# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # :system fragment with turn metadata (tenant, relevant vars).
      # Nothing if there is no metadata. priority 40. Not required?
      # (metadata may degrade).
      class Request < ContextProvider
        def call(request)
          lines = []
          lines << "tenant: #{request.tenant}" if request.tenant
          # "history" is transcript (consumed by the Session provider), not turn
          # metadata — it does not leak into the system's request_context.
          request.vars.to_h.each { |k, v| lines << "#{k}: #{v}" unless k.to_s == "history" }
          return [] if lines.empty?

          [ContextFragment.build(
            content: "<request_context>\n#{lines.join("\n")}\n</request_context>",
            placement: :system, priority: Context::Priority::REQUEST, source: id
          )]
        end
      end
    end
  end
end
