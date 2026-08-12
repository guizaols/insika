# frozen_string_literal: true

require "ruby_llm"
require "time"

module Insika
  module Tools
    # Level 2 of progressive disclosure: loads the full SKILL.md body
    # on demand. Respects the agent's allowlist (the model does not load a
    # skill that the policy did not expose).
    #
    # `require "ruby_llm"` stays in THIS file (it inherits from
    # RubyLLM::Tool), which is why it does NOT enter lib/insika.rb: the Executor
    # loads it lazily inside create_chat.
    class LoadSkill < RubyLLM::Tool
      description "Loads the complete instructions (SKILL.md) of a skill by name"
      param :name, desc: "Exact skill name, as listed in <available_skills>"

      # RubyLLM::Tool#name derives from self.class.name — for a nested class it produces
      # "insika--tools--load_skill", not "load_skill" (which wire_callbacks/
      # :skill_activated and SkillCatalog#format_for_prompt assume). Explicit
      # override. Coexists with
      # `param :name` (verified: the param is still present).
      def name = "load_skill"

      # trace_recorder/state are OPTIONAL (nil = no trace, parity): this tool is
      # deliberately NOT enveloped (ToolAssembly#wrap_tools), and the envelope is
      # what records the tool trace — so without recording HERE, the one call an
      # operator most needs to audit is the only one missing from the Studio's
      # trace. Same shape as ToolSearch, which also emits its own event.
      def initialize(catalog, allowed_names, trace_recorder: nil, state: nil)
        @catalog = catalog
        @allowed = Array(allowed_names).map(&:to_s)
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
        return { error: "skill '#{name}' not available for this agent" } unless @allowed.include?(name.to_s)

        skill = @catalog.find(name)
        return { error: "skill '#{name}' not found" } unless skill

        skill.body
      end

      # Mirrors ToolEnvelope#trace (same entry shape, so the Studio renders it
      # like any other call). Clipping/masking is the ToolTraceStore's job.
      # NEVER breaks the turn — the trace is observability.
      def trace(name, result, started)
        return unless @trace_recorder && @state&.task&.session_id

        @trace_recorder.record(
          session_id: @state.task.session_id,
          entry: { "turn" => @state.turn, "tool" => "load_skill", "call_id" => "",
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
