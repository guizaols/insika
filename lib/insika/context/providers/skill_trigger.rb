# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Level-2 skill BODIES in the prompt, with two selection modes — both
      # deterministic, neither asks the model:
      #
      #   profile.skills_eager  -> the agent's eager set (all, or a named list),
      #                            every turn. No decision at all, so no miss rate.
      #                            Costs the bodies' tokens.
      #   `triggers:` in the    -> only the skills whose trigger matches this
      #   frontmatter              message (whole word, accent- and case-insensitive).
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
      # it. The fragment's `labels` carry the name AND THE REASON, and the EXECUTOR
      # announces them (:skill_activated) — not this provider. A provider only has the
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

          content = matched.map do |skill, _reason|
            %(<active_skill name="#{skill.name}">\n#{skill.body}\n</active_skill>)
          end.join("\n\n")

          labels = matched.map { |skill, reason| { "name" => skill.name, "reason" => reason } }
          [ContextFragment.build(content: content, placement: :system,
                                 priority: Context::Priority::SKILL_BODY, source: id,
                                 labels: labels)]
        end

        private

        # -> [[skill, reason]]. Two independent reasons a body lands here: the AGENT
        # marked it eager (always), or a `triggers:` entry matched THIS message.
        # The union is injected; everything else stays at level 1 for load_skill, where
        # the model's call is the only record of what it reached for.
        #
        # The reason travels with the skill from here to the activation card, because
        # "which skills were active" without "why each one was" is the information the
        # deterministic paths destroyed when they replaced the load_skill call.
        def select(request)
          eager = @catalog.eager_for(request.profile).map { |skill| [skill, "eager"] }
          # `triggered` reads the LAZY set, which excludes the eager one — so a skill
          # cannot arrive twice. uniq_by name anyway: the invariant is worth not
          # depending on from here.
          selected = (eager + triggered(request)).uniq { |skill, _reason| skill.name }
          (selected + companions(selected, request)).uniq { |skill, _reason| skill.name }
        end

        # Declared `companions:` travel with whatever brought them, so the half-recipe
        # state cannot be assembled: the line map that arrived by trigger takes its
        # query-construction rules with it. ONE LEVEL, deliberately — a transitive walk
        # would make a cycle a hang and a chain a budget blowout, and "cannot work
        # without" is a direct relationship.
        #
        # Restricted to the agent's own allowed set: a companion the agent cannot see
        # is not injectable, and `doctor` flags that declaration rather than the engine
        # quietly widening the allowlist.
        def companions(selected, request)
          wanted = selected.flat_map { |skill, _reason| Array(skill.companions).map { |c| [c.to_s, skill.name] } }
          return [] if wanted.empty?

          by_name = @catalog.effective(request.profile.skills, agent: request.profile.id)
                            .each_with_object({}) { |s, acc| acc[s.name] = s }
          wanted.filter_map do |name, of|
            skill = by_name[name]
            [skill, "companion:#{of}"] if skill
          end
        end

        def triggered(request)
          message = fold(request.message)
          return [] if message.empty?

          @catalog.lazy_for(request.profile).filter_map do |skill|
            phrase = matched_trigger(skill, message)
            [skill, "trigger:#{phrase}"] if phrase
          end
        end

        # The trigger phrase that fired, or nil. AS AUTHORED, never as typed: the
        # reason lands on the activation card, and what an operator needs there is the
        # config line they can go and edit — not an echo of the customer's message
        # (which also keeps the label content-free, like the rest of the trace).
        #
        # Two hygiene rules, and both are tokenization rather than the semantic
        # matching this feature deliberately does not do:
        #
        #   whole word — bare substring made `triggers: presente` fire inside
        #   *apresente*, and the card now PRINTS the matched phrase: `trigger:presente`
        #   on a turn about *apresentação* would discredit the card on day one.
        #
        #   folded accents — the corpus is Portuguese and customers type *maquiagem*
        #   and *maquiágem* unpredictably, so both sides are folded before comparing.
        def matched_trigger(skill, folded_message)
          skill.triggers.find do |trigger|
            needle = fold(trigger)
            next false if needle.empty?

            /(?<![[:alnum:]])#{Regexp.escape(needle)}(?![[:alnum:]])/.match?(folded_message)
          end
        end

        # NFD splits an accented letter into letter + combining mark; dropping the
        # marks (\p{Mn}) leaves the bare letter, so "maquiágem" and "maquiagem" fold
        # to the same string.
        def fold(text) = text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
      end
    end
  end
end
