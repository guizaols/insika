# frozen_string_literal: true

require "async"
require "delegate"
require "time"

module Harness
  # Wraps each allowed tool: per-call timeout
  # + recording of a non-idempotent side-effect BEFORE the result returns to the
  # model. Delegates everything else (name/description/params) to the real tool.
  #
  # The tool loop belongs to RubyLLM; this is a decorator over the instances —
  # the Executor never drives roundtrips.
  class ToolEnvelope < SimpleDelegator
    # The tool timeout's OWN class: distinct from Async::TimeoutError so that
    # the rescue below NEVER swallows the TURN timeout (which uses the default of
    # with_timeout). Without this, a turn overflowing while the fiber is inside a
    # tool would be masked as a tool timeout and the turn would run past the
    # deadline (a durability defect).
    ToolTimeout = Class.new(StandardError)
    private_constant :ToolTimeout

    def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:,
                   skip_side_effects: [], trace_recorder: nil)
      super(tool)
      @state = state
      @checkpoint_store = checkpoint_store
      @tool_registry = tool_registry
      @timeout = timeout
      @skip_side_effects = Array(skip_side_effects) # ids already completed in the interrupted turn
      @trace_recorder = trace_recorder # duck-type: #record(session_id:, entry:). nil = no trace.
    end

    # Entry point that RubyLLM invokes (Tool#call in the pinned version).
    # A timeout overflow returns to the MODEL as a serialized error — it does
    # not bring down the turn.
    def call(args)
      # A non-idempotent tool call ALREADY COMPLETED in the interrupted
      # turn -> respond with a marker, NEVER re-execute. The marker returns to
      # the model, keeping the tool-use protocol intact.
      call_id = correlation_id
      return { "skipped" => "already_executed" } if call_id && @skip_side_effects.include?(call_id)

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
      result = Async::Task.current.with_timeout(@timeout, ToolTimeout) { __getobj__.call(args) }
      record_side_effect!(call_id) if side_effect?
      trace(call_id, args, result, started)
      result
    rescue ToolTimeout
      err = { error: "TimeoutError: tool exceeded #{@timeout}s" }
      trace(call_id, args, err, started)
      err
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Records the call for debugging in the Studio (name + model args + result +
    # ms), keyed by the SESSION. Masking/truncation is the ToolTraceStore's job;
    # here we only collect. NEVER breaks the turn (trace is observability).
    def trace(call_id, args, result, started)
      return unless @trace_recorder && @state.task&.session_id

      @trace_recorder.record(
        session_id: @state.task.session_id,
        entry: { "turn" => @state.turn, "tool" => real_name, "call_id" => call_id.to_s,
                 "args" => args, "result" => result,
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
  end
end
