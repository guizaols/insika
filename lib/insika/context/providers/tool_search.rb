# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Level 1 (progressive disclosure) of the profile's deferred TOOLS. The
      # slice is `profile.tools_deferred`, known at stage 2 — it may be slightly
      # over-inclusive (showing a deferred tool the Policy later denies); acceptable,
      # the real cut happens at PROMOTION (tool_search, `deferred ∩ allowed`).
      class ToolSearch < CatalogProvider
        # priority 70: below skills (80) in the sacrifice order.
        def priority = Context::Priority::TOOL_SEARCH
        # RFC-0030 C1: tool registry + tools_deferred — config only.
        def layer = :identity

        private

        def entries(request) = @catalog.subset(request.profile.tools_deferred)
      end
    end
  end
end
