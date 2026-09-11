# frozen_string_literal: true

require "async"
require "delegate"
require "time"

module Insika
  # Wraps each allowed tool: per-call timeout
  # + recording of a non-idempotent side-effect BEFORE the result returns to the
  # model. Delegates everything else (name/description/params) to the real tool.
  #
  # The tool loop belongs to RubyLLM; this is a decorator over the instances —
  # the Executor never drives roundtrips.
  class ToolEnvelope < SimpleDelegator
    PROVENANCE_INSTRUCTION = "This value was not returned by any tool in this conversation. " \
                             "Find it with a tool that returns it — a search or a lookup by id — " \
                             "then call this tool again with an id from that result."

    CONFIRMATION_INSTRUCTION = "This action is held until the customer confirms it. Tell the customer " \
                               "exactly what will happen, with these arguments, and ask whether to " \
                               "proceed. Do not report it as done. On their next message: if they " \
                               "confirm, call confirm_pending with this pending_id; if they decline, " \
                               "change anything, or ask for something else, call cancel_pending."

    # The tool timeout's OWN class: distinct from Async::TimeoutError so that
    # the rescue below NEVER swallows the TURN timeout (which uses the default of
    # with_timeout). Without this, a turn overflowing while the fiber is inside a
    # tool would be masked as a tool timeout and the turn would run past the
    # deadline (a durability defect).
    ToolTimeout = Class.new(StandardError)
    private_constant :ToolTimeout

    # A gate's refusal. A plain Hash subclass: it reaches the model exactly as the
    # `{status:, gate:, ...}` it always was, and the engine's own readers (the
    # :tool_result outcome, the trace) recognize a refusal by CLASS — a data tool
    # answering `{"status":"blocked","gate":"fraud_review"}` for a held order is
    # not one, whatever keys it happens to use.
    class Blocked < Hash; end

    # A call held for the customer's confirmation. Same Hash-subclass trick as
    # Blocked, and a different class on purpose: nothing was refused and nothing
    # ran — the next customer message decides, through confirm_pending.
    class Held < Hash; end

    def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:,
                   skip_side_effects: [], trace_recorder: nil, event_stream: nil)
      super(tool)
      @state = state
      @checkpoint_store = checkpoint_store
      @tool_registry = tool_registry
      @timeout = timeout
      @event_stream = event_stream
      @skip_side_effects = Array(skip_side_effects) # ids already completed in the interrupted turn
      @trace_recorder = trace_recorder # duck-type: #record(session_id:, entry:). nil = no trace.
    end

    # Entry point that RubyLLM invokes (Tool#call in the pinned version).
    # A timeout overflow returns to the MODEL as a serialized error — it does
    # not bring down the turn.
    def call(args) = run(args, hold: true)

    # The confirmed re-run of a held call (Tools::ConfirmPending): every check but
    # the hold itself — provenance, approval, fencing, evidence, the side-effect
    # record and the trace all still apply to the write.
    def call_confirmed(args) = run(args, hold: false)

    private

    def run(args, hold:)
      # A non-idempotent tool call ALREADY COMPLETED in the interrupted
      # turn -> respond with a marker, NEVER re-execute. The marker returns to
      # the model, keeping the tool-use protocol intact.
      call_id = correlation_id
      return { "skipped" => "already_executed" } if call_id && @skip_side_effects.include?(call_id)

      started = monotonic
      if (blocked = provenance_block(args))
        trace(call_id, args, blocked, started)
        emit_blocked(blocked)
        return blocked
      end

      # Customer confirmation: the call is recorded and returned to the model as
      # held; the turn goes on to ask. After the provenance gate (an id the customer
      # never saw is not put to them as real) and before approval.
      if hold && (held = confirmation_hold(args))
        trace(call_id, args, held, started)
        return held
      end

      # Approval gate: a tool marked `approval` suspends the turn in
      # :waiting until the operator resolves it. Delegates to the coordinator (the
      # Executor), which creates/queries the PendingAction and blocks via the
      # mailbox. Rejection returns to the MODEL as an error (the turn continues),
      # it does not bring down the turn. CancelledError/TimeoutError from the wait
      # propagate (they are not ToolTimeout).
      if approval_required?
        decision = @state.approval_coordinator.request_approval(
          task: @state.task, turn: @state.turn, tool: real_name, args: args, actor: @state.actor
        )
        return { error: "rejected by operator" } unless decision.to_s == "approved"
      end

      started = monotonic
      result = with_gate { Async::Task.current.with_timeout(@timeout, ToolTimeout) { __getobj__.call(args) } }
      # the ONE seam every tool result passes on its way to the model.
      # For a declared-evidence tool: reshape to the lean envelope, record the ids
      # on the ledger, hoard the attachments. No evidence = the result passes
      # through untouched (one nil-check — parity).
      result = process_evidence(result)
      result = fence(result)
      record_side_effect!(call_id) if side_effect?
      trace(call_id, args, result, started)
      result
    rescue ToolTimeout
      err = { error: "TimeoutError: tool exceeded #{@timeout}s" }
      trace(call_id, args, err, started)
      err
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # with parallel tool calls on, the turn's shared semaphore
    # (TurnState#tool_gate, sized by `limits[:tool_concurrency]`) caps how many run
    # at once. Wraps the REAL call ONLY — the approval wait and the skip check are
    # outside it, so a call blocked on a human never holds a slot, and the per-call
    # `tool_timeout` clock starts after the slot is granted rather than while
    # queueing for one. The trace's `ms` DOES include the queue wait: that is the
    # wall-clock the model waited. No gate (the default, serial) = straight through.
    def with_gate(&)
      gate = @state.respond_to?(:tool_gate) ? @state.tool_gate : nil
      return yield unless gate

      serial = @state.respond_to?(:side_effect_gate) ? @state.side_effect_gate : nil
      return gate.acquire(&) unless side_effect? && serial

      # Backends may read-modify-write. Serialize writes before taking a slot,
      # so queued writes cannot keep independent reads from running.
      serial.acquire { gate.acquire(&) }
    end

    def provenance_block(args)
      tool = __getobj__
      requirement = tool.respond_to?(:requires_evidence) ? tool.requires_evidence : nil
      return unless requirement

      ledger = @state.respond_to?(:evidence_ledger) ? @state.evidence_ledger : nil
      known = ledger ? ledger.ids : []
      optional = optional_params(tool)
      requirement.fetch("params").each do |param|
        value = args.key?(param) ? args[param] : args[param.to_sym]
        # A parameter the schema marks optional and the model left out carries no
        # id to ground — nothing to check (a REQUIRED one left out is still a
        # block: the write would run without the id the gate exists for).
        next if value.nil? && ledger && optional.include?(param)

        values = value.is_a?(Array) ? value : [value]
        values = [nil] if values.empty? && !ledger
        values.each do |id|
          next if ledger && known.include?(id.to_s)

          return Blocked[{ "status" => "blocked", "gate" => "provenance", "param" => param,
                           "value" => id.to_s, "instruction" => PROVENANCE_INSTRUCTION }]
        end
      end
      nil
    end

    # The wrapped tool's top-level parameters NOT in the schema's `required`
    # (DataDefinedTool exposes its definition's schema; a code tool exposes none
    # -> every declared parameter is treated as required).
    def optional_params(tool)
      return [] unless tool.respond_to?(:params_schema) && (schema = tool.params_schema).is_a?(Hash)

      (schema["properties"] || {}).keys.map(&:to_s) - Array(schema["required"]).map(&:to_s)
    end

    def confirmation_hold(args)
      return unless customer_confirm?

      store = @state.respond_to?(:pending_action_store) ? @state.pending_action_store : nil
      task = @state.task
      if store.nil? || task.nil? || task.session_id.nil?
        # Fail loud, never run: a write that needs the customer's word and has
        # nowhere to wait for it is a misconfiguration, not a pass.
        missing = store.nil? ? "no PendingActionStore" : "no session"
        raise Insika::Error, "tool '#{real_name}' needs the customer's confirmation but the turn has #{missing} to hold it in"
      end

      id = PendingActionStore.confirmation_id(task.session_id, real_name)
      store.create(id: id, task_id: task.id, session_id: task.session_id, turn: @state.turn,
                   tool: real_name, args: args || {}, kind: PendingActionStore::CUSTOMER)
      @event_stream&.emit(Insika::Event.new(
        type: :confirmation_requested,
        data: { pending_id: id, tool: real_name, args: args },
        meta: { task_id: task.id, session_id: task.session_id }
      ))
      Held[{ "status" => "pending_confirmation", "gate" => "confirmation", "pending_id" => id,
             "tool" => real_name, "args" => args, "instruction" => CONFIRMATION_INSTRUCTION }]
    end

    def customer_confirm?
      profile = @state.respond_to?(:profile) ? @state.profile : nil
      list = profile.respond_to?(:customer_confirm) ? profile.customer_confirm : nil
      Array(list).include?(real_name)
    end

    def emit_blocked(result)
      task = @state.task # nil on a one-shot turn, like `trace` already assumes
      @event_stream&.emit(Insika::Event.new(
        type: :tool_blocked,
        data: { name: real_name, gate: result["gate"], param: result["param"] },
        meta: task ? { task_id: task.id, session_id: task.session_id } : {}
      ))
    end

    # Records the call for debugging in the Studio (name + model args + result +
    # ms), keyed by the SESSION. Masking/truncation is the ToolTraceStore's job;
    # here we only collect. NEVER breaks the turn (trace is observability).
    def trace(call_id, args, result, started)
      return unless @trace_recorder && @state.task&.session_id

      @trace_recorder.record(
        session_id: @state.task.session_id,
        entry: { "turn" => @state.turn, "tool" => real_name, "call_id" => call_id.to_s,
                 "args" => args, "result" => result,
                 "gate" => result.is_a?(Blocked) || result.is_a?(Held) ? result["gate"] : nil,
                 "ms" => started ? ((monotonic - started) * 1000).round : nil,
                 "at" => Time.now.utc.iso8601 }
      )
    rescue StandardError
      nil
    end

    # The real impl_name when the delegate is a Capability::ResolvedTool:
    # side_effect?/approval/correlation operate on the REAL name registered in
    # the tool_registry (the capability alias does not exist there). A direct
    # tool = #name.
    def real_name
      __getobj__.respond_to?(:impl_name) ? __getobj__.impl_name.to_s : __getobj__.name.to_s
    end

    # Does the current tool require approval? (names come from the Resolution
    # via state).
    def approval_required?
      @state.respond_to?(:requires_approval) &&
        Array(@state.requires_approval).include?(real_name)
    end

    # The call's correlation: the provider id (RubyLLM chat, via
    # before_tool_call) when it exists; otherwise the tool NAME — the workflow
    # case, which calls the instances directly and has no provider-generated id.
    # LIMITATION: name-based correlation is per-TOOL, not per-call. If a
    # workflow calls the SAME side-effect tool more than once in a turn,
    # the resume skips ALL calls of that name (over-skip) — per-step
    # checkpointing is future work. One call per tool is safe.
    def correlation_id
      (@state.current_tool_call&.id || real_name).to_s
    end

    def side_effect?
      @tool_registry.respond_to?(:side_effect?) &&
        @tool_registry.side_effect?(real_name)
    end

    # Written BEFORE the tool result returns to the model.
    def record_side_effect!(call_id)
      return if call_id.to_s.empty?

      @checkpoint_store.record_side_effect(@state.task.id, turn: @state.turn,
                                                           tool_call_id: call_id)
    end

    # ----   fencing ----------------------------------------------

    # After the evidence reshape (the lean envelope is already the shape the
    # model reads): every String leaf sanitized, keys and non-strings untouched,
    # each leaf capped at the platform's `fencing.max_chars`. Off = bytes
    # identical to today. An error hash is engine-authored — never touched.
    def fence(result)
      return result unless Insika::Fence.enabled?(@state.profile)
      return result if result.is_a?(Hash) && (result[:error] || result["error"])

      max = (@state.respond_to?(:fence_max_chars) && @state.fence_max_chars) || Insika::Fence::DEFAULT_MAX_CHARS
      return Insika::Fence.sanitize_value(result, max_chars: max) unless lean_evidence?(result)

      # A lean evidence result: the LINES are third-party text, the IDS are keys.
      # The ledger recorded the ids byte-exact and a presentation or a write joins
      # on them, so NFKC must not touch them (a fullwidth digit in a SKU would
      # stop matching the moment the model repeated it).
      items = result["items"].map { |i| i.merge("line" => Insika::Fence.sanitize_text(i["line"].to_s, max_chars: max)) }
      result.merge("items" => items)
    end

    def lean_evidence?(result)
      evidence_spec && result.is_a?(Hash) && result["items"].is_a?(Array)
    end

    # ----   evidence ---------------------------------------------

    # The evidence spec for the wrapped tool (D4). Resolution order:
    #   1. the wrapped tool responds to `evidence` -> its spec (the data-tool
    #      path — DataDefinedTool exposes its definition's evidence);
    #   2. otherwise the tool_registry entry's metadata carries an `evidence`
    #      spec (the code-tool path — a registry tool opts in at registration).
    # No spec = pass the result through untouched (parity, byte-identical).
    def evidence_spec
      tool = __getobj__
      if tool.respond_to?(:evidence)
        raw = tool.evidence
        return raw && Insika::Evidence::Spec.parse(raw)
      end

      entry = @tool_registry.respond_to?(:entries) ? registry_entry(real_name) : nil
      metadata = entry&.respond_to?(:metadata) ? entry.metadata : nil
      raw = metadata && (metadata[:evidence] || metadata["evidence"])
      raw && Insika::Evidence::Spec.parse(raw)
    end

    def registry_entry(name)
      @tool_registry.entries.find { |e| e.name == name.to_s }
    end

    # -> result (possibly reshaped). NEVER raises out: a broken evidence result
    # becomes the envelope error the model can act on, exactly like a malformed
    # CALL is today. A tool ERROR result is never reshaped (an error must reach
    # the model verbatim — the DataDefinedTool rule).
    def process_evidence(result)
      spec = evidence_spec
      return result unless spec
      return result if result.is_a?(Hash) && (result[:error] || result["error"])

      raw = Insika::Evidence::Processor.raw(spec, result)
      bad = Insika::SchemaGuard.violation_output(spec, raw)
      return { error: bad } if bad

      lean, attachments = Insika::Evidence::Processor.build(spec, raw)
      record_evidence!(spec, lean)
      hoard_attachments!(attachments)
      lean
    rescue StandardError => e
      { error: "evidence processing failed: #{e.message}" }
    end

    # Ledger write + attachment hoarding, both via the state (duck-typed — the
    # envelope's existing specs construct state stubs without these readers).
    def record_evidence!(_spec, lean)
      ledger = @state.respond_to?(:evidence_ledger) ? @state.evidence_ledger : nil
      return unless ledger

      ids = Array(lean["items"]).map { |i| i["id"] }
      ledger.record(ids) unless ids.empty?
    end

    def hoard_attachments!(attachments)
      return if attachments.empty?
      return unless @state.respond_to?(:evidence_attachments)

      @state.evidence_attachments ||= []
      @state.evidence_attachments.concat(attachments)
      ledger = @state.respond_to?(:evidence_ledger) ? @state.evidence_ledger : nil
      ledger.record_cards(attachments) if ledger.respond_to?(:record_cards)
    end
  end
end
