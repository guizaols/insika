# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Fragmento :system com metadados do turno (tenant, vars relevantes).
      # Nada se não houver metadados (doc 04 §2). priority 40. Não é required?
      # (metadados podem degradar — L5).
      class Request < ContextProvider
        def call(request)
          lines = []
          lines << "tenant: #{request.tenant}" if request.tenant
          request.vars.to_h.each { |k, v| lines << "#{k}: #{v}" }
          return [] if lines.empty?

          [ContextFragment.build(
            content: "<request_context>\n#{lines.join("\n")}\n</request_context>",
            placement: :system, priority: 40, source: id
          )]
        end
      end
    end
  end
end
