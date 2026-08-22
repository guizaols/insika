# frozen_string_literal: true

require "json"

module Insika
  # LIVE MCP ingestion (/ spec): discovers the tools of an
  # MCP instance at RUNTIME (no hand-written manifest) and ingests them as
  # data-tools. Given an McpStore instance + an INJECTABLE MCP client
  # (duck-typed: `#list_tools -> [{name, description, inputSchema}]`), it builds a
  # ToolManifest and REUSES the ingestion path (the:import_tools Command:
  # batch upsert into the ToolStore + hot reload + per-tool report + partial-
  # failure isolation R4). The ToolManifest MCP adapter (`inputSchema`) is reused
  # — no schema parsing here.
  #
  # GENERIC: nothing here mentions a consumer/gateway. The MCP instance is DATA in the store.
  #
  # BINDING STRATEGY (this stage's choice, bounded):
  #   Each discovered tool becomes an HTTP data-tool that makes a JSON-RPC 2.0
  #   `tools/call` POST to the instance endpoint (url). The tool name is resolved
  #   at INGESTION (literal in the body); the model's arguments come in as `{{param}}`
  #   per TOP-level property of the inputSchema (with quoting by type — strings
  #   quoted, others raw, via the DataDefinedTool :body encode). This way the tool
  #   runs through the SAME HTTP path as the other data-tools (egress guard, secret
  #   headers, hot reload) — no new execution code.
  #
  #   Each tool gets `group: "mcp:<instance>"` so the per-group gating
  #   (tools_allow_groups) works for free.
  #
  # DEFERRED / OUT-OF-SCOPE (documented — spec):
  #   - Real MCP transport: only instances with a `url` (http transport) are ingestible;
  #     stdio has no HTTP endpoint -> raises a clear error (later work).
  #   - MCP session lifecycle (initialize/negotiation/session-id/notifications) and the
  #     UNWRAP of the `tools/call` response (`{content:[{type,text}]}`) — the binding
  #     makes a stateless POST and returns the raw body (extract body_raw). A server
  #     that requires the handshake before answering `tools/list`/`tools/call` is not
  #     reachable yet — that IS the real transport, not this minimal client.
  #   - Tools whose name/top-level property is outside the ToolDefinition NAME_RE
  #     (uppercase/hyphens) are ISOLATED into `errors[]` by the import (R4).
  #
  # CREDENTIAL INJECTION: the instance `env` (Hash) is sent verbatim as HTTP
  # headers, on BOTH the discovery request (`tools/list`, this file) and every
  # ingested tool's `tools/call` binding (`build_manifest`'s `defaults.headers`)
  # — literal header-name -> value, the same convention as a data-tool's own
  # `secret_headers` (the operator types the full value, "Bearer xxx" included;
  # no magic prefixing). An instance with no `env` sends the bare
  # `Content-Type` header only, byte-for-byte what shipped before this.
  class McpToolIngestor
    def initialize(mcp_store:, import_tools:, client_factory: nil)
      @mcp_store = mcp_store
      @import_tools = import_tools
      # Per-instance client factory (default: minimal JSON-RPC HTTP client).
      # Injectable for tests (Fake) and to swap for a real transport later.
      @client_factory = client_factory || method(:default_client)
    end

    # Discovers + ingests the tools of instance `name`. `client` is injectable
    # (Fake in tests); absent -> the factory builds one from the record. -> the
    # import_tools report + `instance:` ({ instance:, version:, created:, updated:, errors: }).
    def ingest(name, client: nil)
      manifest = manifest_for(name, client: client)
      report = @import_tools.call(Insika::Command.build(:import_tools, manifest, transport: :internal))
      report.merge(instance: name.to_s)
    end

    # Discovers the tools and builds the manifest Hash (without ingesting) — isolable for testing.
    def manifest_for(name, client: nil)
      record = @mcp_store.get_raw(name.to_s)
      raise Insika::NotFoundError, "MCP instance '#{name}' not found" if record.nil?
      raise Insika::ValidationError, "MCP instance '#{name}' is disabled" unless record["enabled"]

      url = presence(record["url"])
      if url.nil?
        raise Insika::ValidationError,
              "MCP instance '#{name}' has no url: live ingestion requires HTTP transport " \
              "(stdio is later work)"
      end

      tools = Array((client || @client_factory.call(record)).list_tools)
      build_manifest(name.to_s, url, tools, env_headers(record))
    end

    private

    # `headers` (an http/sse instance's credentials — `env` reads
    # as `headers` for these transports via McpStore's migration-on-read, see
    # McpStore#migrate_legacy_headers) -> literal HTTP headers (header-NAME ->
    # value; the value carries its own scheme, e.g. "Bearer xxx" — no magic
    # prefixing). NOT `secret_headers`: ToolManifest's own rule for a secret
    # header requires a `{{secret.*}}` reference, which is the opposite of what
    # a literal credential is — so an MCP instance's headers are NOT masked in
    # a tool's edit page in /studio/tools, unlike a hand-authored data-tool's
    # Authorization header. Acceptable for now (Studio is already
    # operator-gated); a real fix routes this through the deployment's own
    # {{secret.*}}/{{env.*}} resolution instead — later work.
    def env_headers(record)
      (record["headers"] || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
    end

    def build_manifest(name, url, tools, headers)
      {
        "version" => 1,
        "defaults" => {
          "method" => "POST",
          "headers" => { "Content-Type" => "application/json" }.merge(headers),
          "response" => { "extract" => "body_raw" },
          "group" => "mcp:#{name}"
        },
        "tools" => tools.map { |raw| tool_entry(name, url, stringify(raw)) }
      }
    end

    # Raw MCP entry -> manifest entry (MCP `inputSchema` envelope + JSON-RPC
    # binding). ToolManifest normalizes the `inputSchema` (MCP adapter) and
    # inherits the defaults; `group` falls through from the defaults.
    def tool_entry(name, url, raw)
      tool_name = raw["name"]
      input_schema = raw["inputSchema"] || {}
      {
        "name" => tool_name,
        "description" => presence(raw["description"]) || "Tool '#{tool_name}' from MCP server '#{name}'.",
        "inputSchema" => input_schema,
        "url" => url,
        "side_effect" => true, # a tools/call is a side effect (checkpoint/skip-on-resume)
        "body" => jsonrpc_call_body(tool_name, input_schema)
      }
    end

    # JSON-RPC 2.0 `tools/call` body. `name` literal (resolved at ingestion);
    # `arguments` per TOP-level property of the inputSchema, with `{{param}}` that
    # the DataDefinedTool interpolates at TURN time.
    def jsonrpc_call_body(tool_name, input_schema)
      %({"jsonrpc":"2.0","id":1,"method":"tools/call",) +
        %("params":{"name":#{JSON.generate(tool_name)},"arguments":#{arguments_fragment(input_schema)}}})
    end

    # -> "{...}" JSON with one placeholder per top-level property. Strings are
    # quoted (the DataDefinedTool :body encode returns the escaped content WITHOUT
    # quotes); other types raw (the encode returns value.to_json).
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
      Insika::McpHttpClient.new(url: record["url"], headers: env_headers(record))
    end

    def presence(str) = Insika::Coercion.presence(str)

    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      else obj
      end
    end
  end
end
