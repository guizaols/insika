# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Deterministic skill activation. A skill can declare `triggers:` in its
      # frontmatter; when the current user message matches one (substring,
      # case-insensitive), the skill BODY is injected for this turn — no model
      # decision, no load_skill call. Selective by construction: only the
      # matched skills, only this turn. Model-invoked loading (load_skill)
      # stays as the fallback for everything without a matching trigger.
      class SkillTrigger < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          message = request.message.to_s.downcase
          return [] if message.empty?

          matched = @catalog.effective(request.profile.skills).select do |skill|
            skill.triggers.any? { |trigger| message.include?(trigger.downcase) }
          end
          return [] if matched.empty?

          content = matched.map do |skill|
            %(<active_skill name="#{skill.name}">\n#{skill.body}\n</active_skill>)
          end.join("\n\n")

          [ContextFragment.build(content: content, placement: :system,
                                 priority: Context::Priority::SKILL_BODY, source: id)]
        end
      end
    end
  end
end
