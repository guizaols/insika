# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Level-2 skill BODIES in the prompt, with two selection modes — both
      # deterministic, neither asks the model:
      #
      #   profile.skills_eager  -> ALL allowed skills, every turn. No decision at
      #                            all, so no miss rate. Costs the bodies' tokens.
      #   `triggers:` in the    -> only the skills whose trigger matches this
      #   frontmatter              message (substring, case-insensitive).
      #
      # Model-invoked loading (load_skill) stays the fallback for everything else.
      #
      # A trigger only belongs on a skill that can COMPLETE the turn by itself.
      # Injecting a reference table whose companion skill holds the procedure is
      # worse than injecting nothing: the model has a plausible half-recipe in the
      # prompt, so it never calls load_skill for the other half. Measured on a real
      # pack — the line map arrived, the query-construction rules did not, and the
      # searches came out malformed.
      # Activation here is NOT a tool call, so nothing in the transcript would show
      # it. The fragment's `labels` carry the names, and the EXECUTOR announces them
      # (:skill_activated) — not this provider. A provider only has the
      # ContextRequest, which has no task, and the Studio's SSE drops an event whose
      # meta lacks `task_id` when the subscriber is task-scoped (Subscription#matches?):
      # emitting from here produced an event that was correct and never arrived.
      class SkillTrigger < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          matched = select(request)
          return [] if matched.empty?

          content = matched.map do |skill|
            %(<active_skill name="#{skill.name}">\n#{skill.body}\n</active_skill>)
          end.join("\n\n")

          [ContextFragment.build(content: content, placement: :system,
                                 priority: Context::Priority::SKILL_BODY, source: id,
                                 labels: matched.map(&:name))]
        end

        private

        # Two independent reasons a body lands here, and a skill can have both:
        # it is `eager` (always), or a `triggers:` entry matched THIS message. The
        # union is injected; everything else stays at level 1 for load_skill, where
        # the model's call is the only record of what it reached for.
        def select(request)
          eager = @catalog.eager_for(request.profile)
          (eager + triggered(request)).uniq
        end

        def triggered(request)
          message = request.message.to_s.downcase
          return [] if message.empty?

          @catalog.lazy_for(request.profile)
                  .select { |skill| skill.triggers.any? { |t| message.include?(t.downcase) } }
        end
      end
    end
  end
end
