# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Fragmento :system com metadados do turno (tenant, vars relevantes).
      # Nada se não houver metadados. priority 40. Não é required?
      # (metadados podem degradar).
      class Request < ContextProvider
        def call(request)
          lines = []
          lines << "tenant: #{request.tenant}" if request.tenant
          # "history" é transcript (consumido pelo Session provider), não metadado
          # do turno — não vaza para o request_context do system.
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
