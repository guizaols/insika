# frozen_string_literal: true

module Harness
  module Context
    # Base for providers that inject level 1 of a catalog (skills, deferred
    # tools) as a :system fragment. The subclass says WHICH entries and the
    # priority; the fragment assembly (format -> skip if empty -> a single
    # fragment with source = the provider id) is shared.
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
