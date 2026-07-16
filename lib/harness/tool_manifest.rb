# frozen_string_literal: true

module Harness
  # Manifesto de tools (Fase 7, Etapa B): a forma em LOTE, em DADOS e em formato
  # PADRÃO de mercado (JSON Schema) das data-tools. Um `defaults` (binding comum:
  # base_url/path_template/method/headers/secret_headers/response) + uma lista de
  # `tools`. Cada tool é normalizada — herdando os defaults, aplicando o adapter
  # de envelope (OpenAI/MCP/cru) e resolvendo `endpoint`→url + `{{secret.*}}`/
  # `{{env.*}}` — numa Hash de ToolDefinition consumível pelo ToolStore.
  #
  # GENÉRICO (NF1): nada aqui cita consumer/openclaw — o manifesto É o contrato. Só
  # NORMALIZA/RESOLVE; a validação final (method/url/tipos, placeholders de modelo
  # `{{param}}`/turno `{{ctx.*}}`, subset seguro de JSON Schema) é da
  # ToolDefinition (fonte única). O upsert em lote + reload hot é do Command
  # :import_tools (que injeta os resolvedores de secret/env).
  #
  # Duas classes de placeholder por MOMENTO de resolução:
  #   - `{{param}}`/`{{ctx.*}}` : resolvidos NO TURNO (pelo DataDefinedTool) —
  #     ficam INTACTOS aqui; a ToolDefinition os valida.
  #   - `{{secret.*}}`/`{{env.*}}` : resolvidos NA INGESTÃO (aqui) — do deployment,
  #     nunca do manifesto (D6/R3). `{{env.*}}` é config não-secreta (qualquer
  #     template); `{{secret.*}}` é credencial e SÓ é permitido num header
  #     declarado em `secret_headers`, com valor === `{{secret.X}}` (nada literal,
  #     nada fora de header — senão o segredo vazaria sem masking).
  #
  # Envelope da interface (o que o modelo vê), por adapter (D3):
  #   - `parameters` (JSON Schema cru), OU
  #   - `{ "function": { name, description, parameters } }` (OpenAI/Anthropic), OU
  #   - `{ "inputSchema": {...} }` (MCP).
  ToolManifest = Data.define(:version, :defaults, :tools)

  # Reabre a classe (constantes num bloco de Data.define caem no escopo LÉXICO
  # errado — mesmo padrão da ToolDefinition irmã).
  class ToolManifest
    ENV_PREFIX = "env."
    SECRET_PREFIX = "secret."
    private_constant :ENV_PREFIX, :SECRET_PREFIX

    # Hash cru (string|symbol keys) -> ToolManifest. Valida só a ESTRUTURA de topo
    # (version/defaults/tools); o conteúdo de cada tool é validado na normalização
    # (per-tool, isolável pelo Command — R4). Levanta ValidationError.
    def self.from_h(hash)
      h = stringify(hash || {})
      version = h.fetch("version", 1)
      defaults = h.fetch("defaults", {}) || {}
      tools = h.fetch("tools", []) || []
      raise Harness::ValidationError, "manifesto: 'defaults' deve ser objeto" unless defaults.is_a?(Hash)
      raise Harness::ValidationError, "manifesto: 'tools' deve ser lista" unless tools.is_a?(Array)

      new(version: version, defaults: defaults, tools: tools)
    end

    # -> [ { ToolDefinition hash } ] com defaults herdados, envelopes normalizados,
    # endpoint→url resolvido e secret/env resolvidos. Levanta na PRIMEIRA tool
    # malformada — use #definition_for por-tool p/ isolar falha parcial (R4).
    def tool_definitions(secrets:, env:)
      tools.map { |t| definition_for(t, secrets: secrets, env: env) }
    end

    # Normaliza UMA tool crua -> Hash de ToolDefinition. Levanta ValidationError
    # (envelope inválido, endpoint/url ausente, secret/env não configurado, R3).
    def definition_for(raw_tool, secrets:, env:)
      t = self.class.stringify(raw_tool || {})
      raise Harness::ValidationError, "tool deve ser objeto" unless t.is_a?(Hash)

      interface = extract_interface(t)
      binding = build_binding(t, secrets, env)

      {
        "name" => interface[:name], "description" => interface[:description],
        "parameters" => interface[:parameters],
        "request" => binding[:request],
        "response" => binding[:response],
        "secret_headers" => binding[:secret_headers],
        "side_effect" => t["side_effect"],
        "group" => t["group"] || defaults["group"],       # Fase 7/D4/F5 (Etapa C):
        "tags" => (Array(defaults["tags"]) | Array(t["tags"])) # default herdado; tags em união
      }.compact
    end

    private

    # Adapter de envelope (D3): extrai a INTERFACE (name/description/parameters) de
    # qualquer forma padrão. name/description caem no topo da tool quando o
    # envelope não os traz.
    def extract_interface(t)
      fn = t["function"]
      if fn.is_a?(Hash)                                   # OpenAI/Anthropic function tool
        { name: fn["name"] || t["name"], description: fn["description"] || t["description"],
          parameters: fn["parameters"] }
      elsif t.key?("inputSchema")                         # MCP tool
        { name: t["name"], description: t["description"], parameters: t["inputSchema"] }
      else                                               # cru: parameters é JSON Schema
        { name: t["name"], description: t["description"], parameters: t["parameters"] }
      end
    end

    # Monta o binding (request/response/secret_headers) herdando defaults, com a
    # tool vencendo. Resolve endpoint→url, secret (só em secret headers) e env.
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

    # url explícita da tool OU base_url + path_template({endpoint}). O `endpoint` é
    # DADO (nunca inferido do name — R6): resolve os remaps nome↔slug. `{endpoint}`
    # é substituição de manifesto (chave única), distinta do `{{param}}` de turno.
    def resolve_url(t, env)
      if self.class.presence(t["url"])
        return resolve_env(t["url"], env)
      end

      base = self.class.presence(defaults["base_url"]) ||
             (raise Harness::ValidationError, "tool '#{t['name']}' sem url e manifesto sem defaults.base_url")
      path = self.class.presence(defaults["path_template"]) ||
             (raise Harness::ValidationError, "tool '#{t['name']}' sem url e manifesto sem defaults.path_template")
      endpoint = self.class.presence(t["endpoint"]) ||
                 (raise Harness::ValidationError, "tool '#{t['name']}' sem 'endpoint' (nunca inferido do name — R6)")

      resolve_env(base.to_s + path.to_s.gsub("{endpoint}", endpoint.to_s), env)
    end

    # Resolve headers: um SECRET header (nome em secret_headers) DEVE conter uma
    # referência {{secret.*}} (nunca literal — R3; prefixo tipo "Bearer " é ok) e
    # resolve secret+env; os demais resolvem só {{env.*}}.
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
              "secret_header '#{name}' deve referenciar {{secret.<nome>}} (nunca literal — R3)"
      end

      substitute(value, secrets: secrets, env: env)
    end

    # Substitui {{env.X}} pelo valor do deployment; deixa os demais placeholders
    # ({{param}}/{{ctx.*}}/{{secret.*}}) INTACTOS. Uso em campos NÃO-secretos — o
    # {{secret.*}} remanescente é barrado por #guard_no_stray_secrets! (vazaria).
    def resolve_env(template, env)
      substitute(template, secrets: nil, env: env)
    end

    # Interpolador de ingestão: resolve {{env.X}} sempre; resolve {{secret.X}} só
    # quando `secrets` foi passado (campos secretos). Placeholders de TURNO
    # ({{param}}/{{ctx.*}}) ficam INTACTOS. Secret/env ausente -> ValidationError.
    def substitute(template, secrets:, env:)
      template.to_s.gsub(Harness::ToolDefinition::PLACEHOLDER_RE) do
        ref = Regexp.last_match(1)
        if secrets && ref.start_with?(SECRET_PREFIX)
          fetch!(secrets, ref.delete_prefix(SECRET_PREFIX), "secret")
        elsif ref.start_with?(ENV_PREFIX)
          fetch!(env, ref.delete_prefix(ENV_PREFIX), "env")
        else
          Regexp.last_match(0) # preserva {{param}}/{{ctx.*}} (e {{secret.*}} fora de header secreto)
        end
      end
    end

    def fetch!(resolver, key, kind)
      val = resolver[key]
      raise Harness::ValidationError, "#{kind} '#{key}' não configurado no deployment" if blank?(val)

      val.to_s
    end

    # Segredo fora de secret-header vazaria (não é mascarado): recusa {{secret.*}}
    # em url/query/body/header não-secreto após a resolução de env.
    def guard_no_stray_secrets!(url:, headers:, secret_headers:, query:, body:)
      non_secret = headers.reject { |name, _| secret_headers.include?(name) }.values
      strings = [url, *non_secret, *query.values, body].compact
      stray = strings.flat_map { |s| s.to_s.scan(Harness::ToolDefinition::PLACEHOLDER_RE).flatten }
                     .select { |r| r.start_with?(SECRET_PREFIX) }.uniq
      return if stray.empty?

      raise Harness::ValidationError,
            "{{secret.*}} só é permitido em secret_headers (vazaria sem masking): #{stray.join(', ')}"
    end

    def merge_maps(base, override)
      (self.class.stringify(base || {})).merge(self.class.stringify(override || {}))
    end

    def blank?(v) = v.nil? || v.to_s.empty?

    # Chaves string em profundidade (o wire pode chegar simbolizado; o JSON Schema
    # aninhado deve ficar string-keyed — igual à canonização da ToolDefinition).
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
