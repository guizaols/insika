# frozen_string_literal: true

module Insika
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

        # Only the skills the model still has to ASK for. An eager skill is already in
        # the prompt in full, so advertising it here would invite a `load_skill` call
        # that buys a duplicate — and the catalog's whole job is to describe what is
        # NOT yet loaded. Nothing lazy left -> CatalogProvider emits no fragment.
        def entries(request) = @catalog.lazy_for(request.profile)
      end
    end
  end
end
