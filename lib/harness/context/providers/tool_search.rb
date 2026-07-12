# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Adapta o ToolCatalog: nível 1 do
      # progressive disclosure de TOOLS deferred — mesma forma do Skill provider,
      # trocando skill por tool. Adaptador FINO — não reimplementa
      # subset/format_for_prompt (o catálogo é intocado).
      #
      # O recorte é `profile.tools_deferred`, conhecido no estágio 2 — igual ao
      # Skill provider, que usa `profile.skills` (não o `allowed_skills`
      # pós-Policy). O catálogo pode ser levemente sobre-inclusivo (mostrar um
      # deferred que a Policy depois nega); aceitável, consistente com a lista de
      # skills. O corte real acontece na PROMOÇÃO (tool_search, `deferred
      # ∩ allowed_tools`), não na exibição. NÃO montar isso no configure_chat
      # violaria "o Runtime nunca monta prompt".
      class ToolSearch < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          entries = @catalog.subset(request.profile.tools_deferred)
          block = @catalog.format_for_prompt(entries)
          return [] if block.empty?

          # pinned: false — priority 70, abaixo das skills (80): ordem de
          # sacrifício histórico -> tools deferred -> skills -> (identidade
          # pinned, nunca).
          [ContextFragment.build(content: block, placement: :system,
                                 priority: 70, source: id)]
        end
      end
    end
  end
end
