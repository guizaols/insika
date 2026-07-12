# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Nível 1 (progressive disclosure) das TOOLS deferred do perfil. O recorte
      # é `profile.tools_deferred`, conhecido no estágio 2 — pode ser levemente
      # sobre-inclusivo (mostrar um deferred que a Policy depois nega); aceitável,
      # o corte real acontece na PROMOÇÃO (tool_search, `deferred ∩ allowed`).
      class ToolSearch < CatalogProvider
        # priority 70: abaixo das skills (80) na ordem de sacrifício.
        def priority = 70

        private

        def entries(request) = @catalog.subset(request.profile.tools_deferred)
      end
    end
  end
end
