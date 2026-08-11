# frozen_string_literal: true

require "ruby_llm"
require_relative "agent_enum"

module Insika
  module Tools
    # In-process delegation to a CHILD agent — the Flue
    # `session.task()` primitive. A system tool (like remember/load_skill): wired
    # by the ChatBuilder ONLY when `profile.subagents` is present, so `require
    # "ruby_llm"` stays in this file (loaded lazily in create_chat). NOT enveloped
    # (system tool) — in the synchronous mode the child lives in the parent's
    # envelope and re-runs on the parent's resume.
    #
    # It holds no delegation logic itself: `execute` reads the parent TurnState
    # (the subagents allowlist + resolved model for inheritance + depth) and hands
    # off to `Executor#run_subagent`, which spawns the isolated child turn and
    # returns its result. The child result = its text + the linked child session
    # id (R3).
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

      # otherwise RubyLLM derives "insika--tools--subagent" from the class name.
      def name = "spawn_subagent"

      def initialize(runner:, state:)
        @runner = runner
        @state = state
        @allowed = Array(state.profile.subagents).map(&:to_s)
        super()
      end

      # The parent's allowlist is per-TURN data, so it is named per instance: the
      # ids go into the description AND as an `enum` on `agent`. Measured, not
      # guessed — with only "must be one this agent may spawn" in the schema, a
      # real provider answered "let me check which agents are available" and then
      # did the work itself instead of delegating. A model cannot call what it
      # cannot name.
      def description
        return super if @allowed.empty?

        "#{super} Agents you may spawn: #{@allowed.join(', ')}."
      end

      def params_schema
        @agent_enum_schema ||= Insika::Tools::AgentEnum.inject(super, @allowed, path: %i[agent])
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
        # can reference it and the transcript stays auditable (R3).
        { text: result[:text], session_id: result[:session_id] }
      end
    end
  end
end
