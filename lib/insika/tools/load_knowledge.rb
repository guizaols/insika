# frozen_string_literal: true

require "ruby_llm"
require "time"

module Insika
  module Tools
    # Level 2 of knowledge's progressive disclosure: loads a learned
    # concept's full body on demand, by the name the `<knowledge>` block
    # listed. Same shape as `LoadSkill` — a system default (outside the
    # allowlist), wired only when the profile opted in
    # (`knowledge.retrieve`), never through `tools_allow`.
    #
    # `require "ruby_llm"` stays in THIS file (it inherits from
    # RubyLLM::Tool), so it does NOT enter lib/insika.rb — the Executor
    # loads it lazily inside create_chat, same as load_skill.
    class LoadKnowledge < RubyLLM::Tool
      description "Loads the complete content of a learned concept by name"
      param :name, desc: "Exact concept name, as listed in <knowledge>"

      # RubyLLM::Tool#name derives from self.class.name — for a nested class it
      # produces "insika--tools--load_knowledge", not "load_knowledge" (which
      # wire_callbacks/:knowledge_retrieved assume). Explicit override, same
      # reason LoadSkill has one.
      def name = "load_knowledge"

      # trace_recorder/state are OPTIONAL (nil = no trace, parity): this tool
      # is deliberately NOT enveloped (ToolAssembly#wrap_tools), so without
      # recording HERE the call is missing from the Studio's trace — same
      # shape as LoadSkill.
      def initialize(store, agent_id, tenant: nil, trace_recorder: nil, state: nil)
        @store = store
        @agent_id = agent_id
        @tenant = tenant
        @trace_recorder = trace_recorder
        @state = state
        super()
      end

      def execute(name:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = load(name)
        trace(name, result, started)
        result
      end

      private

      def load(name)
        content = @store.get(@agent_id, name.to_s, tenant: @tenant)
        return { error: "concept '#{name}' not found" } unless content

        content
      end

      # Mirrors LoadSkill#trace (same entry shape, so the Studio renders it
      # like any other call). NEVER breaks the turn — the trace is
      # observability, not the answer.
      def trace(name, result, started)
        return unless @trace_recorder && @state&.task&.session_id

        @trace_recorder.record(
          session_id: @state.task.session_id,
          entry: { "turn" => @state.turn, "tool" => "load_knowledge", "call_id" => "",
                   "args" => { "name" => name.to_s }, "result" => result,
                   "ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
                   "at" => Time.now.utc.iso8601 }
        )
      rescue StandardError
        nil
      end
    end
  end
end
