# frozen_string_literal: true

require "time"
require "securerandom"
require "async/queue"

module Insika
  # Coordinates execution. It does not build context, decide policy, or talk to
  # the provider. This file does NOT require ruby_llm at load-time —
  # the require is lazy inside the chat methods.
  #
  # Surrounds the stages: spawn, state lifecycle
  # (always via TaskStore), mailbox drain at the boundaries, in-process
  # registration of live fibers (running?), and the emitter with meta + seq.
  class Executor
    def initialize(context_builder:, policy_engine:, middleware:, hooks:,
                   tool_registry:, skill_catalog:, profiles:,
                   session_store:, task_store:, checkpoint_store:,
                   event_stream:, workflow_registry: nil, pending_action_store: nil,
                   capability_registry: nil, tool_catalog: nil, memory_store: nil,
                   tool_trace_store: nil, settings_store: nil, content_filter_factory: nil,
                   delegation_store: nil)
      @context_builder = context_builder
      @policy_engine = policy_engine
      @middleware = middleware
      @hooks = hooks
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      # Legacy Hash -> StaticProfileSource; a ProfileSource passes through.
      @profiles = ProfileSource.coerce(profiles)
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @workflow_registry = workflow_registry # stage 6 of trigger_workflow
      @pending_action_store = pending_action_store # approval gate
      @capability_registry = capability_registry # capability resolution (nil = off)
      @tool_trace_store = tool_trace_store # tool-call trace for Studio debugging (nil = off)
      # Guardrails output filter (RFC-0009 §3.2): ->(state) { OutputFilter | nil }.
      # Injected by the Safety::Factory; nil = off (parity — the stream is untouched).
      # The INPUT guardrail is a Middleware (in the stack, not here); this is the seam
      # for the stream-side redaction the Executor owns.
      @content_filter_factory = content_filter_factory
      # RFC-0010 Fase 2: durable record of ASYNC delegations. nil = async
      # delegation OFF (only the synchronous spawn_subagent works — parity). When
      # present, run_subagent(async: true) dispatches + returns immediately and the
      # child's result is delivered to the parent session as a NEW turn on completion.
      @delegation_store = delegation_store
      # LLM config v2 (§10): resolves the model at turn start (Chat > Agent >
      # platform default) + model_policy + fallback chain. settings_store nil =
      # no platform layer (pre-v2 behavior: the agent's own model is used as-is).
      @model_resolver = ModelResolver.new(settings_store: settings_store)
      # RubyLLM glue (stages 5-7): chat assembly delegated to ChatBuilder. Its
      # optional deps tool_catalog (Tool Search) and memory_store (cross-session
      # memory) matter only to it — nil = parity (deferred
      # not partitioned; no system remember).
      @chat_builder = ChatBuilder.new(
        tool_registry: tool_registry, skill_catalog: skill_catalog,
        checkpoint_store: checkpoint_store, event_stream: event_stream, hooks: hooks,
        tool_catalog: tool_catalog, memory_store: memory_store,
        # RFC-0010: the ChatBuilder wires the spawn_subagent system tool (gated by
        # profile.subagents) and hands it this Executor as the runner. `self` is not
        # yet fully built here, but the ChatBuilder only STORES it (used per-turn).
        subagent_runner: self
      )
      # Stage-3-tail tool assembly (capability resolution, instantiation, D2
      # injection, dedup join, ToolEnvelope wrap) — extracted collaborator (§11 B5).
      @tool_assembly = ToolAssembly.new(
        tool_registry: tool_registry, capability_registry: capability_registry,
        event_stream: event_stream, checkpoint_store: checkpoint_store,
        tool_trace_store: tool_trace_store
      )
      @running = {}            # task_id => TaskActor (live fibers in this process)
      @seqs = Hash.new(0)      # monotonic counter per task
      @supervised = false      # serving mode? — see #turn_parent
      @supervisor = nil        # lazy long-lived supervisor (created when serving)
      @session_actors = {}     # session_id => SessionActor (FIFO queue)
    end

    # Turns on SERVING mode: the composition root's serving arm (serve.rb /
    # config.ru) sets true AFTER recovery. Under HTTP `spawn` runs on the request's
    # EPHEMERAL fiber; without this the turn would be its child and the runtime
    # would CANCEL it on disconnect (violates the contract: "execution belongs to
    # the runtime, not the connection"). When on, the turn is born a child of a
    # long-lived supervisor (sibling of the accept loop) and outlives the
    # connection. false (default) = parents on the current fiber: at recovery/boot
    # and in tests the owner WANTS to wait for the turn to finish (structured
    # concurrency).
    attr_accessor :supervised

    # In-process registry of live fibers (ResumeTask's criterion).
    def running?(task_id) = @running.key?(task_id)

    # CancelTask's access point: posts :cancel if there is a live fiber.
    # Idempotent no-op if there is none (terminal/orphan). Returns whether there
    # was a fiber.
    def cancel(task_id)
      actor = @running[task_id]
      actor&.post(:cancel)
      !actor.nil?
    end

    # PauseTask's access point: posts :pause if there is a live fiber; the turn
    # suspends at the next boundary (drain_and_maybe_suspend). Idempotent no-op
    # if there is none. Returns whether there was a fiber.
    def pause(task_id)
      actor = @running[task_id]
      actor&.post(:pause)
      !actor.nil?
    end

    # ResumeTask's access point for a paused IN-PROCESS task:
    # posts :resume on the live fiber (which is blocked in await). Returns whether
    # there was a live fiber — the handler decides between in-process resume and
    # crash re-dispatch based on that.
    def resume_live(task_id)
      actor = @running[task_id]
      actor&.post(:resume)
      !actor.nil?
    end

    # ApproveAction's access point: WAKES the turn suspended in
    # :waiting by posting :approval on the live fiber. The decision was already
    # written to the store by the handler BEFORE this post (request_approval
    # re-reads it from the store). No-op if there is no live fiber (process
    # crashed) — recovery re-executes and uses the durable decision. Returns
    # whether there was a fiber.
    def approve(task_id)
      actor = @running[task_id]
      actor&.post(:approval)
      !actor.nil?
    end

    # Approval gate, called by the ToolEnvelope at stage 6 when the
    # tool requires approval. Creates/queries the PendingAction (deterministic id
    # by task+turn+tool — per-tool correlation as with the side-effect),
    # suspends the turn in :waiting and BLOCKS (await(:approval)) until the
    # operator resolves it via ApproveAction. The AUTHORITATIVE decision comes
    # from the durable store (crash-safe): on a post-crash re-execution, an
    # already-resolved PendingAction is reused without re-suspending; a :pending
    # one re-suspends.
    # -> "approved" | "rejected".
    def request_approval(task:, turn:, tool:, args:, actor:)
      # Fail-closed: requiring approval with nowhere to persist/query the decision
      # is a misconfiguration — fail LOUD, never hang nor auto-approve.
      if @pending_action_store.nil?
        raise Insika::Error, "tool '#{tool}' requires approval but PendingActionStore is not configured"
      end

      id = pending_id(task.id, turn, tool)
      existing = @pending_action_store.find(id)
      return existing.status.to_s if existing && existing.status != :pending # re-execution: already resolved

      unless existing
        @pending_action_store.create(id: id, task_id: task.id, turn: turn, tool: tool, args: args || {})
        emit(:approval_requested, { pending_id: id, tool: tool.to_s, args: args }, task: task)
      end

      @task_store.transition(task.id, to: :waiting) if @task_store.find(task.id).status == :running

      # Awaits the resolution of THIS pending. A spurious :approval (duplicate or
      # from another pending of the same actor) that wakes up before resolution is
      # ignored (re-await) — fail-closed: only the real resolution of this id
      # unblocks.
      status = nil
      loop do
        actor.await(reason: :approval) # blocks (or raises on :cancel/:timeout)
        status = @pending_action_store.find(id)&.status
        break unless status == :pending
      end

      @task_store.transition(task.id, to: :running)
      (status || :rejected).to_s # fail-closed: missing record -> reject (defensive)
    end

    # Stage 1 (async part): creates the actor, registers it and fires the fiber.
    # Called by the turn handlers (SendMessage/ResumeTask/TriggerWorkflow).
    def spawn(task, profile:, resume_from: nil)
      raise Insika::ValidationError, "task already running: #{task.id}" if running?(task.id)

      actor = TaskActor.new(task_id: task.id, parent: turn_parent)
      @running[task.id] = actor
      actor.run { execute(task, profile: profile, resume_from: resume_from, actor: actor) }
      task.id
    end

    # Turn entry point that RESPECTS the session: a turn with a
    # session_id is SERIALIZED in that session's SessionActor queue (one at a
    # time); without a session_id (one-shot/history) it goes straight to spawn
    # (standalone).
    def spawn_in_session(task, profile:, resume_from: nil)
      # SessionActor only in SERVING mode (@supervised): serializes concurrent
      # REQUESTS. At boot/recovery (non-supervised) the replay is sequential and
      # the long-lived loop would hang the Boot's Sync — use direct spawn (the
      # owner awaits the turn). One-shot/history (no session_id)
      # never serialize.
      unless @supervised && task.session_id
        return spawn(task, profile: profile, resume_from: resume_from)
      end

      session_actor(task.session_id).enqueue(task, profile: profile, resume_from: resume_from)
    end

    # Runs ONE turn serially (called by the SessionActor loop):
    # spawns (the turn is born a child of the supervisor, non-blocking) and AWAITS
    # its completion before returning — that is what serializes the session. A
    # turn error is already mapped to a terminal state inside its own fiber (single
    # capture); here we only ensure the session loop does not die.
    def run_serial(task, profile:, resume_from: nil)
      spawn(task, profile: profile, resume_from: resume_from)
      @running[task.id]&.wait
    rescue Async::Stop
      raise # shutdown: propagate (ends the session loop)
    rescue StandardError => e
      # A SYNCHRONOUS spawn error (before the fiber): execute's single capture
      # does not act (the turn never ran). Mark :failed here so as NOT to orphan
      # the task as :queued with no terminal state nor event (the client would
      # hang).
      fail_spawn(task, e)
    end

    # Shuts down all SessionActors (server shutdown / tests — the loop blocks
    # forever on dequeue when idle).
    def stop_session_actors
      @session_actors.each_value(&:stop)
      @session_actors.clear
      nil
    end

    # RFC-0010 (item 21): runs a CHILD agent turn (called by Tools::Subagent during
    # stage 6). Isolated context (fresh child session), capability NON-inheritance
    # (child profile resolved fresh), environment inheritance (model/thinking seeded
    # from the parent). NEVER raises: a bad agent/depth/child failure is a message
    # to the model, not a turn-killer.
    #
    # async:false (default, Fase 1) — SYNCHRONOUS: runs the child inside the parent's
    #   fiber and returns { text:, session_id: } (the child result is the tool result).
    # async:true (Fase 2) — DURABLE dispatch: spawns the child NON-blocking, persists
    #   a Delegation, returns { dispatched:, agent:, session_id: } immediately; the
    #   parent turn ends and the child's result is later delivered as a NEW turn on
    #   the parent session (needs a delegation_store — else falls back to sync).
    def run_subagent(agent:, message:, parent_state:, async: false)
      plan = plan_subagent({ "agent" => agent, "message" => message }, parent_state)
      return { error: plan[:error] } if plan[:error]

      if async && @delegation_store
        dispatch_async_child(plan[:profile], plan[:message], plan[:depth], parent_state)
      else
        spawn_and_await_child(plan[:profile], plan[:message], plan[:depth], parent_state)
      end
    end

    # RFC-0010 §A (fan-out): runs SEVERAL child turns IN PARALLEL and returns all
    # results together, in the requested order. This is the real latency win — the
    # children overlap their provider waits on the reactor, so wall-clock ≈ the
    # slowest child, not the sum. Always sync-join (a combined result in the parent's
    # turn); the async deliver-as-new-turn mode is single-child only, by design.
    # NEVER raises: per-task errors keep their slot; a bad envelope returns { error: }.
    # -> { results: [{agent:, text:, session_id:} | {agent:, error:}, ...] } | { error: }
    def run_subagents(tasks:, parent_state:)
      list = Array(tasks)
      return { error: "tasks must be a non-empty list of {agent, message}" } if list.empty?

      cap = SubagentGraph.fan_out_cap
      return { error: "too many subagents in one call: #{list.size} (max #{cap})" } if list.size > cap

      plans = list.map { |t| plan_subagent(t, parent_state) }
      { results: spawn_all_and_project(plans, parent_state) }
    end

    # RFC-0010 Fase 2 (boot): reconciles ASYNC delegations after a crash so a
    # completed child's result is never lost. For each undelivered Delegation:
    #   · child TERMINAL, not captured -> capture + deliver.
    #   · child TERMINAL, captured (completed) -> deliver (crash before delivery).
    #   · child NOT terminal -> left as-is; the normal task Recovery resumes the
    #     child and its terminal hook (finalize_delegation) delivers when it finishes.
    # Called once at boot AFTER the task Recovery. No-op without a delegation_store.
    # -> { delivered: [ids] }
    def recover_delegations
      return { delivered: [] } unless @delegation_store

      delivered = []
      @delegation_store.undelivered.each do |deleg|
        child = @task_store.find(deleg.child_task_id)
        next unless child && TERMINAL_STATUSES.include?(child.status)

        finalize_delegation(child) # capture (if needed) + claim + deliver
        delivered << deleg.id
      end
      { delivered: delivered }
    end

    # Stages 2..9. Runs INSIDE the task's fiber.
    def execute(task, profile:, actor:, resume_from: nil)
      # Resume of a crash orphan: the interrupted attempt's Execution was left OPEN
      # (the fiber died). The TaskStore forbids opening a second one while one is
      # open -> close the orphan as :interrupted before opening the N+1 (a new
      # entry, never overwrites).
      close_orphan_execution(task) if resume_from
      @task_store.begin_execution(task.id) # attempt N+1
      # queued (normal spawn) and paused/waiting (resume) -> running. An orphan is
      # already :running (running->running is invalid) -> no transition.
      status = @task_store.find(task.id).status
      @task_store.transition(task.id, to: :running) if %i[queued paused waiting].include?(status)
      emit(:task_started, started_data(task, profile), task: task)

      actor.drain!
      run_pipeline(task, profile, actor, resume_from)
    # SINGLE capture at the top of the fiber: a single place maps
    # error -> terminal state -> events. Stages do no rescue of their own
    # (except tool, RubyLLM semantics). The fiber NEVER re-raises.
    rescue CancelledError
      # cancel is not an error: transition WITHOUT error: (does not close the
      # Execution), then finish_execution closes it with outcome :cancelled.
      @task_store.transition(task.id, to: :cancelled)
      @task_store.finish_execution(task.id, outcome: :cancelled)
      emit(:task_cancelled, { task_id: task.id }, task: task)
    rescue PolicyDenied => e
      emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task)
      fail_task(task, e, stage: :policy)
    rescue Insika::WorkflowSchemaError => e
      # Item 22 / §4.4: a workflow OUTPUT that violates its output_schema. Distinct
      # stage so a contract breach is not conflated with an :unknown failure. (INPUT
      # is validated synchronously in TriggerWorkflow -> 422, never reaches here.)
      fail_task(task, e, stage: :workflow_schema)
    rescue ContextError => e
      fail_task(task, e, stage: :context)
    rescue CapabilityError => e
      fail_task(task, e, stage: :capability)
    rescue ProviderError => e
      fail_task(task, e, stage: :ruby_llm)
    rescue StoreError => e
      fail_task(task, e, stage: :persistence)
    rescue TimeoutError => e
      fail_task(task, e, stage: e.stage)
    rescue StandardError => e
      fail_task(task, e, stage: :unknown)
    ensure
      @running.delete(task.id) # ALWAYS deregister (a false-positive running? would break the resume)
    end

    private

    # Lazy SessionActor per session, parented in the turn scope:
    # the session loop outlives the connection, like the supervisor. Revalidates
    # liveness: if the cached loop died (supervisor recreated/stopped), create a
    # new one — otherwise the queued turns would be black-holed in a dead loop.
    def session_actor(session_id)
      existing = @session_actors[session_id]
      return existing if existing&.alive?

      @session_actors[session_id] =
        SessionActor.new(session_id: session_id, executor: self, parent: turn_parent)
    end

    # Marks :failed a task whose turn FAILED at spawn (before the fiber).
    # Idempotent against a terminal state; StoreError re-raises (the session loop
    # handles it).
    def fail_spawn(task, error)
      current = @task_store.find(task.id)
      return if current.nil? || TERMINAL_STATUSES.include?(current.status)

      @task_store.transition(task.id, to: :failed,
                                      error: { class: error.class.name, message: error.message, stage: :spawn })
      emit(:task_failed, { task_id: task.id, error: error.class.name, message: error.message }, task: task)
    rescue Insika::Error
      nil
    end

    # Parent of the turn's fiber. Non-serving: the current fiber (the owner waits
    # for the turn). Serving: a long-lived supervisor created lazily at the reactor
    # BOUNDARY — the task whose parent is the reactor itself (sibling of the accept
    # loop), outside the subtree of any request. This way the turn outlives the
    # request stop (disconnect). One supervisor per Executor, reused while alive.
    def turn_parent
      return Async::Task.current unless @supervised
      return @supervisor if @supervisor&.running?

      reactor = Async::Task.current.reactor
      node = Async::Task.current
      node = node.parent while node.parent && node.parent != reactor
      # Idle with no spin nor deprecated API (Async::Task#sleep is deprecated in
      # 2.42): blocks on a dequeue that never arrives. Ends only when the scope is
      # stopped (server shutdown) — then the child turns go with it (acceptable).
      @supervisor = node.async { |t| t.annotate("harness-turn-supervisor"); Async::Queue.new.dequeue }
    end

    # Deterministic PendingAction id: correlation by task+turn+tool.
    # Limitation inherited from the side-effect: the SAME tool with approval more
    # than once in a turn collides (the 2nd reuses the 1st's decision) — per-step
    # checkpointing is a future slice. One call per tool is safe.
    def pending_id(task_id, turn, tool) = "#{task_id}:#{turn}:#{tool}"

    # §11 B2: all readings of the persisted command go through rebuild_command
    # (the single normalizer). command_type stays a STRING (the :task_started
    # event and the Telemetry attribute are string-typed).
    def command_type(task)
      rebuild_command(task).type.to_s
    end

    # Closes the orphan Execution (open) of an attempt interrupted by a crash,
    # marking it :interrupted — the record of what happened is preserved; the
    # N+1 attempt is opened right after by begin_execution.
    def close_orphan_execution(task)
      open = @task_store.find(task.id).executions.last
      @task_store.finish_execution(task.id, outcome: :interrupted) if open && open.finished_at.nil?
    end

    # Maps error -> task :failed + events. `transition` with error: ALREADY closes
    # the open Execution (real TaskStore) — do NOT call finish_execution
    # (double-close). The previous checkpoint is NEVER touched on failure. Never
    # re-raises: the fiber dies clean.
    def fail_task(task, error, stage:)
      # Defense-in-depth: if the task is already terminal (e.g. a failure in
      # cleanup AFTER transition(:completed)), completed->failed is invalid and
      # would raise ArgumentError INSIDE the rescue, leaking from the fiber. In
      # that case only report the error — the durability of the committed turn is
      # preserved. This :error is the ONE deliberate, non-twin executor error
      # signal (R2b): the terminal already fired, so a session-scoped subscriber
      # is the only one that may still see it. Same family as the overflow :error.
      current = @task_store.find(task.id)
      if current && TERMINAL_STATUSES.include?(current.status)
        emit(:error, { message: error.message }, task: task)
        return nil
      end

      @task_store.transition(task.id, to: :failed,
                                      error: { class: error.class.name, message: error.message, stage: stage })
      emit(:task_failed, { task_id: task.id, error: error.class.name, message: error.message }, task: task)
      # RFC-0010 Fase 2: a FAILED delegation child still delivers — the parent
      # receives an error note as a new turn (never left hanging).
      finalize_delegation(task)
      nil
    end

    TERMINAL_STATUSES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATUSES

    # Stages 2-9, with mailbox drain only at the boundaries and the
    # turn-timeout wrapping everything via Async::Task#with_timeout — NEVER
    # stdlib Timeout.timeout.
    def run_pipeline(task, profile, actor, resume_from)
      timing = TurnTiming.new if TurnTiming.enabled?
      timing&.mark(:prep_start)
      state = build_turn_state(task, profile, resume_from)
      turn_timeout = turn_timeout_for(profile)

      Async::Task.current.with_timeout(turn_timeout) do
        # :task pair: wraps the turn's stages. before_task may
        # rewrite the TurnState before stage 2; after_task runs after stage 9.
        # The block-param `state` shadows the outer one (uses the TurnState
        # possibly rewritten by before_task). Subject == result == TurnState
        # (the Response content lives in the :done event).
        @hooks.around(:task, state) do |state|
        prepare_turn(task, profile, state, actor, resume_from) # stages 2-3 (mutates state)

        # stage 4: Middleware wraps stages 5-9. A link that
        # short-circuits does NOT call the terminal and sets state.halt_reason.
        terminal_ran = false
        @middleware.call(state) do |st|
          raise Insika::Error, "turn halted: #{st.halt_reason}" if st.halt_reason

          terminal_ran = true
          run_turn_body(task, profile, st, actor, timing) # stages 5-9
        end

        # A Middleware short-circuited (did not call the terminal). Three cases:
        #   · halt_response set -> GRACEFUL halt (RFC-0009 §3.1): the turn COMPLETES
        #     with a safe reply, reusing stages 8-9, without ever touching the LLM.
        #   · halt_reason set    -> halt-as-FAILURE (the pre-existing contract).
        #   · neither            -> contract violation (short-circuit with no signal).
        if !terminal_ran && state.halt_response
          complete_with_halt(task, profile, state)
        elsif state.halt_reason
          raise Insika::Error, "turn halted: #{state.halt_reason}"
        elsif !terminal_ran
          raise Insika::Error, "middleware short-circuited without halt_reason"
        end

          state # subject of the :task pair (after_task receives it; the caller discards)
        end.tap { |st| emit_guardrail_flags(task, st) }
      end
    rescue Async::TimeoutError
      raise Insika::TimeoutError.new("turn exceeded #{turn_timeout}s", stage: :turn)
    end

    # Builds the turn's mutable state (turn number, message, memory tenant, D2
    # turn context). before_task (hooks.around) may still rewrite it before stage 2.
    def build_turn_state(task, profile, resume_from)
      turn = resume_from ? resume_from.turn : 1
      state = TurnState.new(task: task, profile: profile, turn: turn,
                            message: extract_message(task))
      state.tenant = memory_tenant(task) # WRITE-path memory scope (`remember`); =chat (D3)
      state.turn_context = build_turn_context(task, profile, state) # data-tools' ctx.* (D2/G4)
      state.resumed = !resume_from.nil? # EdgeLimiter: an admitted turn is never re-counted
      state
    end

    # with_timeout budget for the turn. A turn that MAY require human approval
    # gets approval_timeout (~1h) so the wrapper does not kill a legitimate
    # operator wait. LLM runaway is already bounded by max_tool_calls + turn_timeout.
    def turn_timeout_for(profile)
      base = profile.limits[:turn_timeout] || 300
      return base if Array(profile.approvals_required).empty?

      [base, profile.limits[:approval_timeout] || 3_600].max
    end

    # Stages 2-3: Context -> initial checkpoint -> capability resolution -> Policy
    # -> tool assembly, each followed by a mailbox drain at the boundary. Mutates
    # `state` in place (the TurnState possibly rewritten by before_task).
    def prepare_turn(task, profile, state, actor, resume_from)
      # stage 2: Context. The :prompt hook pair is wrapped INSIDE the
      # ContextBuilder#call — do NOT wrap here (a double-wrap would fire the hooks
      # twice). Hooks is the SAME instance injected into the Builder and here.
      request = build_context_request(task, profile, state, resume_from)
      state.context = @context_builder.call(request)
      drain_and_maybe_suspend(task, actor)

      # INITIAL checkpoint of the turn ("the checkpoint of turn n contains the
      # state AT THE START of turn n"). Without it, a crash mid stage 6 (before
      # stage 8) would orphan the task WITH NO checkpoint -> unrecoverable.
      # Idempotent: only writes on the 1st turn of a new task.
      save_initial_checkpoint(task, profile, state)

      # capability-resolution sub-step BETWEEN Context and Policy: fills
      # state.capability_names for the POST-Policy join; candidate_tools stays
      # tool_registry.entries (a capability does not go through the ToolAllowlist).
      state.capability_names = resolve_capabilities(profile, state.context)

      # stage 3: Policy (candidate_skills from the CATALOG; candidate_tools =
      # tool_registry.entries, direct tools only).
      resolution = @policy_engine.decide(policy_request(profile, task, state))
      # on resume, tool calls already completed in the interrupted turn are
      # "skipped" (standalone key ∪ turn checkpoint), propagated to promoted tools too.
      skip = resume_from ? @checkpoint_store.side_effects(task.id, turn: state.turn) : []
      state.skip_side_effects = skip
      # wire the approval gate into the state (the ToolEnvelope reads it at stage 6).
      state.actor = actor
      state.approval_coordinator = self
      state.requires_approval = resolution.requires_approval
      state.allowed_tools = wrap_tools(assemble_tool_instances(resolution.allowed_tools, state), state, skip)
      state.allowed_skills = resolution.allowed_skills
      drain_and_maybe_suspend(task, actor)
    end

    # Stages 5-9 (inside the Middleware wrap): assemble chat, the single agent
    # interaction, persistence, terminal event. `st` is the Middleware-yielded state.
    def run_turn_body(task, profile, st, actor, timing = nil)
      # stage 5: assemble chat + check mailbox (send_message only; a workflow does
      # not use the Insika chat — it orchestrates RubyLLM internally).
      drain_and_maybe_suspend(task, actor)
      unless workflow_turn?(task)
        st.chat = create_chat(profile, st)
        @chat_builder.assemble(st.chat, st, emit: ->(type, data) { emit(type, data, task: task) })
        # §11 R1: baseline = seeded-history size, before `ask` appends the turn.
        st.chat_baseline = Array(st.chat.messages).size if st.chat.respond_to?(:messages)
      end

      # guardrails (RFC-0009 §3.2): per-turn stream redactor (nil = off).
      st.output_filter = @content_filter_factory&.call(st)

      # stage 6: the turn's single agent interaction (send_message -> chat.ask;
      # trigger_workflow -> workflow.call). Returns the turn's final content.
      content = run_agent_stage(task, st, timing)
      st.response_content = content # after_task OutputValidator inspects this

      # stage 8: Persistence (fixed order checkpoint->session->task). pure drain!
      # (NEVER suspends at stage 8 — forbidden window): a :pause here arms the flag
      # but is not honored (last stage); :cancel here still raises.
      actor.drain!
      persist_turn(task, profile, st, content)

      # stage 9: Response. usage (tokens) captured at stage 6 travels in the
      # terminal event -> /v1/responses usage + Telemetry (OTEL).
      timing&.mark(:done)
      data = { task_id: task.id, content: content, usage: st.usage }
      data[:timing] = timing.to_h if timing # opt-in TTFB breakdown (INSIKA_TURN_TIMING)
      emit(:task_completed, data, task: task)
    end

    def workflow_turn?(task)
      command_type(task).to_s == "trigger_workflow"
    end

    # Stage 6: the single agent interaction. Returns the turn's final content.
    def run_agent_stage(task, state, timing = nil)
      if workflow_turn?(task)
        # workflow = a Ruby callable that orchestrates RubyLLM internally (RubyLLM
        # First). tools: are the SAME instances filtered by the Resolution and
        # enveloped (stage 7) — the workflow inherits timeout/side-effect/skip.
        # Item 22 / §4.4: the EXPOSED surface — the run (== task.id) is announced on
        # the stream (:workflow_started), the RETURN is validated against the
        # output_schema (WorkflowSchemaError -> :workflow_schema stage), and the
        # typed output is published (:workflow_completed).
        definition = @workflow_registry.definition(workflow_name(task))
        emit(:workflow_started,
             { run_id: task.id, workflow: definition.name, input: state.message || {} }, task: task)
        output = @hooks.around(:agent, state) do |s|
          # input omitted from the payload -> {} (the workflow expects a Hash).
          definition.call(s.message || {}, context: s.context, tools: s.allowed_tools)
        end
        definition.validate_output!(output)
        emit(:workflow_completed, { run_id: task.id, workflow: definition.name, output: output }, task: task)
        output
      else
        filter = state.output_filter # RFC-0009 §3.2: nil = off (stream untouched)
        timing&.mark(:ask)
        response = @hooks.around(:agent, state) do |s|
          result = s.chat.ask(s.message) do |chunk|
            emit_thinking(chunk, task)
            next unless chunk.content

            timing&.mark(:first_token) # first-write-wins -> real TTFB
            out = filter ? filter.push(chunk.content) : chunk.content
            emit(:content, { delta: out }, task: task) unless out.to_s.empty?
          end
          # release the buffered tail once the stream ends (a value that never
          # completed into a match is emitted redacted-if-needed, not lost).
          if filter && !(tail = filter.flush).to_s.empty?
            emit(:content, { delta: tail }, task: task)
          end
          result
        end
        state.usage = with_model_source(usage_of(response), state.model_selection)
        # persisted/terminal content must match the redacted stream (D3): the filter's
        # accumulated output, else the raw response.
        filter ? filter.output : response.content
      end
    end

    # The provider's REASONING (DeepSeek `reasoning_content`, Anthropic thinking
    # blocks): RubyLLM parks it in `chunk.thinking`, NEVER in `chunk.content`, so it
    # was being dropped on the floor — invisible in the Studio and in the trace. It
    # rides the Event Stream as its OWN type (:thinking), and `/v1/responses`
    # deliberately does not translate it: the deliberation is observability, not the
    # answer, and must not cross the edge to the end customer.
    #
    # Three deliberate omissions:
    # · the guardrail filter is NOT applied — it accumulates the PERSISTED content
    #   (D3), and pushing reasoning through it would corrupt the turn's answer;
    # · `timing.mark(:first_token)` stays on :content — TTFB means the first token the
    #   customer can see (item 34's baselines measure that, not the first thought);
    # · nothing is persisted — the reasoning is not part of the conversation.
    #
    # Duck-typed like `usage_of`: a provider/fake with no thinking -> nothing to emit.
    def emit_thinking(chunk, task)
      return unless chunk.respond_to?(:thinking)

      thought = chunk.thinking
      text = thought.respond_to?(:text) ? thought.text : thought # RubyLLM::Thinking | String | nil
      emit(:thinking, { delta: text.to_s }, task: task) unless text.to_s.empty?
    end

    # Annotates the usage with the RESOLVED model-selection source (v2, §10):
    # where the model came from (:chat/:agent/:platform_default) travels alongside
    # the resolved model id (from the provider) into the terminal event/Telemetry,
    # so billing/telemetry can attribute the turn to a config layer. nil usage
    # (workflow / provider without counts) -> nothing to annotate.
    def with_model_source(usage, selection)
      return usage if usage.nil? || selection.nil?

      usage[:model_source] = selection.source
      usage[:model] ||= selection.model # falls back to the resolved id when the provider omits it
      usage
    end

    # Token usage of the provider's response (RubyLLM::Message exposes
    # input_tokens/output_tokens/cached_tokens/model_id). Duck-typed: a provider/
    # fake with no counting -> nil (nothing to report). Shape compatible with the
    # OpenAI Responses usage (input/output/total) + model, consumed by
    # /v1/responses and Telemetry.
    def usage_of(response)
      return nil unless response.respond_to?(:input_tokens)

      input = response.input_tokens.to_i
      output = response.output_tokens.to_i
      usage = { input_tokens: input, output_tokens: output, total_tokens: input + output }
      if response.respond_to?(:cached_tokens) && response.cached_tokens
        usage[:cached_tokens] = response.cached_tokens.to_i # cache_read_input_tokens
      end
      # §11 R3: prompt-cache WRITE tokens (Anthropic cache_creation_input_tokens),
      # billed at ~1.25x. Reported so the first (write) turn vs later (read) turns
      # are distinguishable in telemetry/usage.
      if response.respond_to?(:cache_creation_tokens) && response.cache_creation_tokens
        usage[:cache_creation_tokens] = response.cache_creation_tokens.to_i
      end
      usage[:model] = response.model_id.to_s if response.respond_to?(:model_id) && response.model_id
      usage
    end

    def workflow_name(task)
      rebuild_command(task).payload["workflow"]
    end

    # turn message: send_message -> payload.message; trigger_workflow ->
    # payload.input (the input becomes the "user" content and the workflow
    # argument).
    def extract_message(task)
      payload = rebuild_command(task).payload
      payload["message"] || payload["input"]
    end

    def command_history(task)
      rebuild_command(task).payload["history"]
    end

    def build_context_request(task, profile, state, resume_from)
      session = task.session_id ? @session_store.find(task.session_id) : nil
      state.session = session # create_chat reads it for the per-chat model pin (§10)
      hist = command_history(task)
      # `vars` reconciles the seam (the Request/Session provider already
      # called request.vars): session metadata + the explicit `history` in the
      # convention the Session provider consumes (vars["history"]).
      vars = (session&.vars || {}).dup
      vars["history"] = hist if hist
      # The single type is Insika::ContextRequest (Data); the explicit `history`
      # travels in vars["history"] (Session provider convention), not in a field
      # of its own.
      ContextRequest.new(profile: profile, message: state.message, session: session,
                         checkpoint: resume_from, tenant: command_tenant(task), vars: vars)
    end

    # :task_started payload. Carries the EXPLICIT command tenant (item 16 / P4) so
    # the observability convention can group by it — the one operator-set label that
    # is not derivable from the task itself. Omitted when absent: the terminal
    # events keep their shape and no consumer sees a null it never saw before. NOT
    # memory_tenant: that one falls back to the chat id (per-chat cardinality).
    def started_data(task, profile)
      data = { task_id: task.id, command: command_type(task), agent: profile&.id }
      tenant = command_tenant(task)
      data[:tenant] = tenant if tenant
      data
    end

    # Command tenant (Command.build(..., tenant:) -> meta[:tenant],
    # command.rb). Absent -> nil (the MemoryStore applies DEFAULT_TENANT).
    def command_tenant(task)
      rebuild_command(task).meta["tenant"]
    end

    # Engine memory scope (D3): the Command's EXPLICIT tenant wins (multi-merchant
    # override); otherwise the SESSION (=chat) — engine-owner memory is per-chat.
    # Symmetric to the READ path (Memory provider). One-shot with no tenant -> nil
    # (_default). It is NOT the <request_context> tenant (that follows
    # command_tenant, prompt parity) — only the memory read/write scope.
    def memory_tenant(task)
      command_tenant(task) || task.session_id
    end

    # Turn context (Phase 6/D2/G4): the ids the data-tools resolve via
    # {{ctx.*}} to emit X-Chat-Id/X-Store-Id/X-Agent-Id to /api/internal/*. They
    # come from the TURN, never from the model args (R2). chat_id = the session
    # (the /v1/responses adapter creates the session with id = user = chat.id);
    # tenant = the Command tenant (memory) OR chat_id (drop-in default); agent_id =
    # profile; store_id = the profile metadata (stable per store, from the pack).
    # Absent fields -> nil (the data-tool emits an empty header; in the pilot the
    # profile carries store_id). Generic: nothing here mentions consumer-app (NF1).
    def build_turn_context(task, profile, state)
      {
        chat_id: task.session_id,
        agent_id: profile.id,
        tenant: state.tenant, # already = command_tenant || session_id (memory_tenant)
        store_id: profile.store_id,
        # RFC-0010: current delegation depth (0 for a top-level turn). Carried in
        # the child command's payload by run_subagent; read here so the child's OWN
        # spawn_subagent tool sees depth+1 and the runtime cap holds down the chain.
        delegation_depth: delegation_depth(task)
      }
    end

    # Delegation depth of THIS turn (RFC-0010): the value run_subagent stamped in
    # the child command, or 0 for a top-level turn. Integer-coerced (JSON round-trip
    # of the persisted command may deliver a String).
    def delegation_depth(task)
      rebuild_command(task).payload["delegation_depth"].to_i
    end

    # RFC-0010 R2: environment (model/thinking) inherits as DEFAULT — the child's
    # explicit value wins; when absent, seed from the parent's RESOLVED selection.
    # Capacity fields are untouched (R1: the child profile is used as-is). Returns
    # the child profile unchanged when there is nothing to inherit.
    def inherit_environment(child_profile, parent_state)
      sel = parent_state.model_selection
      return child_profile if sel.nil?

      model = child_profile.model || sel.model
      provider = child_profile.provider || sel.provider
      params = child_profile.params.dup # build stringified it => string keys
      inherited_thinking = (sel.params || {})[:thinking]
      params["thinking"] = inherited_thinking if !params.key?("thinking") && !inherited_thinking.nil?

      return child_profile if model == child_profile.model &&
                              provider == child_profile.provider &&
                              params == child_profile.params

      child_profile.with(model: model, provider: provider, params: params)
    end

    # Single validation path for a delegation (RFC-0010) — shared by run_subagent
    # and the fan-out run_subagents. `task` is {agent, message} (string OR symbol
    # keys — the model's args arrive string-keyed). Returns a resolved plan
    # { agent:, profile:, message:, depth: } or { agent:, error: } (the agent name is
    # kept even on error so a fan-out result keeps its slot labeled).
    def plan_subagent(task, parent_state)
      agent = (task["agent"] || task[:agent]).to_s
      message = (task["message"] || task[:message]).to_s

      # Gate = the PARENT's subagents allowlist (a capacity field — never inherited).
      allowed = Array(parent_state.profile.subagents).map(&:to_s)
      return { agent: agent, error: "agent '#{agent}' is not in this agent's subagents allowlist" } unless allowed.include?(agent)

      # Runtime depth guard (belt-and-suspenders; SubagentGraph is the primary,
      # definition-time check). parent depth from its turn context, +1 for the child.
      cap = SubagentGraph.depth_cap
      depth = (parent_state.turn_context&.dig(:delegation_depth) || 0) + 1
      return { agent: agent, error: "subagent depth #{depth} exceeds cap #{cap}" } if depth > cap

      profile = @profiles[agent]
      return { agent: agent, error: "agent '#{agent}' not configured" } if profile.nil?

      { agent: agent, profile: inherit_environment(profile, parent_state), message: message, depth: depth }
    end

    # Fan-out barrier: spawn ALL valid children first (non-blocking), THEN await ALL.
    # Spawning before awaiting is what makes them concurrent — each child spends its
    # time on the provider HTTP wait, and those waits overlap on the reactor. Invalid
    # plans keep their ordered slot as an { agent:, error: } result.
    def spawn_all_and_project(plans, parent_state)
      spawned = plans.map do |plan|
        next plan if plan[:error]

        session_id, child_task = create_child(plan[:profile], plan[:message], plan[:depth], parent_state, async: false)
        spawn(child_task, profile: plan[:profile])
        { agent: plan[:agent], task_id: child_task.id, session_id: session_id }
      end

      spawned.each { |s| @running[s[:task_id]]&.wait unless s[:error] }
      spawned.map do |s|
        next { agent: s[:agent], error: s[:error] } if s[:error]

        # label each result with its agent so the model can tell the N apart.
        project_child_result(s[:task_id], s[:session_id], s[:agent], parent_state).merge(agent: s[:agent])
      end
    end

    # Creates the isolated child session (linked to the parent) + child task.
    # Shared by the sync and async paths. Emits :subagent_started correlated to the
    # PARENT task. -> [child_session_id, child_task].
    def create_child(child_profile, message, depth, parent_state, async:, delegation_id: nil)
      child_session_id = "sub-#{SecureRandom.uuid}"
      @session_store.create(
        id: child_session_id,
        vars: { "parent_session_id" => parent_state.task.session_id,
                "parent_task_id" => parent_state.task.id, "delegation_depth" => depth }
      )
      payload = { "agent" => child_profile.id, "message" => message,
                  "session_id" => child_session_id, "delegation_depth" => depth }
      # Async children carry their delegation id in the command payload so the
      # terminal hook (finalize_delegation) is O(1) — a normal turn has no marker and
      # skips the delegation store entirely (no per-turn O(n) scan).
      payload["delegation_id"] = delegation_id if delegation_id
      command = Insika::Command.build(:send_message, payload).to_h
      child_task = @task_store.create(command: command, session_id: child_session_id)

      emit(:subagent_started,
           { agent: child_profile.id, parent_task_id: parent_state.task.id,
             child_session_id: child_session_id, depth: depth, async: async },
           task: parent_state.task)
      [child_session_id, child_task]
    end

    # SYNC (Fase 1): spawns the child and AWAITS it on the parent's fiber, then
    # projects the terminal content. Direct `spawn` (not spawn_in_session): the
    # child session is brand-new, so there is no SessionActor contention — the child
    # is parented at turn_parent and the parent yields cooperatively on `wait`.
    def spawn_and_await_child(child_profile, message, depth, parent_state)
      child_session_id, child_task = create_child(child_profile, message, depth, parent_state, async: false)
      spawn(child_task, profile: child_profile)
      @running[child_task.id]&.wait
      project_child_result(child_task.id, child_session_id, child_profile.id, parent_state)
    end

    # ASYNC (Fase 2): persists a Delegation, spawns the child NON-blocking, and
    # returns a dispatch ack immediately — the parent turn ends without waiting. The
    # child's terminal hook (finalize_delegation) delivers the result later, as a
    # NEW turn on the parent session.
    def dispatch_async_child(child_profile, message, depth, parent_state)
      delegation_id = SecureRandom.uuid
      child_session_id, child_task =
        create_child(child_profile, message, depth, parent_state, async: true, delegation_id: delegation_id)
      @delegation_store.create(
        id: delegation_id,
        parent_task_id: parent_state.task.id, parent_session_id: parent_state.task.session_id,
        parent_agent: parent_state.profile.id, child_agent: child_profile.id,
        child_task_id: child_task.id, child_session_id: child_session_id, depth: depth
      )
      spawn(child_task, profile: child_profile)
      { dispatched: child_task.id, agent: child_profile.id, session_id: child_session_id }
    end

    # Child result = last `assistant` message of the child session (R3), or the
    # terminal error if the child turn failed. Same projection as the A2A edge.
    def project_child_result(child_task_id, child_session_id, agent_id, parent_state)
      task = @task_store.find(child_task_id)
      if task && task.status.to_s == "failed"
        err = child_terminal_error(task)
        emit(:subagent_completed,
             { agent: agent_id, child_session_id: child_session_id, state: "failed" },
             task: parent_state.task)
        return { error: "subagent '#{agent_id}' failed: #{err || 'unknown error'}" }
      end

      emit(:subagent_completed,
           { agent: agent_id, child_session_id: child_session_id, state: "completed" },
           task: parent_state.task)
      { text: child_final_text(child_session_id).to_s, session_id: child_session_id }
    end

    def child_final_text(child_session_id)
      session = @session_store.find(child_session_id)
      msg = session&.messages&.reverse&.find { |m| (m["role"] || m[:role]).to_s == "assistant" }
      msg && (msg["content"] || msg[:content])
    end

    def child_terminal_error(task)
      exec = task.executions.last
      return nil unless exec && exec.outcome.to_s == "failed"

      exec.error && (exec.error["message"] || exec.error[:message])
    end

    # RFC-0010 Fase 2 — terminal hook: when a turn ends (success OR failure), if the
    # task is the child of an ASYNC delegation, capture its result and deliver it to
    # the parent. Fires for both a normal completion and a resumed one (recovery),
    # so it needs no live watcher fiber. No-op without a delegation_store or when the
    # task is not a delegation child. Best-effort: a failure here must NOT re-fail an
    # already-committed child turn — swallow (recovery re-drives from the record).
    def finalize_delegation(child_task)
      return unless @delegation_store

      # Fresh read: the snapshot the hook passes predates transition(:completed/
      # :failed); the store is the single source of truth for terminal state + the
      # command marker.
      child_id = child_task.respond_to?(:id) ? child_task.id : child_task
      child = @task_store.find(child_id)
      # Cheap gate: only async delegation children carry a delegation_id in the
      # command payload — a normal turn skips the store entirely (no O(n) scan).
      deleg_id = child && rebuild_command(child).payload["delegation_id"]
      return unless deleg_id

      deleg = @delegation_store.find(deleg_id)
      return if deleg.nil? || deleg.status == :delivered

      if deleg.status == :dispatched
        if child.status.to_s == "failed"
          @delegation_store.mark_completed(deleg.id, error: child_terminal_error(child) || "unknown error")
        else
          @delegation_store.mark_completed(deleg.id, result: child_final_text(deleg.child_session_id).to_s)
        end
      end
      deliver_delegation(@delegation_store.find(deleg.id))
    rescue Insika::Error
      nil # best-effort: never re-fail a committed child turn (recovery re-drives).
    end

    # Delivers a captured delegation as a NEW turn on the PARENT session. The claim
    # (completed -> delivered) makes this AT-MOST-ONCE: only the caller that wins the
    # transition spawns the delivery turn (the hook and recovery may both fire).
    # spawn_in_session routes through the parent's SessionActor FIFO — that is what
    # makes it a new turn "when idle" (queued behind any in-flight parent turn),
    # preserving role alternation + prompt cache.
    def deliver_delegation(deleg)
      return unless @delegation_store.claim_delivery(deleg.id)

      profile = @profiles[deleg.parent_agent]
      # The parent agent vanished (deleted mid-flight): nothing to deliver to. The
      # record stays :delivered (claimed) so recovery does not loop on it.
      return if profile.nil?

      message = format_delegation_message(deleg)
      command = Insika::Command.build(
        :send_message,
        { "agent" => deleg.parent_agent, "message" => message,
          "session_id" => deleg.parent_session_id, "delegation_id" => deleg.id }
      ).to_h
      task = @task_store.create(command: command, session_id: deleg.parent_session_id)
      emit(:subagent_delivered,
           { delegation_id: deleg.id, agent: deleg.child_agent,
             child_session_id: deleg.child_session_id, state: deleg.error ? "failed" : "completed" },
           task: task)
      spawn_in_session(task, profile: profile)
    end

    # The synthetic message the parent turn receives. A clear, self-describing note
    # so the parent agent knows a delegated subtask returned (and can relay it).
    def format_delegation_message(deleg)
      if deleg.error
        "[subagent:#{deleg.child_agent}] delegated task FAILED: #{deleg.error}"
      else
        "[subagent:#{deleg.child_agent}] delegated task completed. Result:\n\n#{deleg.result}"
      end
    end

    # The real Request: command (for the WorkflowAllowlist), context
    # (Context before Policy), candidate_tools (registry Entries, UNfiltered) and
    # candidate_skills (from the CATALOG).
    def policy_request(profile, task, state)
      Insika::Policy::PolicyRequest.new(
        profile: profile,
        command: rebuild_command(task),
        context: state.context,
        candidate_tools: @tool_registry.entries,
        candidate_skills: @skill_catalog.effective(profile.skills)
      )
    end

    # The Task persists the Command as a Hash; the WorkflowAllowlist needs
    # a Command with #type (Symbol) and #payload. §11 B2: the SINGLE point that
    # reconciles the string||symbol keys of the persisted command — payload/meta
    # keys are stringified ONCE here, so every reader (command_type/workflow_name/
    # extract_message/command_history/command_tenant) works with string keys.
    def rebuild_command(task)
      cmd = task.command
      Insika::Command.new(
        type: (cmd["type"] || cmd[:type]).to_s.to_sym,
        payload: normalize_keys(cmd["payload"] || cmd[:payload]),
        meta: normalize_keys(cmd["meta"] || cmd[:meta])
      )
    end

    # Shallow key stringification (nil -> {}). The persisted command comes
    # string-keyed from the TaskStore; this only matters for a symbol-keyed
    # command that bypassed it (fakes/tests).
    def normalize_keys(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    # Stage-3-tail tool assembly — delegated to ToolAssembly (§11 B5). Kept as
    # thin private methods so the existing spec contract (executor.send(:...))
    # stays intact and run_pipeline reads unchanged.
    def resolve_capabilities(profile, context) = @tool_assembly.resolve_capabilities(profile, context)
    def assemble_tool_instances(allowed, state) = @tool_assembly.assemble_tool_instances(allowed, state)

    def wrap_tools(tools, state, skip_side_effects = [])
      @tool_assembly.wrap_tools(tools, state, skip_side_effects)
    end

    # Stage boundary: drains the mailbox and, if the operator requested a pause,
    # SUSPENDS the turn in :paused until :resume. Cooperative — never in the
    # middle of an operation. NOT called at stage 8 (forbidden window).
    # :cancel during the wait becomes CancelledError (top single capture);
    # :timeout becomes TimeoutError. The turn's initial checkpoint was already
    # written, so a kill -9 in :paused is resumable.
    def drain_and_maybe_suspend(task, actor)
      actor.drain!
      return unless actor.pause_requested?

      @task_store.transition(task.id, to: :paused)
      emit(:task_paused, { task_id: task.id }, task: task)
      actor.await(reason: :paused) # blocks until :resume (or raises on :cancel/:timeout)
      @task_store.transition(task.id, to: :running)
      emit(:task_resumed, { task_id: task.id }, task: task)
    end

    # Checkpoint of the turn's initial state (see the call in run_pipeline). Only
    # on the 1st turn of a new task: on resume the turn checkpoint already exists
    # (does not re-save — the CheckpointStore's monotonicity would raise). It emits
    # NO event (:checkpoint_created is stage 8's only) and touches no side-effects.
    def save_initial_checkpoint(task, profile, state)
      return unless @checkpoint_store.find(task.id, turn: state.turn).nil?

      @checkpoint_store.save(Insika::Checkpoint.new(
                               task_id: task.id, turn: state.turn, session_id: task.session_id,
                               agent_id: profile.id, messages: flatten_history(state.context.history),
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))
    end

    # GRACEFUL halt (RFC-0009 §3.1): a Middleware short-circuited with a safe reply.
    # The turn COMPLETES — same stages 8-9 as a normal turn — but the "assistant
    # content" is the guardrail's safe response, produced with ZERO LLM calls. The
    # order mirrors a real turn so both the /v1/responses consumer (which reads the
    # text off :content deltas) and the Studio viewer render it: audit -> safe text
    # -> persist -> terminal.
    def complete_with_halt(task, profile, state)
      content = state.halt_response.to_s
      state.response_content = content

      if (block = state.guardrail_block)
        emit(:guardrail_blocked, {
               task_id: task.id, category: block[:category], source: block[:source],
               action: block[:action], detail: block[:detail]
             }, task: task)
      end
      emit(:content, { delta: content }, task: task) unless content.empty?
      # An EDGE-blocked turn (rate limit / token ceiling, item 33) completes but
      # stays OUT of the session history: a flood at the wall must not bloat the
      # session nor evict real conversation from the context budget — the
      # :guardrail_blocked event is the audit trail. Content-guardrail blocks
      # keep persisting (RFC-0009: the refusal is part of the conversation).
      persist_turn(task, profile, state, content,
                   session: state.guardrail_block&.[](:source) != "edge")
      emit(:task_completed, { task_id: task.id, content: content, usage: state.usage }, task: task)
    end

    # Emits one :guardrail_flagged per flag the OutputValidator appended in
    # after_task (audit only — the turn already completed). Reads a plain Array off
    # the state, keeping the Executor decoupled from Safety.
    def emit_guardrail_flags(task, state)
      return unless state.respond_to?(:guardrail_flags)

      Array(state.guardrail_flags).each do |flag|
        emit(:guardrail_flagged, {
               task_id: task.id, category: flag[:category], source: flag[:source], detail: flag[:detail]
             }, task: task)
      end
    end

    # Stage 8: FIXED order checkpoint -> session -> task. If it crashes
    # between writes, the worst case is a new checkpoint with the task :running ->
    # Recovery re-executes the already-saved turn (safe thanks to the side-effect
    # recording).
    #
    # CHECKPOINT vs SESSION — the two stores DIVERGE by design (§11 R2c):
    #   · Checkpoint.messages = flatten_history(context.history) + new_messages,
    #     i.e. "what the model actually SAW this turn" AFTER budget eviction
    #     (context.history is the post-budget assembly). It is the deterministic
    #     replay tape for Recovery: resuming from it reproduces the exact prompt.
    #     It is per-task and pruned to keep: 1 (only the latest matters for resume).
    #   · SessionStore = the INTEGRAL source of truth: append-only, never evicted,
    #     the full human-readable transcript (viewer, audit, next turns' raw input).
    # So a long session legitimately has a Checkpoint SHORTER than the Session:
    # that is not drift to reconcile — it is the point. Do NOT "fix" the checkpoint
    # to carry the full history (it would defeat the budget) nor evict the session.
    def persist_turn(task, profile, state, content, session: true)
      new_messages = turn_transcript(state, content)
      transcript = flatten_history(state.context.history) + new_messages

      @checkpoint_store.save(Insika::Checkpoint.new(
                               task_id: task.id, turn: state.turn + 1, session_id: task.session_id,
                               agent_id: profile.id, messages: transcript,
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))

      # session only when the turn is from a persisted session; one-shot/history
      # do not persist TO THE SESSION (but always checkpoint). `session: false` is
      # the edge-blocked halt (see complete_with_halt).
      @session_store.append_messages(task.session_id, new_messages) if session && task.session_id

      # finish_execution (closes the Execution) BEFORE transition(:completed) —
      # transition without error: does not close, so the finish is needed here.
      @task_store.finish_execution(task.id, outcome: :completed)
      @task_store.transition(task.id, to: :completed)
      # prune is best-effort cleanup: a failure here must NOT re-fail an
      # already-committed turn (the task is already :completed and durable).
      # Swallow.
      begin
        @checkpoint_store.prune(task.id, keep: 1)
      rescue Insika::StoreError
        nil
      end

      emit(:checkpoint_created, { task_id: task.id, turn: state.turn + 1 }, task: task)

      # RFC-0010 Fase 2: if this completed turn is an ASYNC delegation child,
      # deliver its result to the parent as a NEW turn. No-op for a normal turn
      # (not a delegation child) or without a delegation_store.
      finalize_delegation(task)
    end

    # Truncation cap for a persisted `role: tool` content (§11 R1): the transcript
    # keeps the loop coherent; the FULL result lives in the ToolTraceStore (viewer).
    TOOL_CONTENT_CAP = 4_000

    # The turn's messages in the ADDITIVE string-keyed format (§11 R1). Prefers the
    # real chat transcript (`chat.messages.drop(baseline)`) so tool calls/results
    # survive between turns; falls back to the {user, assistant} pair when the chat
    # did not record the turn (workflow, graceful halt, or the specs' FakeChat).
    # The final assistant text is the REDACTED `content` (output_filter, RFC-0009 D3),
    # never the raw text the gem stored.
    def turn_transcript(state, content)
      recorded = recorded_turn_messages(state)
      return [{ "role" => "user", "content" => state.message.to_s },
              { "role" => "assistant", "content" => content.to_s }] if recorded.empty?

      recorded[-1] = recorded[-1].merge("content" => content.to_s) if recorded.last["role"] == "assistant"
      recorded
    end

    # Slices the chat's messages added DURING this turn and serializes them.
    # [] when there is no recorded transcript (baseline nil / no #messages).
    def recorded_turn_messages(state)
      chat = state.chat
      baseline = state.chat_baseline
      return [] unless chat && baseline && chat.respond_to?(:messages)

      Array(chat.messages).drop(baseline).filter_map { |m| serialize_chat_message(m) }
    end

    # A RubyLLM::Message (duck-typed) -> string-keyed Hash. Assistant carries
    # "tool_calls" only when present; tool carries "tool_call_id" + a clipped content.
    def serialize_chat_message(msg)
      role = msg_field(msg, :role).to_s
      content = msg_field(msg, :content).to_s
      case role
      when "assistant"
        calls = serialize_tool_calls(msg_field(msg, :tool_calls))
        h = { "role" => "assistant", "content" => content }
        h["tool_calls"] = calls unless calls.empty?
        h
      when "tool"
        { "role" => "tool", "tool_call_id" => msg_field(msg, :tool_call_id).to_s,
          "content" => clip_tool_content(content) }
      else
        { "role" => role, "content" => content }
      end
    end

    # RubyLLM keeps tool_calls as {id => ToolCall}; tolerate an Array too. -> [{id,name,arguments}].
    def serialize_tool_calls(tool_calls)
      return [] if tool_calls.nil?

      list = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)
      list.filter_map do |tc|
        next nil unless tc

        { "id" => msg_field(tc, :id).to_s, "name" => msg_field(tc, :name).to_s,
          "arguments" => msg_field(tc, :arguments) || {} }
      end
    end

    # Reads a field off a Message/ToolCall (method) OR a Hash (sym|string key).
    def msg_field(obj, key)
      return obj.public_send(key) if obj.respond_to?(key)

      obj[key] || obj[key.to_s] if obj.respond_to?(:[])
    end

    def clip_tool_content(str)
      return str if str.length <= TOOL_CONTENT_CAP

      "#{str[0, TOOL_CONTENT_CAP]}…(truncated — full result in the viewer)"
    end

    # context.history may carry "eviction units" (an assistant+tool_results cycle
    # grouped as one Array by the Session provider, §11 R1). Checkpoints store a
    # FLAT list — the provider regroups on read. Flatten one level; message Hashes
    # are untouched.
    def flatten_history(history) = Array(history).flatten(1)

    # Stage 6 (factory): the ONLY point that touches the gem. lazy require,
    # confined — not covered by unit (factory line). It also loads the system
    # builtins (load_skill/tool_search/remember) that the ChatBuilder assembles at
    # stage 5 — lazy, so the core installs without ruby_llm.
    def create_chat(profile, state)
      require "ruby_llm"
      require_relative "tools/load_skill"
      require_relative "tools/tool_search"
      require_relative "tools/remember"
      require_relative "tools/subagent"
      require_relative "tools/subagents"
      # v2 resolution (§10): Chat pin > Agent model > platform default, model_policy
      # enforced, fallback chain resolved. Kept on the state for telemetry (usage).
      selection = @model_resolver.resolve(profile: profile, session: state.session)
      state.model_selection = selection
      chat = RubyLLM.chat(
        model: selection.model,
        provider: selection.provider,
        assume_model_exists: selection.assume_model_exists?
      )
      selection.apply_params(chat) # temperature/max_tokens/thinking (per-agent, §10)
      chat
    end

    # Single emitter: an Event with meta and a monotonic seq per task. @seqs is not
    # cleared at the end of the task — the resume (new Execution) continues the
    # numbering (reliable replay).
    def emit(type, data, task:)
      @event_stream.emit(Insika::Event.new(
                           type: type, data: data,
                           meta: { task_id: task.id, session_id: task.session_id,
                                   seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
