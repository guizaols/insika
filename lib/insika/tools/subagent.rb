# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # In-process delegation to a CHILD agent (RFC-0010, item 21) — the Flue
    # `session.task()` primitive. A system tool (like remember/load_skill): wired
    # by the ChatBuilder ONLY when `profile.subagents` is present, so `require
    # "ruby_llm"` stays in this file (loaded lazily in create_chat). NOT enveloped
    # (system tool) — in the synchronous mode the child lives in the parent's
    # envelope and re-runs on the parent's resume (RFC-0010 §6).
    #
    # It holds no delegation logic itself: `execute` reads the parent TurnState
    # (the subagents allowlist + resolved model for inheritance + depth) and hands
    # off to `Executor#run_subagent`, which spawns the isolated child turn and
    # returns its result. The child result = its text + the linked child session
    # id (§4.3 R3).
    class Subagent < RubyLLM::Tool
      description "Delegates a self-contained task to a specialized child agent. " \
                  "The child runs in an ISOLATED context (it does not see this " \
                  "conversation) — pass everything it needs in `message`. By default " \
                  "it BLOCKS and returns the child's final answer. Set async:true to " \
                  "fire-and-forget a long task: it returns immediately and the child's " \
                  "result arrives later as a new message on this conversation."
      param :agent, desc: "Id of the child agent to delegate to (must be one this agent may spawn)"
      param :message, desc: "The self-contained task/prompt for the child agent"
      param :async, type: :boolean, required: false,
                    desc: "true = dispatch and continue (result delivered later); default false = wait for the answer"

      # otherwise RubyLLM derives "harness--tools--subagent" from the class name.
      def name = "spawn_subagent"

      def initialize(runner:, state:)
        @runner = runner
        @state = state
        super()
      end

      # The child result is returned to the model as the tool result. On error we
      # return { error: } (never raise) — a bad `agent`/depth/child failure is a
      # message to the model, not a turn-killer (parity with A2ARemote).
      def execute(agent:, message:, async: false)
        result = @runner.run_subagent(agent: agent.to_s, message: message.to_s,
                                      parent_state: @state, async: async == true)
        return { error: result[:error] } if result[:error]

        # async dispatch: the ack (the child result arrives later as a new turn).
        return { dispatched: true, agent: result[:agent], session_id: result[:session_id] } if result[:dispatched]

        # sync: link the child session id alongside the text so a multi-step parent
        # can reference it and the transcript stays auditable (§4.3 R3 / §7).
        { text: result[:text], session_id: result[:session_id] }
      end
    end
  end
end
