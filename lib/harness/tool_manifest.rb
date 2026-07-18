# frozen_string_literal: true

module Harness
  # Tool manifest (Phase 7, Step B): the BATCH, DATA-driven, industry-STANDARD
  # (JSON Schema) form of the data-tools. A `defaults` (common binding:
  # base_url/path_template/method/headers/secret_headers/response) + a list of
  # `tools`. Each tool is normalized — inheriting the defaults, applying the envelope
  # adapter (OpenAI/MCP/raw) and resolving `endpoint`→url + `{{secret.*}}`/
  # `{{env.*}}` — into a ToolDefinition Hash consumable by the ToolStore.
  #
  # GENERIC (NF1): nothing here mentions consumer/openclaw — the manifest IS the contract. It
  # only NORMALIZES/RESOLVES; the final validation (method/url/types, model placeholders
  # `{{param}}`/turn `{{ctx.*}}`, safe subset of JSON Schema) belongs to
  # ToolDefinition (single source). The batch upsert + hot reload belongs to the
  # :import_tools Command (which injects the secret/env resolvers).
  #
  # Two placeholder classes by resolution MOMENT:
  #   - `{{param}}`/`{{ctx.*}}` : resolved AT THE TURN (by DataDefinedTool) —
  #     they stay INTACT here; ToolDefinition validates them.
  #   - `{{secret.*}}`/`{{env.*}}` : resolved AT INGESTION (here) — from the deployment,
  #     never from the manifest (D6/R3). `{{env.*}}` is non-secret config (any
  #     template); `{{secret.*}}` is a credential and is ONLY allowed in a header
  #     declared in `secret_headers`, with value === `{{secret.X}}` (nothing literal,
  #     nothing outside a header — otherwise the secret would leak without masking).
  #
  # Interface envelope (what the model sees), by adapter (D3):
  #   - `parameters` (raw JSON Schema), OR
  #   - `{ "function": { name, description, parameters } }` (OpenAI/Anthropic), OR
  #   - `{ "inputSchema": {...} }` (MCP).
  ToolManifest = Data.define(:version, :defaults, :tools)

  # Reopens the class (constants inside a Data.define block land in the wrong LEXICAL
  # scope — same pattern as the sibling ToolDefinition).
  class ToolManifest
    ENV_PREFIX = "env."
    SECRET_PREFIX = "secret."
    private_constant :ENV_PREFIX, :SECRET_PREFIX

    # Raw Hash (string|symbol keys) -> ToolManifest. Validates only the top-level
    # STRUCTURE (version/defaults/tools); each tool's content is validated during
    # normalization (per-tool, isolable by the Command — R4). Raises ValidationError.
    def self.from_h(hash)
      h = stringify(hash || {})
      version = h.fetch("version", 1)
      defaults = h.fetch("defaults", {}) || {}
      tools = h.fetch("tools", []) || []
      raise Harness::ValidationError, "manifest: 'defaults' must be an object" unless defaults.is_a?(Hash)
      raise Harness::ValidationError, "manifest: 'tools' must be a list" unless tools.is_a?(Array)

      new(version: version, defaults: defaults, tools: tools)
    end

    # -> [ { ToolDefinition hash } ] with inherited defaults, normalized envelopes,
    # resolved endpoint→url and resolved secret/env. Raises on the FIRST malformed
    # tool — use #definition_for per-tool to isolate partial failure (R4).
    def tool_definitions(secrets:, env:)
      tools.map { |t| definition_for(t, secrets: secrets, env: env) }
    end

    # Normalizes ONE raw tool -> ToolDefinition Hash. Raises ValidationError
    # (invalid envelope, missing endpoint/url, secret/env not configured, R3).
    def definition_for(raw_tool, secrets:, env:)
      t = self.class.stringify(raw_tool || {})
      raise Harness::ValidationError, "tool must be an object" unless t.is_a?(Hash)

      interface = extract_interface(t)
      binding = build_binding(t, secrets, env)

      {
        "name" => interface[:name], "description" => interface[:description],
        "parameters" => interface[:parameters],
        "request" => binding[:request],
        "response" => binding[:response],
        "secret_headers" => binding[:secret_headers],
        "side_effect" => t["side_effect"],
        "group" => t["group"] || defaults["group"],       # Phase 7/D4/F5 (Step C):
        "tags" => (Array(defaults["tags"]) | Array(t["tags"])) # inherited default; tags unioned
      }.compact
    end

    private

    # Envelope adapter (D3): extracts the INTERFACE (name/description/parameters) from
    # any standard form. name/description fall back to the tool's top level when the
    # envelope does not carry them.
    def extract_interface(t)
      fn = t["function"]
      if fn.is_a?(Hash)                                   # OpenAI/Anthropic function tool
        { name: fn["name"] || t["name"], description: fn["description"] || t["description"],
          parameters: fn["parameters"] }
      elsif t.key?("inputSchema")                         # MCP tool
        { name: t["name"], description: t["description"], parameters: t["inputSchema"] }
      else                                               # raw: parameters is JSON Schema
        { name: t["name"], description: t["description"], parameters: t["parameters"] }
      end
    end

    # Builds the binding (request/response/secret_headers) inheriting defaults, with the
    # tool winning. Resolves endpoint→url, secret (only in secret headers) and env.
    def build_binding(t, secrets, env)
      method = (t["method"] || defaults["method"] || "GET").to_s.upcase
      headers = merge_maps(defaults["headers"], t["headers"])
      query = merge_maps(defaults["query"], t["query"])
      body = t.key?("body") ? t["body"] : defaults["body"]
      secret_headers = (Array(defaults["secret_headers"]) | Array(t["secret_headers"])).map(&:to_s)
      response = t["response"] || defaults["response"] || { "extract" => "body_raw" }

      url = resolve_url(t, env)
      headers = resolve_headers(headers, secret_headers, secrets, env)
      query = query.transform_values { |v| resolve_env(v, env) }
      body = body.nil? ? nil : resolve_env(body, env)
      guard_no_stray_secrets!(url: url, headers: headers, secret_headers: secret_headers, query: query, body: body)

      { request: { "method" => method, "url" => url, "headers" => headers,
                   "query" => query, "body" => body }.compact,
        response: response, secret_headers: secret_headers }
    end

    # explicit tool url OR base_url + path_template({endpoint}). The `endpoint` is
    # DATA (never inferred from the name — R6): it resolves name↔slug remaps. `{endpoint}`
    # is a manifest substitution (single key), distinct from the turn's `{{param}}`.
    def resolve_url(t, env)
      if self.class.presence(t["url"])
        return resolve_env(t["url"], env)
      end

      base = self.class.presence(defaults["base_url"]) ||
             (raise Harness::ValidationError, "tool '#{t['name']}' has no url and manifest has no defaults.base_url")
      path = self.class.presence(defaults["path_template"]) ||
             (raise Harness::ValidationError, "tool '#{t['name']}' has no url and manifest has no defaults.path_template")
      endpoint = self.class.presence(t["endpoint"]) ||
                 (raise Harness::ValidationError, "tool '#{t['name']}' has no 'endpoint' (never inferred from the name — R6)")

      resolve_env(base.to_s + path.to_s.gsub("{endpoint}", endpoint.to_s), env)
    end

    # Resolves headers: a SECRET header (name in secret_headers) MUST contain a
    # {{secret.*}} reference (never literal — R3; a prefix like "Bearer " is ok) and
    # resolves secret+env; the rest resolve only {{env.*}}.
    def resolve_headers(headers, secret_headers, secrets, env)
      headers.each_with_object({}) do |(name, value), acc|
        acc[name] =
          if secret_headers.include?(name)
            resolve_secret_header(name, value, secrets, env)
          else
            resolve_env(value, env)
          end
      end
    end

    def resolve_secret_header(name, value, secrets, env)
      unless value.to_s.match?(/\{\{\s*#{SECRET_PREFIX}/)
        raise Harness::ValidationError,
              "secret_header '#{name}' must reference {{secret.<name>}} (never a literal — R3)"
      end

      substitute(value, secrets: secrets, env: env)
    end

    # Substitutes {{env.X}} with the deployment value; leaves the other placeholders
    # ({{param}}/{{ctx.*}}/{{secret.*}}) INTACT. Used on NON-secret fields — a
    # remaining {{secret.*}} is blocked by #guard_no_stray_secrets! (it would leak).
    def resolve_env(template, env)
      substitute(template, secrets: nil, env: env)
    end

    # Ingestion interpolator: always resolves {{env.X}}; resolves {{secret.X}} only
    # when `secrets` was passed (secret fields). TURN placeholders
    # ({{param}}/{{ctx.*}}) stay INTACT. Missing secret/env -> ValidationError.
    def substitute(template, secrets:, env:)
      template.to_s.gsub(Harness::ToolDefinition::PLACEHOLDER_RE) do
        ref = Regexp.last_match(1)
        if secrets && ref.start_with?(SECRET_PREFIX)
          fetch!(secrets, ref.delete_prefix(SECRET_PREFIX), "secret")
        elsif ref.start_with?(ENV_PREFIX)
          fetch!(env, ref.delete_prefix(ENV_PREFIX), "env")
        else
          Regexp.last_match(0) # preserves {{param}}/{{ctx.*}} (and {{secret.*}} outside a secret header)
        end
      end
    end

    def fetch!(resolver, key, kind)
      val = resolver[key]
      raise Harness::ValidationError, "#{kind} '#{key}' not configured in the deployment" if blank?(val)

      val.to_s
    end

    # A secret outside a secret-header would leak (it is not masked): reject {{secret.*}}
    # in url/query/body/non-secret header after env resolution.
    def guard_no_stray_secrets!(url:, headers:, secret_headers:, query:, body:)
      non_secret = headers.reject { |name, _| secret_headers.include?(name) }.values
      strings = [url, *non_secret, *query.values, body].compact
      stray = strings.flat_map { |s| s.to_s.scan(Harness::ToolDefinition::PLACEHOLDER_RE).flatten }
                     .select { |r| r.start_with?(SECRET_PREFIX) }.uniq
      return if stray.empty?

      raise Harness::ValidationError,
            "{{secret.*}} is only allowed in secret_headers (would leak without masking): #{stray.join(', ')}"
    end

    def merge_maps(base, override)
      (self.class.stringify(base || {})).merge(self.class.stringify(override || {}))
    end

    def blank?(v) = v.nil? || v.to_s.empty?

    # Deep string keys (the wire may arrive symbolized; the nested JSON Schema
    # must stay string-keyed — same as ToolDefinition's canonicalization).
    def self.stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end

    def self.presence(str) = Harness::Coercion.presence(str)
  end
end
