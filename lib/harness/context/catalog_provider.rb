# frozen_string_literal: true

module Harness
  module Context
    # Base dos providers que injetam o nível 1 de um catálogo (skills, tools
    # deferred) como um fragmento :system. A subclasse diz QUAIS entries e a
    # prioridade; a montagem do fragmento (formatar -> pular se vazio -> um
    # fragmento com source = id do provider) é uma só.
    class CatalogProvider < ContextProvider
      def initialize(catalog:)
        @catalog = catalog
      end

      def call(request)
        block = @catalog.format_for_prompt(entries(request))
        return [] if block.empty?

        [ContextFragment.build(content: block, placement: :system,
                               priority: priority, source: id)]
      end
    end
  end
end
