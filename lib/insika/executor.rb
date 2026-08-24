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
                    delegation_store: nil, channel_delivery: nil, llm: nil,
                    context_trace_store: nil, reliability: nil, media: nil, media_output: nil,
                    grounding_enforcer: nil, cache_series_store: nil,
                    contact_store: nil, followup_store: nil, model_visible_trace_store: nil,
                    knowledge_store: nil)
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
      # per-turn context breakdown (tokens by category + budget) for the
      # Studio session card. nil = off (no record, zero overhead — parity).
      @context_trace_store = context_trace_store
      # the model-visible trace — what the provider received per
      # (task, turn), captured at the chat boundary. nil = off (no record,
      # zero overhead — parity).
      @model_visible_trace_store = model_visible_trace_store
      # Guardrails output filter: ->(state) { OutputFilter | nil }.
      # Injected by the Safety::Factory; nil = off (parity — the stream is untouched).
      # The INPUT guardrail is a Middleware (in the stack, not here); this is the seam
      # for the stream-side redaction the Executor owns.
      @content_filter_factory = content_filter_factory
      # durable record of ASYNC delegations. nil = async
      # delegation OFF (only the synchronous spawn_subagent works — parity). When
      # present, run_subagent(async: true) dispatches + returns immediately and the
      # child's result is delivered to the parent session as a NEW turn on completion.
      @delegation_store = delegation_store
      # outbound delivery for Shape B channels. nil = no channel
      # delivers out of band (parity — every surface today answers on the request's
      # own connection). When present, a turn that CAME IN through a channel writes
      # its answer to the outbox at the terminal and the dispatcher POSTs it.
      @channel_delivery = channel_delivery
      # the chat FACTORY this executor asks — a RubyLLM::Context (an
      # isolated config dup) when the graph owns its credentials, nil = the
      # process-wide RubyLLM constant (the historic single-graph deployment).
      # Duck-typed: Context#chat and RubyLLM.chat take the same keywords.
      @llm = llm
      # stability for the turn's single agent interaction (WS3): retries /
      # fallback / circuit breaker, all DATA on AgentProfile#reliability.
      # nil = the plain single ask (parity).
      @reliability = reliability
      # WS9 media seam (nil = default built on first audio turn): ->(url) { text }.
      @media = media
      # WS9 (saída) media-generation seams: { image: ->(prompt, cfg) [part,
      # usage], tts: ->(text, cfg) [part, usage] }. nil = the defaults (built
      # lazily on first generation — RubyLLM + Net::HTTP behind lazy requires,
      # the core stays gem-free at load). Injected by specs; a production graph
      # that wants a non-RubyLLM backend injects its own lambdas.
      @media_output = media_output
      # the :enforce boundary step, called between stages 6 and 8.
      # Defaults to a REAL enforcer (inert unless the profile's grounding.mode is
      # :enforce — zero behavior change for parity) so an embedder that builds
      # the Executor directly still gets the cut; `nil` stays injectable for
      # stubs that want none.
      @grounding_enforcer = grounding_enforcer || Insika::Safety::GroundingEnforcer.new
      # the per-AGENT cache-hit series. nil = no series recorded
      # (parity — the trace store still gets the per-turn entry when wired).
      @cache_series_store = cache_series_store
      # LLM config v2: resolves the model at turn start (Chat > Agent >
      # platform default) + model_policy + fallback chain. settings_store nil =
      # no platform layer (pre-v2 behavior: the agent's own model is used as-is).
      @model_resolver = ModelResolver.new(settings_store: settings_store)
      # the follow-up stores the ChatBuilder gates the
      # schedule/cancel_followup tools on (nil = never wired — parity).
      @contact_store = contact_store
      @followup_store = followup_store
      # the platform layer of the queue policy (nil = per-agent and
      # defaults only, which is `followup` with no window — today's behavior).
      @settings_store = settings_store
      # LEARNED concepts, extracted from a turn's transcript after it
      # completes. nil = the loop is off (parity — every write path below is
      # skipped, zero allocations). Gated per-agent by `profile.knowledge`.
      @knowledge_store = knowledge_store
      # RubyLLM glue (stages 5-7): chat assembly delegated to ChatBuilder. Its
      # optional deps tool_catalog (Tool Search) and memory_store (cross-session
      # memory) matter only to it — nil = parity (deferred
      # not partitioned; no system remember).
      @chat_builder = ChatBuilder.new(
        tool_registry: tool_registry, skill_catalog: skill_catalog,
        checkpoint_store: checkpoint_store, event_stream: event_stream, hooks: hooks,
        tool_catalog: tool_catalog, memory_store: memory_store,
        # load_skill is not enveloped, so it records its own trace entry.
        tool_trace_store: tool_trace_store,
        # the ChatBuilder wires the spawn_subagent system tool (gated by
        # profile.subagents) and hands it this Executor as the runner. `self` is not
        # yet fully built here, but the ChatBuilder only STORES it (used per-turn).
        subagent_runner: self,
        # WS9 (saída): the media-generation runner, same shape — the Executor
        # owns the seams + usage accounting, the builder only wires the tools
        # the turn's gates allow.
        media_runner: self,
        # the builder wires the briefing-write system tools gated by
        # @session_store + profile.briefing_fields. nil = never wired (parity).
        session_store: session_store,
        # the builder wires the schedule/cancel_followup system
        # tools gated by a parsed policy AND both stores present. nil = never
        # wired (parity).
        contact_store: contact_store,
        followup_store: followup_store
      )
      # Stage-3-tail tool assembly (capability resolution, instantiation,
      # injection, dedup join, ToolEnvelope wrap) — extracted collaborator.
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
      @draining = false        # shutdown drain — see #begin_drain!
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

    # the periodic tick (outbox drain + stale recovery sweep), wired
    # by the graph AFTER the bus exists (the tick's recovery half dispatches
    # through it). nil = no tick (parity — recovery stays boot-only). When
    # present and serving, it starts as a child of the turn supervisor (see
    # #turn_parent).
    attr_accessor :tick

    # The WS6 alert dispatcher: answers budget_warning / breaker_open /
    # delivery_failed with a durable webhook delivery. Started as a child of
    # the turn supervisor in serving mode (like the tick); nil = no alerts.
    attr_accessor :alert_dispatcher

    # the distillation engine — the tick-duty that finds idle
    # customer sessions and distills them on its own worker fiber (a child of
    # the turn supervisor, like the tick). nil = distillation off (parity —
    # nothing scans, nothing distills).
    attr_accessor :distill_engine

    # the harvest engine — the tick-duty that finds idle,
    # unmined sessions and mines them on its own worker fiber (a child of the
    # turn supervisor, like the tick). nil = harvest off (parity — nothing
    # scans, nothing mines).
    attr_accessor :harvest_engine

    # Forces the long-lived turn supervisor (and its tick/alert/distill/harvest
    # children — see #turn_parent) to start NOW instead of lazily on the first
    # served turn. Without this, a deployment whose only agents are scheduled
    # (no live chat) never fires the tick until some unrelated turn happens to
    # land first — observed live as 16+ minutes of silence after a clean boot.
    # Call once, right after `supervised = true`, from the composition root
    # (Server::Boot / config.ru / DSL::ServerBoot). A no-op outside a live
    # reactor (nothing to bind the supervisor to yet) — the lazy path in
    # #turn_parent still covers that case, e.g. specs that never enter Async.
    def start_supervisor!
      turn_parent if @supervised && Async::Task.current?
      nil
    end

    # closes the TURN intake for shutdown. Armed by Insika::Shutdown
    # when the process is asked to stop: from here on a new top-level turn is left
    # `:queued` (durable — the next boot's recovery replays it) instead of
    # spawning, while the in-flight turns run to their natural end. One-way by
    # design: a draining process never takes work again.
    def begin_drain!
      @draining = true
    end

    def draining? = @draining

    # The turns still running in THIS process — what a drain waits on.
    def in_flight = @running.keys

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
    #
    # `timing`  is the channel clock a channel turn allocated at 202
    # acceptance, already carrying `:inbound`; nil means the pipeline allocates its
    # own (resume, engine-initiated, non-channel). `mark` is first-write-wins, so
    # re-marking `:inbound` in the pipeline is a no-op on a threaded clock.
    def spawn(task, profile:, resume_from: nil, timing: nil)
      raise Insika::ValidationError, "task already running: #{task.id}" if running?(task.id)

      actor = TaskActor.new(task_id: task.id, parent: turn_parent)
      @running[task.id] = actor
      actor.run { execute(task, profile: profile, resume_from: resume_from, actor: actor, timing: timing) }
      task.id
    end

    # Turn entry point that RESPECTS the session: a turn with a
    # session_id is SERIALIZED in that session's SessionActor queue (one at a
    # time); without a session_id (one-shot/history) it goes straight to spawn
    # (standalone).
    def spawn_in_session(task, profile:, resume_from: nil, timing: nil)
      # the intake is closed. The task is already durable (queued);
      # answering with its id and spawning NOTHING is what "stops accepting new
      # turns" means — the next boot's recovery replays it. Subagent turns are NOT
      # gated (they spawn directly): a child of an in-flight parent is part of the
      # work the drain is waiting FOR, and refusing it would wedge the parent.
      return defer_turn(task) if @draining

      # SessionActor only in SERVING mode (@supervised): serializes concurrent
      # REQUESTS. At boot/recovery (non-supervised) the replay is sequential and
      # the long-lived loop would hang the Boot's Sync — use direct spawn (the
      # owner awaits the turn). One-shot/history (no session_id)
      # never serialize.
      unless @supervised && task.session_id
        return spawn(task, profile: profile, resume_from: resume_from, timing: timing)
      end

      session_actor(task.session_id).enqueue(task, profile: profile, resume_from: resume_from,
                                                   policy: queue_policy(profile, task.session_id),
                                                   timing: timing)
    end

    # the `collect` door, asked BEFORE a task is created.
    # -> the task id the fragment joined, or nil (create a task and spawn as usual).
    #
    # Asking first is what keeps the store clean: creating a task and then
    # discarding it would leave an orphan :queued record for every fragment, and
    # `queued` is what Recovery replays at boot.
    def collect_into_pending(session_id, text, profile:)
      return nil unless @supervised && session_id

      policy = queue_policy(profile, session_id)
      return nil unless policy.collect? && policy.debounce?

      actor = @session_actors[session_id]
      return nil unless actor&.alive?

      actor.collect(text)
    end

    # the `steer` door: a message for a session whose turn is ALREADY
    # running is appended to that run instead of becoming a turn of its own.
    # -> the RUNNING task's id (the turn that will answer it), or nil (create a task and
    # spawn as usual, which is `followup`).
    #
    # Asked BEFORE a task is created, like the `collect` door, and for the same reason.
    # The post lands in the turn's mailbox; `SteerInjector` reads it at the next
    # tool-batch boundary. Nothing here touches the run in flight — a message that no
    # boundary ever arrives for is released as a follow-up turn (#release_steered).
    def steer_into_running(session_id, text, profile:)
      return nil unless @supervised && session_id

      policy = queue_policy(profile, session_id)
      return nil unless policy.steer?

      session_actor = @session_actors[session_id]
      return nil unless session_actor&.alive?

      # No turn running (or one still at the door): there is nothing to steer INTO.
      # A turn at the door is the collect door's other window — a steer agent with a
      # debounce merges there instead , so no message waits on either.
      task = session_actor.current_task
      return nil if task.nil?
      # A workflow turn orchestrates RubyLLM itself and has no Insika chat to append to
      # (docs/WORKFLOWS.md says so). Refused at the door so the message becomes an
      # ordinary next turn instead of a phantom one.
      return nil if workflow_turn?(task)

      actor = @running[task.id]
      return nil if actor.nil?
      # The bound is on what ONE run may absorb, so it counts posts and not the buffer:
      # a message already injected still spent its slot. Overflow degrades to
      # `followup` rather than growing an unbounded tail.
      return nil if actor.user_messages_posted >= policy.steer_max_messages

      actor.post(:user_message, text)
      task.id
    end

    # the `interrupt` door: the turn in flight is answering a question
    # the customer has already replaced, so it is abandoned and the new message becomes an
    # ordinary turn. -> the abandoned task's id, or nil (nothing was running).
    #
    # Unlike `collect`/`steer` this one JOINS nothing: `replaced_by` already has its own
    # task and its own reply, so there is no verdict to report and every surface can use
    # it, `/v1/responses` included.
    #
    # What "abandon" means here is Insika's existing cancellation semantics, unchanged:
    # `:cancel` is observed only at a stage boundary, so a tool call in flight runs to
    # completion and is recorded. Cancelling the not-yet-started calls of a batch would
    # leave it half applied, and fabricating failure results would teach the model that
    # tools failed when they did not (records the same boundary for `turn_timeout`).
    def interrupt_running(session_id, profile:, replaced_by: nil)
      return nil unless @supervised && session_id

      return nil unless queue_policy(profile, session_id).interrupt?

      session_actor = @session_actors[session_id]
      return nil unless session_actor&.alive?

      task = session_actor.current_task
      return nil if task.nil?

      actor = @running[task.id]
      return nil if actor.nil?

      actor.post(:cancel)
      emit(:turn_interrupted, { task_id: task.id, replaced_by: replaced_by }, task: task)
      task.id
    end

    # The SessionActor writes the merged fragment through this (it has no store of
    # its own, by design — it owns scheduling, not persistence).
    attr_reader :task_store

    # Emitted by the SessionActor when a window closes having merged
    # more than one fragment. `arrivals` are the ISO8601 times each fragment landed
    # — the ONLY record that they were separate messages, since a merged fragment
    # creates no task of its own. Ids and times, never content.
    def emit_coalesced(task, merged:, arrivals: [])
      emit(:turn_coalesced, { task_id: task.id, merged: merged, arrivals: arrivals }, task: task)
    end

    # a steered message the run could NOT absorb: no tool batch ever
    # closed (a text-only turn), the batch ended in `halt_when`, the turn failed, or it
    # was cancelled. The message is a person's and must not evaporate, so it is released
    # as the next turn on this session — which is `followup`, arrived at late.
    #
    # Runs in `execute`'s ensure, on the dying turn's fiber: `spawn_in_session` only
    # enqueues, and the session loop is still awaiting THIS turn, so the follow-up runs
    # after it, in order.
    def release_steered(task, profile, actor)
      # Cheap gate first: a turn nobody steered pays one integer read and no store round
      # trip, which is every turn on every agent that never turned the mode on.
      return unless actor.user_messages_posted.positive?

      # Only a turn that actually FINISHED releases. A process going down (Async::Stop
      # through this ensure) leaves the task `:running` for Recovery to replay, and
      # spawning a follow-up during shutdown would parent a turn on a supervisor that is
      # already stopping. The honest limitation: a steered message lives in memory until a
      # boundary writes it to the transcript, so a hard stop in that window loses it.
      current = @task_store.find(task.id)
      return unless current && TERMINAL_STATUSES.include?(current.status)

      texts = actor.take_user_messages!
      return if texts.empty?

      command = Insika::Command.build(
        :send_message,
        # No `origin`: a person typed this, which is exactly what an absent origin means.
        { "agent" => profile.id, "message" => texts.join("\n"), "session_id" => task.session_id }
      ).to_h
      follow_up = @task_store.create(command: command, session_id: task.session_id)
      emit(:turn_steer_released, { task_id: task.id, released_as: follow_up.id, count: texts.size },
           task: task)
      spawn_in_session(follow_up, profile: profile)
    rescue Insika::Error
      # Best-effort: the turn is already terminal and durable, and a store that refuses
      # here must not turn a committed turn into a failed one. The message is then lost,
      # and the ABSENCE of :turn_steer_released is what says so — there is no half state.
      nil
    end

    # Runs ONE turn serially (called by the SessionActor loop):
    # spawns (the turn is born a child of the supervisor, non-blocking) and AWAITS
    # its completion before returning — that is what serializes the session. A
    # turn error is already mapped to a terminal state inside its own fiber (single
    # capture); here we only ensure the session loop does not die.
    def run_serial(task, profile:, resume_from: nil, timing: nil)
      # a drain that started with turns already queued behind this
      # session's current one must not keep feeding the loop — without this gate
      # the drain would only converge when the whole backlog ran out.
      return defer_turn(task) if @draining

      spawn(task, profile: profile, resume_from: resume_from, timing: timing)
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

    # runs a CHILD agent turn (called by Tools::Subagent during
    # stage 6). Isolated context (fresh child session), capability NON-inheritance
    # (child profile resolved fresh), environment inheritance (model/thinking seeded
    # from the parent). NEVER raises: a bad agent/depth/child failure is a message
    # to the model, not a turn-killer.
    #
    # async:false (default) — SYNCHRONOUS: runs the child inside the parent's
    #   fiber and returns { text:, session_id: } (the child result is the tool result).
    # async:true — DURABLE dispatch: spawns the child NON-blocking, persists
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

    # (fan-out): runs SEVERAL child turns IN PARALLEL and returns all
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

    # (boot): reconciles ASYNC delegations after a crash so a
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

    # (boot): re-drives the outbound replies a previous process
    # recorded and never claimed. Records left `delivering` are NOT swept — that
    # process may have POSTed before it died, and re-sending is the duplicate the
    # claim exists to prevent. No-op without a channel_delivery.
    # -> { dispatched: [ids] }
    def recover_channel_deliveries
      return { dispatched: [] } unless @channel_delivery

      @channel_delivery.sweep
    end

    # Stages 2..9. Runs INSIDE the task's fiber.
    def execute(task, profile:, actor:, resume_from: nil, timing: nil)
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
      run_pipeline(task, profile, actor, resume_from, timing)
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
    rescue BudgetExceeded => e
      # WS2 hard budget: a typed, retryable failure — the envelope reads
      # budget_exceeded + retry_after (window roll), never a silent drop.
      fail_task(task, e, stage: :budget)
    rescue CircuitOpenError => e
      # WS3 breaker: the turn died BEFORE the provider call — the envelope
      # reads circuit_open + retry_after (cooldown remaining). Worth its own
      # stage: an open breaker is a reliability decision, not an error bug.
      fail_task(task, e, stage: :reliability)
    rescue Insika::RoutingError => e
      # WS4: a route's delegate is missing or its turn failed — an operator
      # config error, staged so the envelope names routing, never :unknown.
      fail_task(task, e, stage: :routing)
    rescue Insika::MediaError => e
      # WS9: a voice message that could not be fetched/transcribed (or a media
      # URL the egress guard refused) — heard-loud, never a silent drop.
      fail_task(task, e, stage: :media)
    rescue Insika::WorkflowSchemaError => e
      # a workflow OUTPUT that violates its output_schema. Distinct
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
      # A provider/transport failure is NOT an :unknown bug: wrap it with its
      # action classification (B9) so the envelope can quote retryable and the
      # provider's own retry_after (A8). The classifier is class-name based —
      # the :ruby_llm stage stays reachable even under the smoke-shim's fake.
      if ProviderErrorClassifier.provider_error?(e)
        fail_task(task, ProviderErrorClassifier.wrap(e), stage: :ruby_llm)
      else
        fail_task(task, e, stage: :unknown)
      end
    ensure
      @running.delete(task.id) # ALWAYS deregister (a false-positive running? would break the resume)
      # Deregistered FIRST on purpose: from here on the `steer` door finds no actor for
      # this session and answers nil, so a message arriving during the release becomes
      # its own turn instead of a post into a mailbox nobody reads again.
      release_steered(task, profile, actor)
    end

    # WS9 (saída), the RUNNER side the generate_image/tts system tools call
    # (public like run_subagent — a tool reaches back into the Executor):
    #
    # -> [part, usage]: resolve the seam (injected or the lazy default) and
    # run it. The default seams are built on FIRST use, when the turn already
    # has a chat (ruby_llm loaded), so the load-guard holds.
    def generate_media_output(kind, content, config)
      seam = @media_output&.fetch(kind, nil) || Insika::Media::Output.defaults(context: @llm)[kind]
      raise Insika::MediaError, "no #{kind} output seam" unless seam

      seam.call(content, config)
    end

    # Accounts a generated part in the turn's usage: the provider's token
    # counts (images — the merge keeps what the classifier already banked),
    # plus an honest `media` call counter per part (the speech API reports no
    # tokens; the part itself carries the model for consumer-side pricing).
    def account_media_usage(state, part, usage)
      usage ||= {}
      tokens = {}
      tokens[:input_tokens] = usage[:input_tokens].to_i if usage[:input_tokens]
      tokens[:output_tokens] = usage[:output_tokens].to_i if usage[:output_tokens]
      tokens[:total_tokens] = tokens[:input_tokens].to_i + tokens[:output_tokens].to_i if tokens.any?
      unless tokens.empty?
        tokens[:model] = part["model"] if part["model"]
        state.usage = merge_usage(tokens, state.usage)
      end
      state.usage = (state.usage || {}).merge(media: state.usage&.fetch(:media, 0).to_i + 1)
    end

    private

    # resolves session vars > profile.limits > settings["queue"] >
    # defaults. One session read plus one settings read per message, the same
    # order of cost the EdgeLimiter already pays per turn. A missing session (or
    # no session store) simply drops the vars layer.
    def queue_policy(profile, session_id)
      vars = session_id && @session_store&.find(session_id)&.vars
      QueuePolicy.resolve(profile, settings_store: @settings_store, vars: vars)
    end

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

    # a turn that arrived while the process is draining: left
    # `:queued` on purpose (recovery replays :queued at the next boot). The event
    # is the deferral's only trace — without it, "why was my message answered
    # only after the deploy" is unanswerable.
    def defer_turn(task)
      emit(:turn_deferred, { task_id: task.id }, task: task)
      task.id
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
      # stopped (server shutdown) — then any child turns still running go with it.
      # In a deployment that is the LAST resort, not the plan: Insika::Shutdown
      # drains first, so only what outlives the drain deadline dies
      # here, `:running`, for the next boot's recovery to replay.
      @supervisor = node.async { |t| t.annotate("harness-turn-supervisor"); Async::Queue.new.dequeue }
      # the periodic tick is a child of the supervisor — it binds to
      # the serving reactor in every arm with no arm edits, and dies with the
      # supervisor at shutdown (after Shutdown's drain, like any turn).
      @tick&.start(parent: @supervisor)
      # the alert dispatcher (WS6) lives on the same supervisor: its consumer
      # answers every alert event for as long as the process serves.
      @alert_dispatcher&.start(parent: @supervisor)
      # the distillation engine  lives on the same supervisor —
      # its worker fiber re-scans idle sessions off the turn path.
      @distill_engine&.start(parent: @supervisor)
      # the harvest engine  lives on the same supervisor — its
      # worker fiber re-scans idle sessions off the turn path.
      @harvest_engine&.start(parent: @supervisor)
      @supervisor
    end

    # Deterministic PendingAction id: correlation by task+turn+tool.
    # Limitation inherited from the side-effect: the SAME tool with approval more
    # than once in a turn collides (the 2nd reuses the 1st's decision) — per-step
    # checkpointing is a future slice. One call per tool is safe.
    def pending_id(task_id, turn, tool) = "#{task_id}:#{turn}:#{tool}"

    # all readings of the persisted command go through rebuild_command
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

      # The task's error record and the :task_failed event both carry the
      # classification when the failure is a wrapped ProviderError (B9/A8):
      # additive fields, absent for every other error.
      classification = error.respond_to?(:classification) ? error.classification : {}
      spec = { class: error.class.name, message: error.message, stage: stage }
      spec = spec.merge(classification) unless classification.empty?
      @task_store.transition(task.id, to: :failed, error: spec)
      data = { task_id: task.id, error: error.class.name, message: error.message }
      data = data.merge(classification) unless classification.empty?
      emit(:task_failed, data, task: task)
      # a FAILED delegation child still delivers — the parent
      # receives an error note as a new turn (never left hanging).
      finalize_delegation(task)
      nil
    end

    TERMINAL_STATUSES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATUSES

    # Stages 2-9, with mailbox drain only at the boundaries and the
    # turn-timeout wrapping everything via Async::Task#with_timeout — NEVER
    # stdlib Timeout.timeout.
    def run_pipeline(task, profile, actor, resume_from, timing = nil)
      # a CHANNEL turn always allocates the clock — first_balloon_ms
      # (inbound -> first outbox flush) is H-latência and must not depend on
      # INSIKA_TURN_TIMING. When the flag is off the clock measures ONLY that
      # window (`breakdown: false`); the full prep/ttft/gen/total stays opt-in.
      #
      # A channel turn may already carry its clock: `SendMessage` stamped
      # `:inbound` at 202 acceptance (before the debounce window and the
      # SessionActor FIFO), so first_balloon_ms includes the wait the customer
      # actually feels. A turn that reached here without one (boot resume,
      # engine-initiated) falls back to allocating and stamps now — `mark` is
      # first-write-wins, so a threaded clock is never re-stamped.
      channel_turn = !channel_transport(task).nil?
      timing ||= if TurnTiming.enabled? || channel_turn
                   TurnTiming.new(breakdown: TurnTiming.enabled?)
                 end
      timing&.mark(:inbound) if channel_turn
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
        #   · halt_response set -> GRACEFUL halt: the turn COMPLETES
        #     with a safe reply, reusing stages 8-9, without ever touching the LLM.
        #   · halt_reason set    -> halt-as-FAILURE (the pre-existing contract).
        #   · neither            -> contract violation (short-circuit with no signal).
        if !terminal_ran && state.halt_response
          complete_with_halt(task, profile, state, timing)
        elsif state.halt_reason
          raise Insika::Error, "turn halted: #{state.halt_reason}"
        elsif !terminal_ran
          raise Insika::Error, "middleware short-circuited without halt_reason"
        end

          state # subject of the :task pair (after_task receives it; the caller discards)
        end.tap do |st|
          # flush the evidence ledger HERE — after the after_task
          # hooks ran, because the :flag validator increments the ungrounded
          # counter in after_task. The envelope's ids (stage 6) ride the same
          # flush. AFTER persist_turn (already done), so a flush failure can
          # never un-commit the turn (the ledger swallows store errors).
          st.evidence_ledger&.flush!
          emit_guardrail_flags(task, st)
        end
      end
    rescue Async::TimeoutError
      raise Insika::TimeoutError.new("turn exceeded #{turn_timeout}s", stage: :turn)
    end

    # Builds the turn's mutable state (turn number, message, memory tenant,
    # turn context). before_task (hooks.around) may still rewrite it before stage 2.
    def build_turn_state(task, profile, resume_from)
      turn = resume_from ? resume_from.turn : 1
      state = TurnState.new(task: task, profile: profile, turn: turn,
                            message: extract_message(task))
      state.tenant = memory_tenant(task) # WRITE-path memory scope (`remember`); =chat
      stamp_customer_session(task, profile)
      state.turn_context = build_turn_context(task, profile, state) # data-tools' ctx.*
      state.resumed = !resume_from.nil? # EdgeLimiter: an admitted turn is never re-counted
      # resolved for the RUN, not per message, so what the turn accepts cannot
      # change under it. Same cost as the EdgeLimiter's per-turn resolution. Only for a
      # SESSION turn: steering needs a session to arrive through, and resolving here for a
      # one-shot would make an unrelated turn fail on a queue key it can never use.
      state.queue_policy = task.session_id ? queue_policy(profile, task.session_id) : nil
      # the session evidence ledger, built per turn. A nil
      # session_id (one-shot) is fine — the ledger just never flushes (grounding
      # on a one-shot is per-turn by definition). The envelope appends ids, the
      # validator/enforcer read the union, stage 8 flushes.
      state.evidence_ledger = Insika::EvidenceLedger.new(store: @session_store,
                                                         session_id: task.session_id)
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
      # WS9 (saída): the CHANNEL's declared output media kinds — read on EVERY
      # run (including resumes — it is plain config) so the ChatBuilder gate
      # can re-wire the media tools; the transcription below stays guarded.
      state.channel_capabilities = Insika::Media.channel_capabilities(
        rebuild_command(task).payload["channel"]
      )
      # WS9: content parts -> turn. Runs BEFORE stage 2's context build so the
      # transcribed voice text feeds the prompt; a resumed turn was already
      # transcribed (never re-pay the STT call).
      run_media_stage(task, state) unless state.resumed

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
      record_context_trace(task, state)
      announce_context_skills(task, state)
      drain_and_maybe_suspend(task, actor)
    end

    # one entry per turn in the ContextTraceStore — tokens per
    # category (the demodulized provider id), the tools-schema estimate and the
    # budget verdict. the entry also carries the prefix
    # fingerprints + the invalidation_reason vs the previous turn, and the
    # categories gain their cache layer. Counts and ids ONLY, never content.
    # nil store = off; the store itself rescues everything (the trace never
    # breaks the turn). -> the sanitized entry (parked on TurnState for the
    # stage-8 cache stamp).
    def record_context_trace(task, state)
      return unless @context_trace_store && task.session_id

      package = state.context
      # A custom builder that does not produce the full package (fragments +
      # budget) simply has no breakdown to record — never an error.
      return unless package.respond_to?(:fragments) && package.respond_to?(:budget)

      categories = package.fragments.each_with_object({}) do |f, acc|
        c = (acc[context_category(f.source)] ||= { tokens: 0, fragments: 0, pinned: 0 })
        c[:tokens] += f.tokens || 0
        c[:fragments] += 1
        c[:pinned] += (f.tokens || 0) if f.pinned
        # the category's cache layer (identity | :volatile —
        # stamped by the Builder at production, C3).
        layer = f.layer || :volatile
        c[:layer] ||= layer
        # WHICH skills/tools the fragment carried and WHY — ids only, still
        # content-free. Without this the trace proves a turn injected N tokens of
        # skill but not which ones, and deterministic activation is unauditable
        # after the fact.
        labels = Array(f.labels)
        (c[:labels] ||= []).concat(labels) unless labels.empty?
      end
      # the prefix chain over the SYSTEM-placement fragments in
      # canonical (identity-first) render order + the tool-schema serialization.
      # The reason is computed against the PREVIOUS trace entry (D3): the first
      # category, in current chain order, whose bytes changed (or vanished).
      previous = previous_trace_entry(task, state.turn)
      fingerprints = Insika::PrefixFingerprint.compute(
        Array(package.fragments).select { |f| f.placement == :system },
        tool_serial: serialize_tools(state.allowed_tools))
      reason = Insika::PrefixFingerprint.invalidation_reason(
        fingerprints, previous && previous["fingerprints"])

      entry = { task_id: task.id, turn: state.turn, at: Time.now.utc.iso8601,
                cap: package.budget[:cap], used: package.budget[:used],
                evicted: package.budget[:evicted], categories: categories,
                tools: { count: state.allowed_tools.size,
                         tokens: estimate_tools_tokens(state.allowed_tools) },
                fingerprints: fingerprints,
                cache: { invalidation_reason: reason } }
      # Park the SANITIZED entry (string keys) — the stage-8 stamp merges into
      # it and re-records the same key; a raw entry would add a SECOND "cache"
      # key that sanitize would then ignore (the symbol one wins).
      state.context_trace_entry = @context_trace_store.record(session_id: task.session_id,
                                                              entry: entry)
    end

    # the previous turn's trace entry — the session list minus
    # THIS (task_id, turn) (an approval-resumed turn re-records over its own key
    # — never compare to self). `turn` is the turn being recorded, passed
    # explicitly. -> Hash | nil (first turn of the session).
    def previous_trace_entry(task, turn)
      @context_trace_store.for_session(task.session_id)
                           .reject { |x| x["task_id"] == task.id && x["turn"] == turn }
                           .last
    end

    # the tool-schema yardstick — the SAME serialization the token
    # estimate uses (estimate_tools_tokens), so the fingerprint and the estimate
    # never disagree. The digest covers name + description + parameters.inspect,
    # approximating RubyLLM's rendering (honest in the doc: the reason's job is
    # the CONTEXT categories; the tool hash is a guard rail).
    def serialize_tools(tools)
      tools.map { |t| "#{t.name} #{t.description} #{t.parameters.inspect}" }.join(" ")
    end

    # the stage-8 stamp — the usage (cached_tokens,
    # input_tokens) only exists after the provider answered, so a SECOND
    # UPSERT with the SAME (task_id, turn) merges the cache fields into the
    # entry parked at prepare_turn (the start-of-turn write stays: a turn that
    # dies mid-flight still shows its context on the Studio screen). The same
    # numbers append one entry to the agent's CacheSeriesStore (C6).
    def stamp_cache_hit(task, state)
      usage = state.usage || {}
      input = usage[:input_tokens].to_i
      cached = usage[:cached_tokens].to_i
      creation = usage[:cache_creation_tokens].to_i
      # A4: the billed prefix is input + cached + cache_creation. RubyLLM's
      # input_tokens is the FRESH input only — cached_tokens is disjoint, not a
      # subset — so dividing by input alone yields absurd numbers (22000/500 =
      # 4400%) and renders a full hit as "—" (fresh=0). The denominator is the
      # whole billed prompt; hit_pct is then always in [0,100].
      billed = input + cached + creation
      hit = billed.positive? ? ((cached * 100.0) / billed).round : nil
      reason = state.context_trace_entry&.dig("cache", "invalidation_reason")

      # The trace merge needs the entry parked at prepare_turn (the UPSERT
      # replaces the same (task_id, turn)); a failed trace write leaves it nil
      # and the cache line simply never lands — never a turn failure.
      if @context_trace_store && state.context_trace_entry && task.session_id
        @context_trace_store.record(
          session_id: task.session_id,
          entry: state.context_trace_entry.merge("cache" => {
            "hit_pct" => hit, "cached_tokens" => cached, "prompt_tokens" => billed,
            "invalidation_reason" => reason }))
      end

      # The per-agent series is INDEPENDENT of the trace store: a deployment
      # that wires the series without the trace (or whose trace write failed)
      # still records its cache-hit numbers — reason is simply nil then.
      @cache_series_store&.record(agent: state.profile.id, entry: {
        at: Time.now.utc.iso8601, turn: state.turn,
        hit_pct: hit, cached_tokens: cached, prompt_tokens: billed,
        invalidation_reason: reason })
    end

    # Skill bodies that reached the prompt WITHOUT a tool call (`triggers:` or
    # `skills_eager`) leave no trace in the transcript: there is no load_skill to
    # render, so an active skill looked exactly like an absent one.
    #
    # Emitted HERE rather than in the provider because only the Executor holds the
    # correlation the Studio's SSE filters on — an event whose meta lacks `task_id`
    # never reaches a task-scoped subscriber (EventStream::Subscription#matches?).
    # `skills` (plural, with reasons) marks the CONTEXT path; the load_skill tool
    # emits the same type with a singular `name`, and the Studio must not conflate them.
    #
    # Read from `package.fragments`, which is POST-BUDGET: a body the cut evicted is
    # not in the prompt, and announcing it as active would make the one surface built
    # to tell the truth the one that lies. Eviction is reported by the trace's own
    # `evicted` list, never as an activation.
    SKILL_BODY_CATEGORY = "skilltrigger"

    def announce_context_skills(task, state)
      package = state.context
      return unless package.respond_to?(:fragments)

      skills = Array(package.fragments)
               .select { |f| context_category(f.source) == SKILL_BODY_CATEGORY }
               .flat_map { |f| Array(f.labels) }
               .map { |l| { name: l["name"], reason: l["reason"] || "pack" } }
               .uniq
      return if skills.empty?

      emit(:skill_activated, { skills: skills, source: "context" }, task: task)
    end

    # "Insika::Context::Providers::Prompt" -> "prompt" (a plugin provider keeps
    # its own demodulized name — still content-free).
    def context_category(source) = source.to_s.split("::").last.to_s.downcase

    # Same yardstick as the fragments (TokenEstimator), so the categories are
    # comparable. `parameters` is not guaranteed JSON-safe — inspect it.
    def estimate_tools_tokens(tools)
      TokenEstimator.estimate(tools.map { |t| "#{t.name} #{t.description} #{t.parameters.inspect}" }.join(" "))
    rescue StandardError
      0
    end

    # Stages 5-9 (inside the Middleware wrap): assemble chat, the single agent
    # interaction, persistence, terminal event. `st` is the Middleware-yielded state.
    def run_turn_body(task, profile, st, actor, timing = nil)
      # stage 5: assemble chat + check mailbox (send_message only; a workflow does
      # not use the Insika chat — it orchestrates RubyLLM internally).
      drain_and_maybe_suspend(task, actor)
      # WS4: intent routing, data-gated. Runs BEFORE the agent chat is assembled:
      # a route that delegates or ends :stuck completes the turn with no ask at
      # all (routed = true); a plain route is a label + event and the turn
      # proceeds. Skipped for workflows (no chat to route into) and resumed turns
      # (already admitted; re-classifying would re-pay the extra call).
      routed = !workflow_turn?(task) && !st.resumed ? attempt_route(task, profile, st) : false
      unless workflow_turn?(task) || routed
        st.chat = create_chat(profile, st)
        @chat_builder.assemble(st.chat, st, emit: ->(type, data) { emit(type, data, task: task) })
        # R1: baseline = seeded-history size, before `ask` appends the turn.
        st.chat_baseline = Array(st.chat.messages).size if st.chat.respond_to?(:messages)
      end

      # guardrails: per-turn stream redactor (nil = off).
      st.output_filter = @content_filter_factory&.call(st)

      # stage 6: the turn's single agent interaction (send_message -> chat.ask;
      # trigger_workflow -> workflow.call). A routed turn's content IS its route
      # action's answer (a delegate's reply or the stuck lead-in).
      content = routed ? st.response_content : run_agent_stage(task, st, timing)
      st.response_content = content # after_task OutputValidator inspects this

      # the model-visible record — what the provider received this
      # turn, captured at the boundary BEFORE stage 8 persists the checkpoint
      # (turn n's provider-visible stream == checkpoint(turn n+1).messages).
      # Skipped for workflows (they orchestrate RubyLLM inside the workflow
      # body — the engine cannot see those calls, stated in the conformance
      # scope) and absent-store runs (parity).
      record_model_visible(task, st) if !workflow_turn?(task) && st.chat

      # the :enforce boundary — a CUT of the final content BEFORE
      # persistence/delivery (after_task fires too late to change what is
      # persisted). The cut text is what persists, delivers and terminates.
      if @grounding_enforcer
        content, st = @grounding_enforcer.call(task, st, content)
        st.response_content = content
      end

      # stage 8: Persistence (fixed order checkpoint->session->task). pure drain!
      # (NEVER suspends at stage 8 — forbidden window): a :pause here arms the flag
      # but is not honored (last stage); :cancel here still raises.
      actor.drain!
      persist_turn(task, profile, st, content, timing: timing)

      # the cache-hit stamp — the usage exists only now. The
      # stamped entry is durable before anything is delivered (same slot as the
      #   enforcer). Best-effort by construction (both stores rescue).
      stamp_cache_hit(task, st)

      # stage 9: Response. usage (tokens) captured at stage 6 travels in the
      # terminal event -> /v1/responses usage + Telemetry (OTEL).
      timing&.mark(:done)
      data = { task_id: task.id, content: content, usage: st.usage }
      # WS4: the intent route rides the terminal additively (like outcome) — a
      # consumer aggregating by route does not need the stream.
      data[:route] = st.route.to_s if st.route
      # WS9: a turn whose message came from a VOICE note is marked — the
      # consumer's signal the person spoke (text was transcribed).
      data[:source] = :voice if st.message_source == :voice
      # WS9 (saída): media the agent GENERATED this turn (image/audio clips).
      # Additive sibling — the answer text stays text on purpose; the channel
      # consumes the parts next to it. Absent when nothing was generated.
      data[:output_parts] = st.output_parts if st.output_parts && !st.output_parts.empty?
      data[:timing] = timing.to_h if timing # opt-in TTFB breakdown (INSIKA_TURN_TIMING)
      # best-effort persist of the same timing onto the task record —
      # the Studio task page reads it from there. A failure here must not re-fail
      # the turn (the task is already committed and the event already carries it).
      persist_turn_timing(task, timing)
      # WS5: the agent declared it cannot proceed (signal_stuck). The turn still
      # COMPLETES (its final message was published) — but the consumer must be able
      # to act on that, so the contract carries it twice: a dedicated :turn_stuck
      # event (subscribable) and an additive `outcome` sibling on the terminal event.
      if (stuck = st.stuck_outcome)
        emit(:turn_stuck, { task_id: task.id, agent: profile.id.to_s,
                            reason: stuck[:reason], message: content }, task: task)
        data[:outcome] = :stuck
      end
      emit(:task_completed, data, task: task)
    end

    def workflow_turn?(task)
      command_type(task).to_s == "trigger_workflow"
    end

    # the model-visible record of ONE ask — the chat at the
    # provider boundary (instructions + tool schemas + the message stream),
    # persisted under the checkpoint's turn number (turn n's stream ==
    # checkpoint(turn n+1).messages). Best-effort: the store rescues
    # everything, and the absent-store path is parity. `chat` defaults to the
    # turn's own chat; the routing classifier passes its own.
    def record_model_visible(task, st, chat = nil, part: "turn")
      return unless @model_visible_trace_store

      c = chat || st.chat
      return unless c

      @model_visible_trace_store.record(
        task_id: task.id, turn: st.turn + 1, part: part,
        payload: Insika::ModelVisible.capture(c))
    end

    # Stage 6: the single agent interaction. Returns the turn's final content.
    def run_agent_stage(task, state, timing = nil)
      if workflow_turn?(task)
        # workflow = a Ruby callable that orchestrates RubyLLM internally (RubyLLM
        # First). tools: are the SAME instances filtered by the Resolution and
        # enveloped (stage 7) — the workflow inherits timeout/side-effect/skip.
        # the EXPOSED surface — the run (== task.id) is announced on
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
        filter = state.output_filter # nil = off (stream untouched)
        timing&.mark(:ask)
        # TurnOutput owns what the customer is allowed to read: chunks ride
        # :intermediate live and only the message that ENDS the turn is published as
        # :content. Registered on the chat (fresh per turn/attempt, no leak).
        # With WS3 reliability the attempts build their own chats + outputs.
        output = nil
        asked = nil
        response = @hooks.around(:agent, state) do |s|
          result = @reliability ? run_reliable_ask(task, s, filter, timing)
                                : run_single_ask(task, s, filter, timing)
          output = result[:output]
          asked = result[:asked]
          result[:response]
        end
        # release the redactor's retained tail (a value that never completed into a
        # match is emitted redacted-if-needed, not lost) before reading anything back.
        output.flush
        # MERGED, not overwritten: a WS4 routing call already banked its tokens in
        # state.usage before the ask — the classifier's cost must survive the ask
        # (it feeds the EdgeLimiter's ceiling/budget and the terminal usage).
        unless halted?(response)
          state.usage = merge_usage(with_model_source(usage_of(response), state.model_selection),
                                    state.usage)
        end

        # BOUNDARY BEFORE THE ANSWER GOES OUT. A cancel that arrived while the provider
        # was working used to be observed at stage 8 — AFTER `:content` had already been
        # published — so the customer read the answer of a turn that then terminated
        # `:cancelled` and persisted nothing: text delivered, transcript silent about it.
        # Honoring it here is what makes `interrupt` mean anything, and it
        # is a safe boundary: the tool batch is finished and nothing is half applied.
        # A `:pause` is deliberately NOT honored here (drain!, not the suspending form):
        # holding a completed answer for an operator would strand it unpublished.
        state.actor&.drain!

        output.publish(turn_answer(response, asked, output, filter))
      end
    end

    # stage 6, plain path: the single ask on the assembled chat. Fresh TurnOutput
    # + steer wiring per interaction (registered on state.chat, which the solve
    # already assembled). -> { response:, asked:, output: }.
    def run_single_ask(task, state, filter, timing)
      output = new_turn_output(task, state, filter)
      wire_chat_output(task, state, output)
      asked = ask_on(task, state, state.chat, output, timing)
      { response: asked, asked: asked, output: output }
    end

    # stage 6, WS3 path: the Reliability coordinator drives retries, backoff,
    # circuit breaker and the fallback rotation. Each ATTEMPT gets a fresh chat
    # + output (a failed `ask` leaves its message in the chat, so re-asking the
    # same one would double the input) and, on a fallback, state.model_selection
    # follows — the turn's usage is attributed to the model that actually spoke
    # ("contabilizado no trace"). -> { response:, asked:, output: }.
    def run_reliable_ask(task, state, filter, timing)
      policy = state.profile.respond_to?(:reliability) ? state.profile.reliability : nil
      return run_single_ask(task, state, filter, timing) if policy.nil? || @reliability.nil?

      attempt_output = nil
      attempt_asked = nil
      primary = state.model_selection
      response = @reliability.call(
        policy: policy, tenant: task_tenant(task), agent: state.profile.id.to_s,
        selection: primary, chain: reliability_chain(state)
      ) do |selection, tries|
        first_attempt = state.chat && selection == primary && tries == 1
        if selection != primary
          state.model_selection = selection # attribution follows the fallback
        end
        unless first_attempt
          chat = build_attempt_chat(state, selection)
          state.chat = chat
        end
        attempt_output = new_turn_output(task, state, filter)
        wire_chat_output(task, state, attempt_output)
        attempt_asked = ask_on(task, state, state.chat, attempt_output, timing)
        attempt_asked
      end
      { response: response, asked: attempt_asked, output: attempt_output }
    end

    # The fallback chain for WS3: profile's `reliability["fallback"]` refs first,
    # then the platform-resolved fallbacks (ModelSelection). Each node is a
    # ModelSelection (the SAME duck the primary is — usage attribution and
    # apply_params just work), source: :fallback, params inherited from the
    # primary. Deduped by ref, primary excluded.
    def reliability_chain(state)
      primary = state.model_selection
      refs = Array((state.profile.reliability || {})["fallback"]).map(&:to_s)
      nodes = refs.filter_map { |r| parse_model_ref(r) }.reject { |n| n[:model].to_s.empty? }
      nodes.concat(Array(primary.fallbacks).map { |f| { model: f[:model], provider: f[:provider] } })
      seen = { ref_of(primary) => true }
      nodes.filter_map do |node|
        ref = model_ref(node)
        # normalize "model" vs "provider/model": a provider-less ref IS the same
        # physical model as any known "provider/model" spelling of it — the same
        # model must never be tried twice just because one spelling omits the
        # provider (WS3: fallback ["deepseek-v4-flash"] under primary
        # deepseek/deepseek-v4-flash used to re-ask the dropped primary). A
        # qualified ref still matches exactly.
        duplicate = ref.include?("/") ? seen[ref]
                                      : seen.keys.any? { |known| known.split("/").last == ref }
        next if duplicate

        seen[ref] = true
        Insika::ModelSelection.new(model: node[:model], provider: node[:provider],
                                   source: :fallback, params: primary.params, fallbacks: [])
      end
    end

    def ref_of(selection) = model_ref(selection)

    # --- WS9 media ------------------------------------------------------
    #
    # Content parts on the command -> a turn: audio parts are transcribed (the
    # text enters the message marked `source: :voice` — the consumer's signal
    # the person SPOKE), image and document parts become the ask's attachments
    # (the model sees them; the provider bills them — usage flows) and the
    # first URL of each kind is deposited as `ctx.image_url` / `ctx.document_url`
    # for data/HTTP tools. The engine transports media, never meaning: no
    # speech/vision logic beyond the call itself.
    def run_media_stage(task, state)
      # a consumer that pre-transcribed voice text labels it `source: voice`;
      # the marker rides the turn even when there are no audio PARTS left.
      state.message_source = :voice if rebuild_command(task).payload["source"].to_s == "voice"

      parts = Insika::Media.parts(rebuild_command(task).payload["parts"])
      return if parts.empty?

      voice = Insika::Media.audio_parts(parts)
      if voice.any?
        text = voice.map { |p| media_transcribe(p.url, state) }.reject(&:empty?).join(" ")
        state.message = [state.message.to_s, text].reject(&:empty?).join("\n")
        state.message_source = :voice
      end

      images = Insika::Media.image_parts(parts)
      if images.any?
        state.image_attachments = images.map { |p| media_attachment(p.url) }
        state.media_attachments = state.image_attachments
        # First image URL for data tools (`{{ctx.image_url}}`) — photo analysis
        # outside the prompt. The model still sees the attachment; the tool
        # gets the original URL (its own egress applies when it fetches).
        state.turn_context = (state.turn_context || {}).merge(image_url: images.first.url)
      end

      # Documents (a prescription, a recipe, an invoice) ride the SAME
      # attachments array as images — RubyLLM's `ask(with:)` takes both, and
      # the attachment content-sniffs PDF magic bytes when the URL has no
      # extension — capped separately (MAX_DOCUMENT_BYTES) since a document
      # is not a photo.
      documents = Insika::Media.document_parts(parts)
      if documents.any?
        doc_attachments = documents.map { |p| media_attachment(p.url, max_bytes: Insika::Media::MAX_DOCUMENT_BYTES) }
        state.media_attachments = Array(state.media_attachments) + doc_attachments
        state.turn_context = (state.turn_context || {}).merge(document_url: documents.first.url)
      end

      # A media-only turn (a voice note with no caption) is legitimate — the
      # surfaces admit it — but it must leave this stage with something to ask
      # about. Empty text AND no attachment means the parts carried nothing the
      # engine could use (a transcription that came back blank): fail loudly at
      # :media rather than ask the provider about nothing.
      return unless state.message.to_s.strip.empty? && state.media_attachments.nil?

      raise Insika::MediaError, "the message parts produced no text and no attachment"
    end

    # The STT seam: the injected transcriber (specs), else the default
    # (fetch + RubyLLM::Transcription — lazy require). A failed transcription
    # fails the turn loudly (MediaError -> :media): a voice message that was
    # not heard must not become a hallucinated one. The default is rebuilt
    # PER CALL (never memoized) because its vocabulary `prompt:` is resolved
    # from THIS turn's profile — a memoized seam would freeze the first
    # agent's prompt (or its absence) for every agent sharing the executor.
    def media_transcribe(url, state)
      transcriber = @media || Insika::Media.default_transcriber(
        stt_model: Insika::EnvSchema.read("INSIKA_STT_MODEL"),
        stt_language: Insika::EnvSchema.read("INSIKA_STT_LANGUAGE"),
        stt_prompt: resolved_stt_prompt(state.profile)
      )
      transcriber.call(url)
    end

    # Resolution order: the agent profile's own vocabulary hint
    # (it knows its catalog) beats the deployment-wide default, which beats
    # nothing (no prompt: kwarg at all).
    def resolved_stt_prompt(profile)
      Insika::Coercion.presence(profile&.stt_prompt) || Insika::EnvSchema.read("INSIKA_STT_PROMPT")
    end

    # An image/document part -> the ask's attachment (Insika::Media.url_attachment
    # — egress-guarded, size-capped fetch; the caller picks the ceiling).
    def media_attachment(url, max_bytes: Insika::Media::MAX_IMAGE_BYTES)
      Insika::Media.url_attachment(url, max_bytes: max_bytes)
    end

    # --- WS4 intent routing --------------------------------------------
    #
    # The turn's message is classified into one of the profile's routes with a
    # CHEAP model (data-gated: no `routes` on the profile = byte-identical turn).
    # -> true when the route took over the turn (delegated / stuck — no ask
    # happens); false when the turn proceeds normally. Classification happens on
    # a fresh chat carrying ONLY the auto-generated route prompt (no identity,
    # no tools — it is a router, not the agent); its tokens ride the turn's
    # usage, so the trace, the token ceiling and the budget all see the cost.
    def attempt_route(task, profile, state)
      meta = Insika::Routing.normalize(profile.routes)
      return false unless meta
      return false unless route_model(meta, profile)

      selection = route_selection(meta, profile)
      classification = classify_route(selection, meta, state.message, task, state)
      return false if classification.nil? # the classifier call failed — routing is additive

      route = classification[:route]
      state.route = route
      # MERGED, not assigned: a WS9 transcription may already have banked its
      # tokens in state.usage (the classifier call must not erase them).
      state.usage = merge_usage(with_model_source(usage_of(classification[:response]), selection),
                                state.usage)
      emit(:route_classified,
           { task_id: task.id, agent: profile.id.to_s, route: route.to_s,
             model: selection.model, usage: state.usage },
           task: task)

      entry = meta[:entries].find { |e| e.name == route.to_s }
      apply_route_action(task, profile, state, entry)
    end

    # The classifier call, its answer parsed back into a route.
    # -> { route:, response: } | nil (nil = the call failed — the turn proceeds
    # unrouted rather than paying a wrong label or dying for an additive step).
    def classify_route(selection, meta, message, task, st)
      response = route_ask(selection, Insika::Routing.classifier_prompt(meta), message, task, st)
      { route: Insika::Routing.parse(route_response_text(response), meta), response: response }
    rescue StandardError
      nil
    end

    # The cheap classifier's model: routes["model"] wins, the agent's own model
    # otherwise. No model anywhere = no routing.
    def route_model(meta, profile)
      ref = meta[:model].to_s
      ref = profile.model.to_s if ref.empty?
      !ref.empty?
    end

    def route_selection(meta, profile)
      ref = meta[:model].to_s
      ref = profile.model.to_s if ref.empty?
      parsed = parse_model_ref(ref) || {}
      provider = parsed[:provider].nil? ? profile.provider : parsed[:provider].to_sym
      Insika::ModelSelection.new(model: parsed[:model], provider: provider, source: :routing)
    end

    # A fresh chat for the routing model with ONLY the generated prompt. RubyLLM
    # required lazily, exactly like create_chat (the load-guard holds).
    # the classifier is model-visible, so it is logged — the ONE
    # engine-internal ask the conformance spec adds a record for (part
    # "routing", same turn number as the answer ask).
    def route_ask(selection, prompt, message, task, st)
      require "ruby_llm"
      chat = (@llm || RubyLLM).chat(model: selection.model, provider: selection.provider,
                                    assume_model_exists: selection.assume_model_exists?)
      chat.with_instructions(prompt) if chat.respond_to?(:with_instructions)
      response = chat.ask(message.to_s)
      record_model_visible(task, st, chat, part: "routing")
      response
    end

    def route_response_text(response)
      response.respond_to?(:content) ? response.content.to_s : response.to_s
    end

    # The route's config decides the turn's fate: nothing (a label), a DELEGATE
    # (an existing agent answers; its reply IS the turn's), or STUCK (WS5 — the
    # turn ends with the stuck outcome; the consumer interprets it).
    def apply_route_action(task, profile, state, entry)
      return false unless entry

      if entry.delegate && !entry.delegate.empty?
        delegate_route(profile, state, entry.delegate)
        true
      elsif entry.stuck
        message = entry.message.empty? ? entry.description : entry.message
        state.stuck_outcome = { reason: "route:#{state.route}", message: message }
        state.response_content = message
        true
      else
        false
      end
    end

    # WS4 delegate action: the route names an existing agent — the turn is
    # handed to it (the sync subagent machinery) and the child's answer IS the
    # parent's answer. A missing agent or a failed child fails the turn: never
    # fabricate the customer's reply.
    #
    # The depth comes from the PARENT's turn context, +1, and is capped here —
    # this path does not go through `plan_subagent` (a route has no subagents
    # allowlist to check against), so a hardcoded depth of 1 made an A -> B -> A
    # route pair a loop with no floor: every hop reclassifies (a paid ask) and
    # spawns another child, forever.
    def delegate_route(profile, state, agent_id)
      child = @profiles[agent_id.to_s]
      raise Insika::RoutingError, "route delegate agent '#{agent_id}' not configured" if child.nil?

      depth = (state.turn_context&.dig(:delegation_depth) || 0) + 1
      cap = SubagentGraph.depth_cap
      if depth > cap
        raise Insika::RoutingError,
              "routed delegate '#{agent_id}' at depth #{depth} exceeds cap #{cap}"
      end

      result = spawn_and_await_child(child, state.message, depth, state)
      if result[:error]
        raise Insika::RoutingError, "routed delegate '#{agent_id}' failed: #{result[:error]}"
      end

      state.response_content = result[:text].to_s
    end

    # The WS4 classifier's tokens, summed over the ask's (a call that reported no
    # usage contributes nothing). The turn's own model/source win for attribution
    # — the routing model's identity lives on the :route_classified event.
    def merge_usage(main, extra)
      return main || extra if main.nil? || extra.nil?

      Insika::Routing::TOKEN_FIELDS.each_with_object(main.dup) do |k, acc|
        next if extra[k].nil?
        next unless main.key?(k) || extra[k].to_i.positive?

        acc[k] = main[k].to_i + extra[k].to_i
      end
    end

    # "provider/model" for any selection duck (ModelSelection | { model:, provider: }).
    def model_ref(selection)
      model = selection.respond_to?(:model) ? selection.model.to_s : selection[:model].to_s
      provider = selection.respond_to?(:provider) ? selection.provider : selection[:provider]
      provider ? "#{provider}/#{model}" : model
    end

    # "provider/model" -> { model:, provider: }; "model" -> { model:, provider: nil }.
    def parse_model_ref(entry)
      s = entry.to_s.strip
      return nil if s.empty?

      if s.include?("/")
        provider, model = s.split("/", 2)
        { model: model, provider: presence_or_nil(provider)&.to_sym }
      else
        { model: s, provider: nil }
      end
    end

    def presence_or_nil(value)
      v = value.to_s.strip
      v.empty? ? nil : v
    end

    # A fresh chat for a retry/fallback attempt: REASSEMBLED from the same turn
    # state (the seed history is identical), baseline reset -> the transcript
    # recorded from than point is the attempt that spoke.
    def build_attempt_chat(state, selection)
      chat = build_chat(selection, state.model_selection)
      @chat_builder.assemble(chat, state, emit: ->(type, data) { emit(type, data, task: state.task) })
      state.chat_baseline = Array(chat.messages).size if chat.respond_to?(:messages)
      chat
    end

    def new_turn_output(task, state, filter)
      TurnOutput.new(filter: filter, emit: ->(type, data) { emit(type, data, task: task) },
                     public_intermediate: state.profile.stream_public?(:intermediate))
    end

    # The message-boundary + steer wiring ON the current chat. Registered
    # AFTER TurnOutput so the publishing decision for a message is made before
    # anything is appended after it — the gem's callbacks are additive and run
    # in registration order.
    def wire_chat_output(task, state, output)
      chat = state.chat
      chat.after_message { |message| output.message_ended(message) } if chat.respond_to?(:after_message)
      install_steer_injector(task, state)
    end

    # The ask itself, chunk-by-chunk (WS3 attempts and the plain path share it).
    # With INSIKA_TURN_TIMING the FIRST content chunk also emits the live
    # :ttft event — the streaming envelope's TTFB signal (WS6), additive. The
    # emit is gated to that first chunk: a probe proved the old code re-emitted
    # :ttft on EVERY content chunk (3 chunks = 3 insika.ttft frames); the spec
    # passed because FakeChat emits a single chunk.
    def ask_on(task, state, chat, output, timing)
      public_thinking = state.profile.stream_public?(:thinking)
      ttft_sent = false
      each_chunk = lambda do |chunk|
        emit_thinking(chunk, task, public: public_thinking)
        next unless chunk.content

        timing&.mark(:first_token) # first-write-wins -> the PROVIDER's TTFB
        unless ttft_sent
          emit_ttft(task, timing) if timing
          ttft_sent = true
        end
        output.push(chunk.content)
      end
      # WS9: image parts ride the ask as attachments (only then — a chat whose
      # ask has no `with:` keeps working, and the plain path is byte-identical).
      # An image with no caption asks with NIL, not "": an empty text part is a
      # thing some providers refuse, and nil is how RubyLLM says "attachments
      # only".
      if state.media_attachments
        text = state.message.to_s.empty? ? nil : state.message
        chat.ask(text, with: state.media_attachments, &each_chunk)
      else
        chat.ask(state.message, &each_chunk)
      end
    end

    # The provider's TTFB as a live event (data: ttft_ms) — only under
    # INSIKA_TURN_TIMING, so absent by default (parity). Rides the SINGLE
    # emitter: a hand-built meta here lacked `tenant`, and a tenant-scoped
    # /v1/events subscription is fail-closed on it — the tenant's own TTFB was
    # invisible to the tenant.
    def emit_ttft(task, timing)
      ttft = timing.to_h[:ttft_ms]
      return if ttft.nil?

      emit(:ttft, { ttft_ms: ttft }, task: task)
    rescue StandardError
      nil
    end

    # wires the tool-batch boundary that lets a message which arrived
    # mid-run enter the conversation. No-op unless the agent asked for `steer`: an
    # unregistered callback is the difference between a feature that is off and one that
    # is on and finds nothing.
    def install_steer_injector(task, state)
      policy = state.queue_policy
      return unless policy&.steer? && task.session_id && state.actor
      # A chat that does not answer the three callbacks cannot host the boundary (the smoke
      # shim, a minimal double). Steering is then simply off, never half-wired.
      return unless %i[after_message after_tool_result add_message].all? { |m| state.chat.respond_to?(m) }

      injector = SteerInjector.new(
        chat: state.chat, actor: state.actor, policy: policy,
        # `task_id` in the payload as well as the meta, so `:turn_steered` reads like
        # `:turn_coalesced` for a subscriber that only looks at data.
        emit: ->(type, data) { emit(type, data.merge(task_id: task.id), task: task) }
      )
      state.chat.after_message { |message| injector.message_ended(message) }
      state.chat.after_tool_result { |result| injector.tool_result(result) }
      injector
    end

    # WHAT THE CUSTOMER GETS, in precedence order. Published once, at the end of the
    # stage, because the `:agent` after-hook runs after the message boundary and is
    # allowed to have the last word.
    def turn_answer(response, asked, output, filter)
      # HALTED BY A TOOL RESULT (`halt_when`): RubyLLM returns the Tool::Halt itself
      # instead of a Message, and its `content` is the tool PAYLOAD — publishing it
      # would ship the envelope to the customer as the answer. The turn is worth
      # exactly the lead-in of the message that called the tool (the model's "vou te
      # inscrever agora"), and nothing after: the backend already said the rest.
      # Nothing streamed -> the tool's `halt_when.say`, when it declared one; else an
      # empty turn, which is what the consumer suppresses. The lead-in still WINS —
      # a model that introduced the escalation already said the right thing, and
      # publishing both would deliver the message twice, which is the whole reason
      # `halt_when` exists.
      return halt_answer(response, output) if halted?(response)
      # An :agent after-hook REPLACED the response. An explicit override outranks
      # what the model streamed (the OutputValidator still sees the result).
      return content_of(response) unless response.equal?(asked)
      # The normal path: the message that ended the turn, as it was streamed and
      # (when guardrails are on) redacted.
      return output.candidate if output.candidate

      # No message boundary was reported — a transport that does not implement
      # `after_message`. Fall back to the whole turn's redacted text, else the raw
      # response: the pre-boundary behaviour, kept as the floor.
      filter ? filter.output : content_of(response)
    end

    # The lead-in when there is one; otherwise whatever the halting tool declared it
    # wants the customer to get (`halt_when.say`). Never both.
    def halt_answer(response, output)
      lead = output.halt_text.to_s
      return lead unless lead.strip.empty?

      Insika::ToolDefinition.halt_say_of(content_of(response)).to_s
    end

    def halted?(response) = response.is_a?(RubyLLM::Tool::Halt)

    def content_of(response) = response.respond_to?(:content) ? response.content : response.to_s

    # The provider's REASONING (DeepSeek `reasoning_content`, Anthropic thinking
    # blocks): RubyLLM parks it in `chunk.thinking`, NEVER in `chunk.content`, so it
    # was being dropped on the floor — invisible in the Studio and in the trace. It
    # rides the Event Stream as its OWN type (:thinking), and `/v1/responses` does not
    # translate it BY DEFAULT: the deliberation is observability, not the answer.
    #
    # An agent may opt in (`edge_stream thinking: true`) — a product with a "thinking"
    # panel wants it — and then the event is TAGGED `public: true` and the edge gives
    # it the reasoning frame, never the answer's. The tag rides the event because
    # `Responses.frame_for` is a pure static mapper with no agent in scope.
    #
    # Three deliberate omissions:
    # · the guardrail filter is NOT applied — it accumulates the PERSISTED content
    # and pushing reasoning through it would corrupt the turn's answer;
    # · `timing.mark(:first_token)` stays on the content chunks — ttft is the
    #   PROVIDER's first token ('s baselines measure that, not the first
    #   thought, and not when TurnOutput publishes the answer);
    # · nothing is persisted — the reasoning is not part of the conversation.
    #
    # Duck-typed like `usage_of`: a provider/fake with no thinking -> nothing to emit.
    def emit_thinking(chunk, task, public: false)
      return unless chunk.respond_to?(:thinking)

      thought = chunk.thinking
      text = thought.respond_to?(:text) ? thought.text : thought # RubyLLM::Thinking | String | nil
      return if text.to_s.empty?

      data = { delta: text.to_s }
      data[:public] = true if public
      emit(:thinking, data, task: task)
    end

    # Annotates the usage with the RESOLVED model-selection source:
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
      # R3: prompt-cache WRITE tokens (Anthropic cache_creation_input_tokens),
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
      state.session = session # create_chat reads it for the per-chat model pin
      hist = command_history(task)
      # `vars` reconciles the seam (the Request/Session provider already
      # called request.vars): session metadata + the explicit `history` in the
      # convention the Session provider consumes (vars["history"]).
      vars = (session&.vars || {}).dup
      vars["history"] = hist if hist
      # The single type is Insika::ContextRequest (Data); the explicit `history`
      # travels in vars["history"] (Session provider convention), not in a field
      # of its own. `memory_scope` is the WS8 customer cell (nil = the providers
      # fall back to tenant || session, today's behavior).
      ContextRequest.new(profile: profile, message: state.message, session: session,
                         checkpoint: resume_from, tenant: command_tenant(task), vars: vars,
                         memory_scope: memory_tenant(task))
    end

    # task_started payload. Carries the EXPLICIT command tenant so
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

    # Who produced the message this turn is answering (MessageOrigin). Absent for an
    # ordinary turn — a customer typed it — and declared by the producer when not:
    # the engine delivering a delegation result, or a consumer that composed the
    # input out of context blocks. Validated where it enters (Commands::SendMessage).
    def command_origin(task)
      Coercion.presence(rebuild_command(task).payload["origin"])
    end

    # Engine memory scope: the Command's EXPLICIT tenant wins (multi-merchant
    # override); otherwise the SESSION (=chat) — engine-owner memory is per-chat.
    # Symmetric to the READ path (Memory provider). One-shot with no tenant -> nil
    # (_default). It is NOT the <request_context> tenant (that follows
    # command_tenant, prompt parity) — only the memory read/write scope.
    #
    # WS8: a request carrying a CUSTOMER moves the scope to the customer cell —
    # "[tenant:]customer" when a tenant is present, the bare customer otherwise
    # (never _default — a tagged customer must never land in the shared cell).
    # Per-customer memory is the 360 view; per-tenant was the leak.
    #
    # the SESSION fallback is MARKED ("chat:<session id>" -> cell
    # "memory:chat:<session id>"), never a bare cell — a bare "memory:<id>" is
    # indistinguishable from a single-tenant customer ref, and the Studio drill
    # must not list conversations as customers with a Forget button.
    def memory_tenant(task)
      customer = command_customer(task)
      return command_tenant(task) || session_scope(task.session_id) if customer.nil?

      [command_tenant(task), customer].compact.join(":")
    end

    # The marked per-session scope : "chat:<session id>" -> cell
    # "memory:chat:<session id>". nil for a one-shot turn (no session) — the
    # MemoryStore applies _default.
    def session_scope(session_id)
      return nil if session_id.nil?

      "#{MemoryStore::SESSION_TAG}:#{session_id}"
    end

    # WS8 +  : stamp the customer (WS8 — the `forget_customer`
    # purge finds the customer's sessions through this var) AND the agent (the
    # distillation engine resolves each session's pack through it) on the
    # session ONCE (idempotent). A session that does not exist yet (no
    # session_id on the turn) is skipped; a look-up failure never breaks the
    # turn.
    def stamp_customer_session(task, profile)
      customer = command_customer(task)
      return if customer.nil? || task.session_id.nil?

      session = @session_store&.find(task.session_id)
      return if session.nil? || !Coercion.presence(session.vars["customer"]).nil?

      @session_store.update_vars(task.session_id,
                                 "customer" => customer, "agent" => profile.id)
    rescue Insika::NotFoundError, ArgumentError
      nil
    end

    # The optional customer_key on the command payload (WS8): a String identifying
    # the person the conversation belongs to — the memory scope's customer half
    # and the handle `forget_customer` purges by. nil = untagged conversation
    # (memory stays per-tenant/per-chat, byte-identical to before).
    def command_customer(task)
      Coercion.presence(rebuild_command(task).payload["customer"])
    end

    # Turn context: the ids the data-tools resolve via
    # {{ctx.*}} to emit X-Chat-Id/X-Store-Id/X-Agent-Id to /api/internal/*. They
    # come from the TURN, never from the model args (R2). chat_id = the session
    # (the /v1/responses adapter creates the session with id = user = chat.id);
    # tenant = the Command tenant (memory) OR chat_id (drop-in default); agent_id =
    # profile; store_id = the profile metadata (stable per store, from the pack).
    # Absent fields -> nil (the data-tool emits an empty header; in the pilot the
    # profile carries store_id). Generic: nothing here mentions a consumer.
    def build_turn_context(task, profile, state)
      {
        chat_id: task.session_id,
        agent_id: profile.id,
        # the DATA-TOOL header tenant stays the merchant (or the chat), even when
        # the memory scope carries a customer — the backend identifies the store,
        # not the shopper (WS8 keeps the two scopes separate).
        tenant: command_tenant(task) || task.session_id,
        # the DECLARED tenant alone (nil in single-tenant). Distinct from
        # `tenant` for the ownership-binding tools (save_artifact): a report
        # belongs to the AGENT's tenant — the deployment's tenant in
        # single-tenant, never the chat that happened to run it.
        command_tenant: command_tenant(task),
        store_id: profile.store_id,
        # the current task id — the save_artifact binding (which run produced
        # this report), same turn-origin discipline as the rest of ctx.*.
        task_id: task.id,
        # current delegation depth (0 for a top-level turn). Set by run_subagent
        # for children.
        delegation_depth: delegation_depth(task)
      }
    end

    # Delegation depth of THIS turn: the value run_subagent stamped in
    # the child command, or 0 for a top-level turn. Integer-coerced (JSON round-trip
    # of the persisted command may deliver a String).
    def delegation_depth(task)
      rebuild_command(task).payload["delegation_depth"].to_i
    end

    # R2: environment (model/thinking) inherits as DEFAULT — the child's
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

    # Single validation path for a delegation — shared by run_subagent
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

    # SYNC: spawns the child and AWAITS it on the parent's fiber, then
    # projects the terminal content. Direct `spawn` (not spawn_in_session): the
    # child session is brand-new, so there is no SessionActor contention — the child
    # is parented at turn_parent and the parent yields cooperatively on `wait`.
    def spawn_and_await_child(child_profile, message, depth, parent_state)
      child_session_id, child_task = create_child(child_profile, message, depth, parent_state, async: false)
      spawn(child_task, profile: child_profile)
      @running[child_task.id]&.wait
      project_child_result(child_task.id, child_session_id, child_profile.id, parent_state)
    end

    # ASYNC: persists a Delegation, spawns the child NON-blocking, and
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

    # terminal hook: when a turn ends (success OR failure), if the
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
        # `origin: engine` — this "user" message is Insika writing to itself. Without
        # it a report reads a delegation result as something the customer said.
        { "agent" => deleg.parent_agent, "message" => message,
          "session_id" => deleg.parent_session_id, "delegation_id" => deleg.id,
          "origin" => Insika::MessageOrigin::ENGINE }
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
        # agent: so a specialized skill reaches the policy as the agent's own version
        # (same name, its body) instead of the shared one it overrides.
        candidate_skills: @skill_catalog.effective(profile.skills, agent: profile.id)
      )
    end

    # The Task persists the Command as a Hash; the WorkflowAllowlist needs
    # a Command with #type (Symbol) and #payload.: the SINGLE point that
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

    # Stage-3-tail tool assembly — delegated to ToolAssembly. Kept as
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

    # GRACEFUL halt: a Middleware short-circuited with a safe reply.
    # The turn COMPLETES — same stages 8-9 as a normal turn — but the "assistant
    # content" is the guardrail's safe response, produced with ZERO LLM calls. The
    # order mirrors a real turn so both the /v1/responses consumer (which reads the
    # text off :content deltas) and the Studio viewer render it: audit -> safe text
    # -> persist -> terminal.
    def complete_with_halt(task, profile, state, timing = nil)
      content = state.halt_response.to_s
      state.response_content = content

      if (block = state.guardrail_block)
        emit(:guardrail_blocked, {
               task_id: task.id, category: block[:category], source: block[:source],
               action: block[:action], detail: block[:detail]
             }, task: task)
      end
      emit(:content, { delta: content }, task: task) unless content.empty?
      # An EDGE-blocked turn (rate limit / token ceiling) completes but
      # stays OUT of the session history: a flood at the wall must not bloat the
      # session nor evict real conversation from the context budget — the
      # :guardrail_blocked event is the audit trail. Content-guardrail blocks
      # keep persisting (the refusal is part of the conversation).
      # The reply is the guardrail's, produced with zero LLM calls — so it is NOT the
      # agent talking, and a report that counts it as the agent repeating itself is
      # reading the engine's own canned text (the `safe_reply` finding exists exactly
      # because that text is otherwise indistinguishable in the transcript).
      persist_turn(task, profile, state, content, reply_origin: MessageOrigin::ENGINE,
                   session: state.guardrail_block&.[](:source) != "edge", timing: timing)
      data = { task_id: task.id, content: content, usage: state.usage }
      data[:timing] = timing.to_h if timing # a channel halt still measured
      persist_turn_timing(task, timing)
      emit(:task_completed, data, task: task)
    end

    # Best-effort write of the turn's timing onto the task record .
    # The record gains `timing` once, when the turn completes; a store failure
    # here is swallowed — the turn is already committed and the event already
    # carries the number.
    def persist_turn_timing(task, timing)
      return unless timing

      hash = timing.to_h
      return if hash.empty?

      @task_store.record_timing(task.id, hash)
    rescue Insika::Error
      nil
    end

      # Emits one :guardrail_flagged per flag the OutputValidator appended in
      # after_task (audit only — the turn already completed). Reads a plain Array off
      # the state, keeping the Executor decoupled from Safety. an
      # :enforce cut rides the SAME event with `action: "cut"` so the audit can
      # distinguish a cut from a flag.
      def emit_guardrail_flags(task, state)
        return unless state.respond_to?(:guardrail_flags)

        Array(state.guardrail_flags).each do |flag|
          data = { task_id: task.id, category: flag[:category], source: flag[:source],
                   detail: flag[:detail] }
          data[:action] = flag[:action] if flag[:action]
          emit(:guardrail_flagged, data, task: task)
        end
      end

    # Stage 8: FIXED order checkpoint -> session -> task. If it crashes
    # between writes, the worst case is a new checkpoint with the task :running ->
    # Recovery re-executes the already-saved turn (safe thanks to the side-effect
    # recording).
    #
    # CHECKPOINT vs SESSION — the two stores DIVERGE by design (R2c):
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
    def persist_turn(task, profile, state, content, session: true, reply_origin: nil, timing: nil)
      new_messages = turn_transcript(state, content, origin: command_origin(task), reply_origin: reply_origin)
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

      # if this completed turn is an ASYNC delegation child,
      # deliver its result to the parent as a NEW turn. No-op for a normal turn
      # (not a delegation child) or without a delegation_store.
      finalize_delegation(task)

      # if this turn CAME IN through a Shape B channel, its answer
      # has to travel out of band. Same terminal hook, next door to the delegation
      # one, for the same reason: it fires for a fresh turn and a recovered one.
      finalize_channel_delivery(task, content, state, timing)

      # extracts durable concepts from this turn, off the critical
      # path — the user already has the answer above. Same terminal hook,
      # next door to the other two, for the same reason: it fires for a fresh
      # turn and a recovered one.
      finalize_knowledge_extraction(task, profile, new_messages)
    end

    # Records the answer in the outbox and dispatches it. The discriminator is the
    # turn's TRANSPORT (`channel:<id>` on the persisted command), not the session:
    # a session belongs to the channel forever, but a message an operator types into
    # the Studio playground against that same session must not reach the customer.
    # Human handoff is not a product feature (``), and it would be a
    # surprising way to acquire one.
    #
    # The consequence, stated rather than discovered later: a turn the ENGINE
    # spawned on a channel session — an async delegation result delivered as a new
    # turn — is not delivered either. There is no consumer for that yet; when there
    # is, the fix is to give those turns the channel transport, not to widen this.
    #
    # Best-effort: the turn is already committed and durable, and a delivery problem
    # must never re-fail it.
    #
    # a PROGRESSIVE channel gets the answer split into balloons —
    # N outbox rows, dispatched in index order (dispatch_chain). `:at_end` is the
    # single whole-answer row, byte-identical to today.
    def finalize_channel_delivery(task, content, state, timing = nil)
      return unless @channel_delivery

      channel_id = channel_transport(task)
      return unless channel_id

      # the hoarded evidence attachments ride the channel delivery
      # (additive outbox payload key — the channel contract widens, nothing breaks).
      attachments = state.respond_to?(:evidence_attachments) ? state.evidence_attachments : nil
      deliveries = @channel_delivery.record_balloons(
        task: task, channel_id: channel_id, content: content,
        progressive: @channel_delivery.progressive?(channel_id),
        attachments: attachments
      )
      return if deliveries.empty?

      timing&.mark(:first_balloon) # C5: inbound -> first outbox row, first-write-wins
      dispatch_chain(deliveries.map(&:id))
    rescue Insika::Error
      nil
    end

    # Turns whose combined transcript slice is this trivially short skip
    # extraction entirely ("ok thanks" exchanges) — no new config surface,
    # just avoids a wasted utility-model call.
    KNOWLEDGE_MIN_CHARS = 200

    # No-op without a knowledge store, without the profile's opt-in
    # (`knowledge.extract`), without a usable model, or for a trivially short
    # turn. Otherwise dispatches the extraction off the critical path — the
    # SAME `dispatch_chain` shape: inline when non-supervised (tests, CLI,
    # boot sweep), a child of the turn supervisor when serving (survives the
    # request's own disconnect). Best-effort: any failure is swallowed here,
    # never re-fails an already-committed turn.
    def finalize_knowledge_extraction(task, profile, new_messages)
      return unless @knowledge_store

      config = Coercion.deep_stringify(profile.knowledge)
      return unless config && Coercion.truthy?(config["extract"])
      return if knowledge_transcript(new_messages).length < KNOWLEDGE_MIN_CHARS

      extractor = Knowledge::ExtractorFactory.build(config, utility_model: utility_model)
      return unless extractor

      run = lambda { run_knowledge_extraction(task, profile, config, new_messages, extractor) }
      return run.call unless @supervised

      turn_parent.async do |t|
        t.annotate("knowledge:#{task.id}")
        run.call
      end
    end

    def run_knowledge_extraction(task, profile, config, new_messages, extractor)
      prompt = knowledge_prompt(config, new_messages)
      result = extractor.extract(prompt: prompt)
      result[:concepts].each do |concept|
        rendered = Knowledge.stamp_and_render(concept, session_id: task.session_id)
        @knowledge_store.write(profile.id, concept["name"], rendered)
        emit(:knowledge_learned, { name: concept["name"], type: concept["type"], agent: profile.id }, task: task)
      end
    rescue StandardError
      nil # best-effort: extraction never re-fails an already-committed turn.
    end

    def knowledge_prompt(config, new_messages)
      base = Coercion.presence(config["prompt"]) || Knowledge::DEFAULT_PROMPT
      <<~PROMPT
        #{base.rstrip}

        ## The conversation

        #{knowledge_transcript(new_messages)}
      PROMPT
    end

    # Redacted (RFC's PII rule applies to what reaches the model too, not
    # just what gets persisted).
    def knowledge_transcript(new_messages)
      redacted, = Insika::Safety::Detectors.redact(
        new_messages.each_with_index.map { |m, i| "[#{i}] #{m['role'] || m[:role]}: #{m['content'] || m[:content]}" }
                    .join("\n")
      )
      redacted
    end

    def utility_model
      return nil unless @settings_store

      @settings_store.get["utility_model"]
    end

    # ONE supervisor fiber for the whole chain. Sequential deliver
    # calls, so balloon N+1 cannot overtake balloon N on the wire. Still off the
    # session's FIFO — the customer's next message does not wait on this turn's
    # outbound. Non-serving (boot sweep, specs) delivers inline, where waiting is
    # what the caller wants.
    def dispatch_chain(ids)
      run = lambda { ids.each { |id| @channel_delivery.deliver(id) } }
      return run.call unless @supervised

      turn_parent.async do |t|
        t.annotate("outbox:#{ids.first}")
        run.call
      end
    end

    # `channel:<id>` -> "<id>"; anything else -> nil. The transport is persisted with
    # the command, so a turn resumed after a crash still knows where it came from.
    def channel_transport(task)
      transport = rebuild_command(task).meta["transport"].to_s
      transport.start_with?("channel:") ? transport.delete_prefix("channel:") : nil
    end

    # Truncation cap for a persisted `role: tool` content (R1): the transcript
    # keeps the loop coherent; the FULL result lives in the ToolTraceStore (viewer).
    TOOL_CONTENT_CAP = 4_000

    # The turn's messages in the ADDITIVE string-keyed format (R1). Prefers the
    # real chat transcript (`chat.messages.drop(baseline)`) so tool calls/results
    # survive between turns; falls back to the {user, assistant} pair when the chat
    # did not record the turn (workflow, graceful halt, or the specs' FakeChat).
    # The final assistant text is the REDACTED `content` (output_filter),
    # never the raw text the gem stored.
    # `origin` (MessageOrigin) travels on the turn's Command and is stamped on the
    # message it describes: the INCOMING one. It is absent for an ordinary turn, and
    # present when the engine wrote the text itself (an async delegation result
    # delivered as a new turn) or when the consumer declared that it composed it.
    # The reply's origin is not a parameter — the model wrote it, unless a guardrail
    # short-circuited, which `complete_with_halt` says explicitly.
    def turn_transcript(state, content, origin: nil, reply_origin: nil)
      recorded = recorded_turn_messages(state)
      if recorded.empty?
        return [MessageOrigin.stamp({ "role" => "user", "content" => state.message.to_s }, origin),
                MessageOrigin.stamp({ "role" => "assistant", "content" => content.to_s }, reply_origin)]
      end

      recorded[0] = MessageOrigin.stamp(recorded[0], origin) if recorded[0]["role"] == "user"
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
    # grouped as one Array by the Session provider, R1). Checkpoints store a
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
      require_relative "tools/stuck_signal"
      require_relative "tools/generate_image"
      require_relative "tools/tts"
      require_relative "tools/update_briefing"
      # the schedule/cancel_followup builtins — lazy, same
      # boundary (the ChatBuilder wires them only when a profile declares
      # followup AND the stores are present).
      require_relative "tools/schedule_followup"
      # v2 resolution: Chat pin > Agent model > platform default, model_policy
      # enforced, fallback chain resolved. Kept on the state for telemetry (usage).
      selection = @model_resolver.resolve(profile: profile, session: state.session)
      state.model_selection = selection
      build_chat(selection, selection)
    end

    # The gem boundary: one chat for a model selection (the resolved primary or
    # a WS3 fallback node). The primary's generation params apply to the whole
    # chain (params_source: ModelSelection#apply_params).
    def build_chat(selection, params_source)
      model = selection.respond_to?(:model) ? selection.model : selection[:model]
      provider = selection.respond_to?(:provider) ? selection.provider : selection[:provider]
      chat = (@llm || RubyLLM).chat(
        model: model,
        provider: provider,
        assume_model_exists: !provider.nil?
      )
      params_source.apply_params(chat) # temperature/max_tokens/thinking (per-agent)
      chat
    end

    # Single emitter: an Event with meta and a monotonic seq per task. @seqs is not
    # cleared at the end of the task — the resume (new Execution) continues the
    # numbering (reliable replay). A task WITH a tenant (WS1) tags every event it
    # emits — the tenant-scoped /v1/events subscription filters on it (a control
    # event without a task has no tenant and never matches a tenant stream);
    # absent tenant -> the meta is byte-identical to before.
    def emit(type, data, task:)
      meta = { task_id: task.id, session_id: task.session_id,
               seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
      tenant = task_tenant(task)
      meta[:tenant] = tenant unless tenant.nil?
      @event_stream.emit(Insika::Event.new(type: type, data: data, meta: meta))
    end

    # The tenant stamped on the task's command (WS1), nil when the request was
    # operator-made. Cheap read on the persisted command hash — never rebuilds.
    def task_tenant(task)
      command = task.respond_to?(:command) ? task.command : nil
      return nil unless command.is_a?(Hash)

      meta = command["meta"] || command[:meta] || {}
      meta["tenant"] || meta[:tenant]
    end
  end
end
