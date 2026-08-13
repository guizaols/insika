# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # The agent's deterministic "I cannot proceed" signal (WS5). A
    # system builtin like remember: the model calls it when it determines it cannot
    # continue (out of scope, missing data, a case a human must take over). It ends
    # the turn with `outcome: :stuck` recorded in the contract (the executor reads
    # `state.stuck_outcome` at stage 8/9 and tags the terminal event) and a final
    # message: the model's lead-in when it wrote one, else this tool's `message`.
    #
    # The ENGINE does not decide what "stuck" means — the consumer does. This tool
    # is the deterministic signal the Agent.Shop subscribes to (`:turn_stuck` /
    # `outcome: "stuck"`) to run its escalation (CRM/operator, which answers with
    # `MessageOrigin::OPERATOR`). Nothing about handoff, pause or resume lives here.
    class StuckSignal < RubyLLM::Tool
      description "Signal that you cannot proceed and end the turn. Use when the " \
                  "request is out of your scope, you lack the data to help, or a human " \
                  "must take over. Write your final sentence to the customer first."
      param :reason, desc: "Why you cannot proceed (goes to the operator, not the customer)"
      param :message, desc: "Optional final message if you wrote none", required: false

      def name = "signal_stuck"

      def initialize(state:, **)
        @state = state
        super()
      end

      def execute(reason:, message: nil)
        @state.stuck_outcome = { reason: reason.to_s, message: message.to_s }
        # A Halt ends the tool loop here, so the turn cannot continue after declaring
        # stuck. The payload's `say` is the fallback final message when the model
        # wrote no lead-in (the executor's halt_answer already prefers the lead-in).
        RubyLLM::Tool::Halt.new(Insika::ToolDefinition.wrap_halt(
                                  { "reason" => reason.to_s },
                                  message.to_s
                                ))
      end
    end
  end
end
