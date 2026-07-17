# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Level 1 (progressive disclosure) of the profile's CANDIDATE skills.
      # The Executor's LoadSkill does NOT come from here: it is built with
      # resolution.allowed_skills (a policy decision). Context->Policy order: the
      # provider produces the candidate; the policy cuts afterwards.
      class Skill < CatalogProvider
        # priority 80: above deferred tools (70), below pinned identity.
        def priority = Context::Priority::SKILL

        private

        def entries(request) = @catalog.effective(request.profile.skills)
      end
    end
  end
end
