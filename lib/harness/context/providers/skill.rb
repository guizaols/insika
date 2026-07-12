# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Nível 1 (progressive disclosure) das skills CANDIDATAS do perfil.
      # A LoadSkill do Executor NÃO vem daqui: ela é construída com
      # resolution.allowed_skills (decisão de policy). Ordem Context->Policy: o
      # provider produz candidato; a policy corta depois.
      class Skill < CatalogProvider
        # priority 80: acima das tools deferred (70), abaixo da identidade pinned.
        def priority = 80

        private

        def entries(request) = @catalog.effective(request.profile.skills)
      end
    end
  end
end
