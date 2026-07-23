# frozen_string_literal: true

module Insika
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
          # metadata — it does not leak into the system's request_context. Keys
          # prefixed with "__" are INTERNAL slots (e.g. the per-chat model pin
          # "__llm__", §10) — reserved, never rendered to the model.
          request.vars.to_h.each do |k, v|
            next if k.to_s == "history" || k.to_s.start_with?("__")

            lines << "#{k}: #{v}"
          end
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
