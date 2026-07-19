# frozen_string_literal: true

require "time"
require "async/queue"

module Harness
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
                   tool_trace_store: nil, settings_store: nil)
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
        tool_catalog: tool_catalog, memory_store: memory_store
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
        raise Harness::Error, "tool '#{tool}' requires approval but PendingActionStore is not configured"
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
      raise Harness::ValidationError, "task already running: #{task.id}" if running?(task.id)

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
      emit(:task_started, { task_id: task.id, command: command_type(task), agent: profile&.id }, task: task)

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
      emit(:error, { message: "task cancelled" }, task: task) # legacy compat
    rescue PolicyDenied => e
      emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task)
      fail_task(task, e, stage: :policy)
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
      emit(:error, { message: error.message }, task: task)
    rescue Harness::Error
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

    # command was normalized to string keys by the TaskStore; accept a symbol
    # too for robustness.
    def command_type(task)
      task.command[:type] || task.command["type"]
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
      # preserved.
      current = @task_store.find(task.id)
      if current && TERMINAL_STATUSES.include?(current.status)
        emit(:error, { message: error.message }, task: task)
        return nil
      end

      @task_store.transition(task.id, to: :failed,
                                      error: { class: error.class.name, message: error.message, stage: stage })
      emit(:task_failed, { task_id: task.id, error: error.class.name, message: error.message }, task: task)
      emit(:error, { message: error.message }, task: task) # legacy compat
      nil
    end

    TERMINAL_STATUSES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATUSES

    # Stages 2-9, with mailbox drain only at the boundaries and the
    # turn-timeout wrapping everything via Async::Task#with_timeout — NEVER
    # stdlib Timeout.timeout.
    def run_pipeline(task, profile, actor, resume_from)
      turn = resume_from ? resume_from.turn : 1
      state = TurnState.new(task: task, profile: profile, turn: turn,
                            message: extract_message(task))
      state.tenant = memory_tenant(task) # WRITE-path memory scope (`remember`); =chat (D3)
      state.turn_context = build_turn_context(task, profile, state) # data-tools' ctx.* (D2/G4)
      turn_timeout = profile.limits[:turn_timeout] || 300
      # A turn that MAY require human approval gets budget = approval_timeout
      # (~1h): the turn's with_timeout must not kill a legitimate operator wait.
      # LLM runaway is already bounded by max_tool_calls/max_turns.
      unless Array(profile.approvals_required).empty?
        turn_timeout = [turn_timeout, profile.limits[:approval_timeout] || 3_600].max
      end

      Async::Task.current.with_timeout(turn_timeout) do
        # :task pair: wraps the turn's stages. before_task may
        # rewrite the TurnState before stage 2; after_task runs after stage 9.
        # The block-param `state` shadows the outer one (uses the TurnState
        # possibly rewritten by before_task). Subject == result == TurnState
        # (the Response content lives in the :done event).
        @hooks.around(:task, state) do |state|
        # stage 2: Context. The :prompt hook pair is wrapped INSIDE the
        # ContextBuilder#call — do NOT wrap here (a double-wrap would
        # fire the hooks twice). Hooks is the SAME instance injected into the
        # Builder and here (for :agent/:task/:tool).
        request = build_context_request(task, profile, state, resume_from)
        state.context = @context_builder.call(request)
        drain_and_maybe_suspend(task, actor)

        # INITIAL checkpoint of the turn ("the checkpoint of turn n contains
        # the state AT THE START of turn n"). Without it, a crash mid stage 6
        # (before stage 8) would leave the task orphaned WITH NO checkpoint ->
        # unrecoverable (Recovery would mark it :failed). Idempotent: only writes on
        # the 1st turn of a new task — on resume the checkpoint already exists
        # (find != nil), and on later turns the previous turn's end checkpoint is
        # already this one's "start".
        save_initial_checkpoint(task, profile, state)

        # capability-resolution sub-step: BETWEEN Context and Policy.
        # It only fills state.capability_names for the POST-Policy join — the
        # policy_request below does NOT change (candidate_tools stays
        # tool_registry.entries).
        state.capability_names = resolve_capabilities(profile, state.context)

        # stage 3: Policy (candidate_skills come from the CATALOG, not the
        # context; candidate_tools = tool_registry.entries, ONLY direct tools —
        # unchanged)
        resolution = @policy_engine.decide(policy_request(profile, task, state))
        # on resume, tool calls already completed in the interrupted turn are
        # "skipped" (union of standalone key ∪ turn checkpoint).
        skip = resume_from ? @checkpoint_store.side_effects(task.id, turn: state.turn) : []
        # propagates the `skip` to tools PROMOTED by tool_search (same
        # resume-safety as the eager ones); the builtin reads
        # Array(state.skip_side_effects).
        state.skip_side_effects = skip
        # the Executor instantiates ONLY the allowed ones: the real Engine
        # returns Entries -> factory.call; a fake already returning instances
        # passes through (compat shim).
        # wires the approval gate into the state (the ToolEnvelope reads it at stage 6).
        state.actor = actor
        state.approval_coordinator = self
        state.requires_approval = resolution.requires_approval
        state.allowed_tools = wrap_tools(assemble_tool_instances(resolution.allowed_tools, state), state, skip)
        state.allowed_skills = resolution.allowed_skills
        drain_and_maybe_suspend(task, actor)

        # stage 4: Middleware wraps stages 5-9. A link that
        # short-circuits does NOT call the terminal and sets state.halt_reason.
        terminal_ran = false
        @middleware.call(state) do |st|
          raise Harness::Error, "turn halted: #{st.halt_reason}" if st.halt_reason

          terminal_ran = true
          # stage 5: assemble chat + check mailbox (send_message only; a workflow
          # does not use the Harness chat — it orchestrates RubyLLM internally).
          drain_and_maybe_suspend(task, actor)
          unless workflow_turn?(task)
            st.chat = create_chat(profile, st)
            @chat_builder.assemble(st.chat, st, emit: ->(type, data) { emit(type, data, task: task) })
          end

          # stage 6: the turn's single agent interaction. send_message ->
          # chat.ask; trigger_workflow -> workflow.call(input, context:, tools:)
          # Both wrapped by hooks.around(:agent). The return is the
          # turn's final content.
          content = run_agent_stage(task, st)

          # stage 8: Persistence (fixed order checkpoint->session->task)
          # pure drain! (NEVER suspends at stage 8 — forbidden window). A
          # :pause arriving here arms pause_requested but is NOT honored: it is the
          # last stage, there is no next boundary; the turn completes and the flag
          # is discarded with the actor. Benign race: the pause loses to the
          # completion (the operator sees the task :completed). :cancel here still
          # raises.
          actor.drain!
          persist_turn(task, profile, st, content)

          # stage 9: Response. usage (tokens) captured at stage 6 travels in the
          # terminal event -> /v1/responses usage + Telemetry (OTEL).
          emit(:done, { content: content, usage: st.usage }, task: task) # legacy compat
          emit(:task_completed, { task_id: task.id, content: content, usage: st.usage }, task: task)
        end

        # halt (with a reason) or short-circuit without terminating (contract
        # violation) -> turn failure via the single capture.
        if state.halt_reason
          raise Harness::Error, "turn halted: #{state.halt_reason}"
        elsif !terminal_ran
          raise Harness::Error, "middleware curto-circuitou sem halt_reason"
        end

          state # subject of the :task pair (after_task receives it; the caller discards)
        end
      end
    rescue Async::TimeoutError
      raise Harness::TimeoutError.new("turn exceeded #{turn_timeout}s", stage: :turn)
    end

    def workflow_turn?(task)
      command_type(task).to_s == "trigger_workflow"
    end

    # Stage 6: the single agent interaction. Returns the turn's final content.
    def run_agent_stage(task, state)
      if workflow_turn?(task)
        # workflow = a Ruby callable that orchestrates RubyLLM internally (RubyLLM
        # First). tools: are the SAME instances filtered by the Resolution and
        # enveloped (stage 7) — the workflow inherits timeout/side-effect/skip.
        workflow = @workflow_registry.resolve(workflow_name(task))
        @hooks.around(:agent, state) do |s|
          # input omitted from the payload -> {} (the workflow expects a Hash).
          workflow.call(s.message || {}, context: s.context, tools: s.allowed_tools)
        end
      else
        response = @hooks.around(:agent, state) do |s|
          s.chat.ask(s.message) do |chunk|
            emit(:content, { delta: chunk.content }, task: task) if chunk.content
          end
        end
        state.usage = with_model_source(usage_of(response), state.model_selection)
        response.content
      end
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
        usage[:cached_tokens] = response.cached_tokens.to_i
      end
      usage[:model] = response.model_id.to_s if response.respond_to?(:model_id) && response.model_id
      usage
    end

    def workflow_name(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["workflow"] || payload[:workflow]
    end

    # turn message: send_message -> payload.message; trigger_workflow ->
    # payload.input (the input becomes the "user" content and the workflow
    # argument).
    def extract_message(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["message"] || payload[:message] || payload["input"] || payload[:input]
    end

    def command_history(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["history"] || payload[:history]
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
      # The single type is Harness::ContextRequest (Data); the explicit `history`
      # travels in vars["history"] (Session provider convention), not in a field
      # of its own.
      ContextRequest.new(profile: profile, message: state.message, session: session,
                         checkpoint: resume_from, tenant: command_tenant(task), vars: vars)
    end

    # Command tenant (Command.build(..., tenant:) -> meta[:tenant],
    # command.rb). Absent -> nil (the MemoryStore applies DEFAULT_TENANT).
    def command_tenant(task)
      meta = rebuild_command(task).meta
      meta["tenant"] || meta[:tenant]
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
    # profile carries store_id). Generic: nothing here mentions achei-b2b (NF1).
    def build_turn_context(task, profile, state)
      {
        chat_id: task.session_id,
        agent_id: profile.id,
        tenant: state.tenant, # already = command_tenant || session_id (memory_tenant)
        store_id: (profile.store_id if profile.respond_to?(:store_id))
      }
    end

    # The real Request: command (for the WorkflowAllowlist), context
    # (Context before Policy), candidate_tools (registry Entries, UNfiltered) and
    # candidate_skills (from the CATALOG).
    def policy_request(profile, task, state)
      Harness::Policy::PolicyRequest.new(
        profile: profile,
        command: rebuild_command(task),
        context: state.context,
        candidate_tools: @tool_registry.entries,
        candidate_skills: @skill_catalog.effective(profile.skills)
      )
    end

    # The Task persists the Command as a Hash; the WorkflowAllowlist needs
    # a Command with #type (Symbol) and #payload.
    def rebuild_command(task)
      cmd = task.command
      Harness::Command.new(
        type: (cmd["type"] || cmd[:type]).to_s.to_sym,
        payload: cmd["payload"] || cmd[:payload] || {},
        meta: cmd["meta"] || cmd[:meta] || {}
      )
    end

    # Real Engine -> Entries (respond to factory); fakes -> ready instances.
    # `turn_context` (D2) is deposited into the instances that expose it
    # (data-tools); the rest ignore it (parity).
    def instantiate_tools(allowed, turn_context = nil)
      Array(allowed).map do |t|
        tool = t.respond_to?(:factory) ? t.factory.call : t
        inject_turn_context(tool, turn_context)
        tool
      end
    end

    # D2/G3 seam: deposits the turn context into the freshly created instance
    # (same idea as `remember`, which receives tenant/state) BEFORE the
    # ToolEnvelope. Duck-typed: only what exposes `turn_context=` (DataDefinedTool)
    # receives it. nil (a state with no turn_context, e.g. a test stub) -> no-op.
    def inject_turn_context(tool, turn_context)
      return if turn_context.nil?

      tool.turn_context = turn_context if tool.respond_to?(:turn_context=)
    end

    # Resolution sub-step BETWEEN Context and Policy —
    # it does NOT feed candidate_tools (those stay ONLY tool_registry.entries,
    # a capability does not go through the ToolAllowlist). Resolves each
    # capability of the profile to the concrete Entry already registered in the
    # tool_registry and keeps the impl_name -> capability_name mapping for the
    # post-Policy join. Errors
    # (Unavailable/Ambiguous, or an unregistered impl) propagate as a
    # CapabilityError -> single capture in `execute` (stage :capability). Without
    # @capability_registry OR without profile.capabilities: {} (parity).
    def resolve_capabilities(profile, context)
      return {} if @capability_registry.nil?

      Array(profile.capabilities).each_with_object({}) do |cap_name, names|
        provider = @capability_registry.resolve(cap_name, profile: profile, context: context,
                                                           event_stream: @event_stream)
        next if provider.kind == :workflow # exposure to the agent loop is a follow-up

        entry = @tool_registry.entries.find { |e| e.name == provider.impl_name.to_s }
        if entry.nil?
          raise CapabilityError, "capability '#{cap_name}' resolveu para impl " \
                                 "'#{provider.impl_name}', not registered in tool_registry"
        end

        names[entry.name] ||= cap_name.to_s # the 1st capability to claim an impl wins
      end
    end

    # Joins the direct instances (Policy/ToolAllowlist) with the
    # capability-sourced ones (grant = profile.capabilities — they never went
    # through Policy). Avoids double-exposure: if the SAME impl_name was also
    # allowed directly, the DIRECT instance is discarded — the model sees only the
    # capability alias.
    def assemble_tool_instances(allowed, state)
      names = state.respond_to?(:capability_names) ? (state.capability_names || {}) : {}
      ctx = state.respond_to?(:turn_context) ? state.turn_context : nil
      return instantiate_tools(allowed, ctx) if names.empty?

      # Dedup by the ENTRY NAME (registry key = impl_name) BEFORE
      # instantiating — the INSTANCE's `.name` (RubyLLM) is not the registration
      # name.
      direct = Array(allowed).reject { |e| e.respond_to?(:name) && names.key?(e.name.to_s) }
      instantiate_tools(direct, ctx) + capability_tool_instances(names, ctx)
    end

    # impl_name -> Capability::ResolvedTool(capability_name:), STILL without
    # ToolEnvelope (the call site's wrap_tools wraps the whole set — same
    # order impl -> ResolvedTool -> ToolEnvelope). entry already validated in
    # resolve_capabilities.
    def capability_tool_instances(names, turn_context = nil)
      names.map do |impl_name, capability_name|
        entry = @tool_registry.entries.find { |e| e.name == impl_name }
        tool = entry.factory.call
        inject_turn_context(tool, turn_context)
        Capability::ResolvedTool.new(tool, capability_name: capability_name,
                                           impl_name: impl_name)
      end
    end

    # Envelopes each allowed tool (per-call timeout + side-effect recording).
    # The system LoadSkill (configure_chat) is NOT enveloped — it is a system
    # tool with no side-effect and of trivial latency.
    def wrap_tools(tools, state, skip_side_effects = [])
      timeout = state.profile.limits[:tool_timeout] || 60
      tools.map do |tool|
        ToolEnvelope.new(tool, state: state, checkpoint_store: @checkpoint_store,
                               tool_registry: @tool_registry, timeout: timeout,
                               skip_side_effects: skip_side_effects,
                               trace_recorder: @tool_trace_store)
      end
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

      @checkpoint_store.save(Harness::Checkpoint.new(
                               task_id: task.id, turn: state.turn, session_id: task.session_id,
                               agent_id: profile.id, messages: Array(state.context.history),
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))
    end

    # Stage 8: FIXED order checkpoint -> session -> task. If it crashes
    # between writes, the worst case is a new checkpoint with the task :running ->
    # Recovery re-executes the already-saved turn (safe thanks to the side-effect
    # recording).
    def persist_turn(task, profile, state, content)
      new_messages = [
        { role: "user", content: state.message },
        { role: "assistant", content: content }
      ]
      transcript = Array(state.context.history) + new_messages

      @checkpoint_store.save(Harness::Checkpoint.new(
                               task_id: task.id, turn: state.turn + 1, session_id: task.session_id,
                               agent_id: profile.id, messages: transcript,
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))

      # session only when the turn is from a persisted session; one-shot/history
      # do not persist TO THE SESSION (but always checkpoint).
      @session_store.append_messages(task.session_id, new_messages) if task.session_id

      # finish_execution (closes the Execution) BEFORE transition(:completed) —
      # transition without error: does not close, so the finish is needed here.
      @task_store.finish_execution(task.id, outcome: :completed)
      @task_store.transition(task.id, to: :completed)
      # prune is best-effort cleanup: a failure here must NOT re-fail an
      # already-committed turn (the task is already :completed and durable).
      # Swallow.
      begin
        @checkpoint_store.prune(task.id, keep: 1)
      rescue Harness::StoreError
        nil
      end

      emit(:checkpoint_created, { task_id: task.id, turn: state.turn + 1 }, task: task)
    end

    # Stage 6 (factory): the ONLY point that touches the gem. lazy require,
    # confined — not covered by unit (factory line). It also loads the system
    # builtins (load_skill/tool_search/remember) that the ChatBuilder assembles at
    # stage 5 — lazy, so the core installs without ruby_llm.
    def create_chat(profile, state)
      require "ruby_llm"
      require_relative "tools/load_skill"
      require_relative "tools/tool_search"
      require_relative "tools/remember"
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
      @event_stream.emit(Harness::Event.new(
                           type: type, data: data,
                           meta: { task_id: task.id, session_id: task.session_id,
                                   seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
