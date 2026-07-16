# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Ingestão em LOTE de data-tools a partir de um manifesto (Fase 7, Etapa B).
    # Normaliza cada tool (defaults + adapter de envelope + endpoint→url + secret/
    # env) via ToolManifest, faz UPSERT no ToolStore e RECARREGA o overlay + o
    # catálogo UMA vez ao fim — passa a valer sem restart (NF3). Idempotente
    # (re-importar reconcilia). Injeta os resolvedores de `{{secret.*}}`/`{{env.*}}`
    # do deployment (D6/open-q2): o segredo NUNCA vem no manifesto.
    #
    # FALHA PARCIAL ISOLADA (R4): uma tool malformada (envelope inválido, endpoint
    # ausente, secret não configurado, colisão com tool de código, url inválida)
    # NÃO derruba o lote — vira uma entrada em `errors[]`. Só erro ESTRUTURAL do
    # manifesto (defaults/tools do tipo errado) levanta (o transporte -> 422).
    # Relatório por-tool no molde do pack importer da Fase 6.
    #   -> { version, created: [names], updated: [names], errors: [{tool,error}] }
    class ImportTools
      def initialize(tool_store:, registry:, tool_catalog:, event_stream:, secrets: ENV, env: ENV)
        @tool_store = tool_store
        @registry = registry
        @tool_catalog = tool_catalog
        @event_stream = event_stream
        @secrets = secrets
        @env = env
      end

      def call(command)
        manifest = Harness::ToolManifest.from_h(command.payload) # estrutural -> 422
        report = { version: manifest.version, created: [], updated: [], errors: [] }

        manifest.tools.each_with_index do |raw, i|
          import_one(manifest, raw, i, report)
        end

        reload_hot unless report[:created].empty? && report[:updated].empty?
        emit(report)
        report
      end

      private

      def import_one(manifest, raw, index, report)
        defn = manifest.definition_for(raw, secrets: @secrets, env: @env)
        name = defn["name"].to_s
        raise Harness::ValidationError, "'#{name}' já é uma tool de código" if @registry.code_tool?(name)

        existed = !@tool_store.get(name).nil?
        @tool_store.write(defn)
        (existed ? report[:updated] : report[:created]) << name
      rescue Harness::Error => e
        report[:errors] << { tool: tool_label(raw, index), error: e.message }
      end

      def reload_hot
        @registry.reload
        @tool_catalog.reload
      end

      # Nome da tool p/ o relatório de erro; cai no índice quando o envelope nem
      # nome trouxe (não deixa a entrada de erro anônima).
      def tool_label(raw, index)
        h = raw.is_a?(Hash) ? raw : {}
        name = h["name"] || h[:name] || h.dig("function", "name") || h.dig(:function, :name)
        Harness::Coercion.presence(name) || "#<tool ##{index}>"
      end

      # Emite só CONTAGENS + nomes (nunca headers/secrets): 0 vazamento.
      def emit(report)
        @event_stream.emit(Harness::Event.new(
                             type: :tools_imported,
                             data: { created: report[:created].size, updated: report[:updated].size,
                                     errors: report[:errors].size },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
