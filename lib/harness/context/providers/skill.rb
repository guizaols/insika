# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Adapta o SkillCatalog: visão CANDIDATA das skills (nível 1
      # do progressive disclosure). Adaptador FINO — não reimplementa
      # effective/format_for_prompt (o catálogo é intocado).
      #
      # A LoadSkill do Executor NÃO vem daqui: ela é construída com
      # resolution.allowed_skills (decisão de policy), não com a
      # visão candidata do provider. Ordem constitucional Context->Policy: o
      # provider produz candidato; a policy corta depois.
      class Skill < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          skills = @catalog.effective(request.profile.skills)
          block = @catalog.format_for_prompt(skills)
          return [] if block.empty?

          # pinned: false — a ordem de sacrifício é: histórico antigo ->
          # histórico recente -> skills -> (identidade pinned, nunca).
          [ContextFragment.build(content: block, placement: :system,
                                 priority: 80, source: id)]
        end
      end
    end
  end
end
