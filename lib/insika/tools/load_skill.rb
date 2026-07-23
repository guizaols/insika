# frozen_string_literal: true

require "ruby_llm"

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

      def initialize(catalog, allowed_names)
        @catalog = catalog
        @allowed = Array(allowed_names).map(&:to_s)
        super()
      end

      def execute(name:)
        return { error: "skill '#{name}' not available for this agent" } unless @allowed.include?(name.to_s)

        skill = @catalog.find(name)
        return { error: "skill '#{name}' not found" } unless skill

        skill.body
      end
    end
  end
end
