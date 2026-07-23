# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # PARALLEL fan-out of child agents (RFC-0010 §A): delegate N self-contained
    # tasks at once and get all answers back together, in ONE parent turn. Sibling
    # of `spawn_subagent` (single); this one always sync-joins — the children run
    # concurrently (their provider waits overlap on the reactor) and the combined
    # result comes back as this tool's result. A system tool wired by the ChatBuilder
    # when `profile.subagents` is present; `require "ruby_llm"` stays in this file
    # (loaded lazily in create_chat). NOT enveloped (children live in the parent's
    # envelope, same as the sync single).
    class Subagents < RubyLLM::Tool
      description "Delegates SEVERAL self-contained tasks to child agents IN " \
                  "PARALLEL and returns all their answers together. Use this — not " \
                  "repeated spawn_subagent calls — when you have multiple independent " \
                  "subtasks whose results you'll combine: it runs them concurrently " \
                  "(much faster). Each child runs in an ISOLATED context, so put " \
                  "everything it needs in its `message`."
      # array-of-objects param via the explicit JSON-schema form (the `param` DSL
      # only reaches strings/scalars). Top-level `tasks` arrives as a kwarg to execute.
      params(
        type: "object",
        properties: {
          tasks: {
            type: "array",
            description: "The independent subtasks to run in parallel",
            items: {
              type: "object",
              properties: {
                agent: { type: "string", description: "id of the child agent (must be one this agent may spawn)" },
                message: { type: "string", description: "the self-contained task/prompt for that child" }
              },
              required: %w[agent message]
            }
          }
        },
        required: %w[tasks]
      )

      # otherwise RubyLLM derives "insika--tools--subagents" from the class name.
      def name = "spawn_subagents"

      def initialize(runner:, state:)
        @runner = runner
        @state = state
        super()
      end

      # -> { results: [{agent:, text:, session_id:} | {agent:, error:}] } | { error: }.
      # Never raises: a bad envelope / per-task failure is a message to the model.
      def execute(tasks:)
        result = @runner.run_subagents(tasks: Array(tasks), parent_state: @state)
        return { error: result[:error] } if result[:error]

        { results: result[:results] }
      end
    end
  end
end
