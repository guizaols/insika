# frozen_string_literal: true

require "json"

module Harness
  # Ingestão MCP LIVE (Fase 7, Etapa E / spec §4 D8): descobre as tools de uma
  # instância MCP em RUNTIME (sem manifesto escrito à mão) e as ingere como
  # data-tools. Dada uma instância do McpStore + um cliente MCP INJETÁVEL
  # (duck-typed: `#list_tools -> [{name, description, inputSchema}]`), constrói um
  # ToolManifest e REUSA o caminho de ingestão da Etapa B (o Command :import_tools:
  # upsert em lote no ToolStore + reload hot + relatório por-tool + isolamento de
  # falha parcial R4). O adapter MCP do ToolManifest (`inputSchema`) é reaproveitado
  # — nada de parsing de schema aqui.
  #
  # GENÉRICO (NF1): nada aqui cita achei/openclaw. A instância MCP é DADO no store.
  #
  # ESTRATÉGIA DE BINDING (escolha desta etapa, bounded):
  #   Cada tool descoberta vira uma data-tool HTTP que faz um POST JSON-RPC 2.0
  #   `tools/call` no endpoint (url) da instância. O nome da tool é resolvido na
  #   INGESTÃO (literal no body); os argumentos do modelo entram como `{{param}}`
  #   por propriedade de TOPO do inputSchema (com aspas por tipo — string entre
  #   aspas, demais crus, via o encode :body do DataDefinedTool). Assim a tool roda
  #   no MESMO caminho HTTP das demais data-tools (egress guard, secret headers,
  #   reload hot) — sem código novo de execução.
  #
  #   Cada tool recebe `group: "mcp:<instância>"` para o gating por grupo da Etapa C
  #   (tools_allow_groups) funcionar de graça.
  #
  # DEFERIDO / OUT-OF-SCOPE (documentado — spec §4 D8):
  #   - Transporte MCP real: só instâncias com `url` (transport http) são ingeríveis;
  #     stdio não tem endpoint HTTP -> levanta erro claro (trabalho posterior).
  #   - Ciclo de sessão MCP (initialize/negociação/session-id/notifications) e o
  #     UNWRAP da resposta `tools/call` (`{content:[{type,text}]}`) — o binding faz
  #     um POST stateless e devolve o body cru (extract body_raw).
  #   - Injeção de credencial (o `env` da instância) como header de auth no binding
  #     HTTP: o `env` é consumido por um cliente MCP real (deferido), não mapeado
  #     para header aqui.
  #   - Tools com nome/propriedade-de-topo fora do NAME_RE do ToolDefinition
  #     (maiúsculas/hífens) são ISOLADAS em `errors[]` pelo import (R4).
  class McpToolIngestor
    def initialize(mcp_store:, import_tools:, client_factory: nil)
      @mcp_store = mcp_store
      @import_tools = import_tools
      # Fábrica de cliente por instância (default: cliente HTTP JSON-RPC mínimo).
      # Injetável para testes (Fake) e para trocar por um transporte real depois.
      @client_factory = client_factory || method(:default_client)
    end

    # Descobre + ingere as tools da instância `name`. `client` injetável (Fake nos
    # testes); ausente -> a fábrica constrói do record. -> relatório do import_tools
    # + `instance:`  ({ instance:, version:, created:, updated:, errors: }).
    def ingest(name, client: nil)
      manifest = manifest_for(name, client: client)
      report = @import_tools.call(Harness::Command.build(:import_tools, manifest, transport: :internal))
      report.merge(instance: name.to_s)
    end

    # Descobre as tools e monta o Hash de manifesto (sem ingerir) — isolável p/ teste.
    def manifest_for(name, client: nil)
      record = @mcp_store.get_raw(name.to_s)
      raise Harness::NotFoundError, "instância MCP '#{name}' não encontrada" if record.nil?
      raise Harness::ValidationError, "instância MCP '#{name}' está desabilitada" unless record["enabled"]

      url = presence(record["url"])
      if url.nil?
        raise Harness::ValidationError,
              "instância MCP '#{name}' sem url: a ingestão live requer transport HTTP " \
              "(stdio é trabalho posterior — D8)"
      end

      tools = Array((client || @client_factory.call(record)).list_tools)
      build_manifest(name.to_s, url, tools)
    end

    private

    def build_manifest(name, url, tools)
      {
        "version" => 1,
        "defaults" => {
          "method" => "POST",
          "headers" => { "Content-Type" => "application/json" },
          "response" => { "extract" => "body_raw" },
          "group" => "mcp:#{name}"
        },
        "tools" => tools.map { |raw| tool_entry(name, url, stringify(raw)) }
      }
    end

    # Entrada MCP crua -> entrada de manifesto (envelope MCP `inputSchema` + binding
    # JSON-RPC). O ToolManifest normaliza o `inputSchema` (adapter MCP) e herda os
    # defaults; o `group` cai por herança do defaults.
    def tool_entry(name, url, raw)
      tool_name = raw["name"]
      input_schema = raw["inputSchema"] || {}
      {
        "name" => tool_name,
        "description" => presence(raw["description"]) || "Tool '#{tool_name}' do servidor MCP '#{name}'.",
        "inputSchema" => input_schema,
        "url" => url,
        "side_effect" => true, # uma tools/call é efeito (checkpoint/skip-on-resume)
        "body" => jsonrpc_call_body(tool_name, input_schema)
      }
    end

    # Body JSON-RPC 2.0 `tools/call`. `name` literal (resolvido na ingestão);
    # `arguments` por propriedade de TOPO do inputSchema, com `{{param}}` que o
    # DataDefinedTool interpola no TURNO.
    def jsonrpc_call_body(tool_name, input_schema)
      %({"jsonrpc":"2.0","id":1,"method":"tools/call",) +
        %("params":{"name":#{JSON.generate(tool_name)},"arguments":#{arguments_fragment(input_schema)}}})
    end

    # -> "{...}" JSON com um placeholder por propriedade de topo. String entre
    # aspas (o encode :body do DataDefinedTool devolve o conteúdo escapado SEM
    # aspas); demais tipos crus (o encode devolve value.to_json).
    def arguments_fragment(input_schema)
      props = (input_schema["properties"] || input_schema[:properties] || {})
      return "{}" if props.nil? || props.empty?

      pairs = props.map do |key, spec|
        type = stringify(spec)["type"].to_s
        placeholder = type == "string" ? %("{{#{key}}}") : "{{#{key}}}"
        %(#{JSON.generate(key.to_s)}:#{placeholder})
      end
      "{#{pairs.join(',')}}"
    end

    def default_client(record)
      Harness::McpHttpClient.new(url: record["url"])
    end

    def presence(str) = Harness::Coercion.presence(str)

    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      else obj
      end
    end
  end
end
