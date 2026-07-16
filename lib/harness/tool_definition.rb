# frozen_string_literal: true

require "uri"

module Harness
  # Definição de uma TOOL POR DADOS (sem código Ruby): nome, descrição, parâmetros
  # e uma chamada HTTP. Value object imutável, persistido pelo ToolStore e
  # materializado em runtime por Tools::DataDefinedTool (uma classe, N instâncias —
  # o mesmo padrão do A2ARemote). Fase 5, Etapa A; parâmetros migrados p/ JSON
  # Schema na Fase 7, Etapa A.
  #
  # Forma persistida (Hash JSON-serializável; ConfigStore stringifica as chaves):
  #   { "name", "description",
  #     "parameters" => <JSON Schema>,        # { "type":"object", "properties":{…}, "required":[…] }
  #     "request"    => { "method","url","headers"=>{},"query"=>{},"body" },
  #     "response"   => { "extract","path" },
  #     "secret_headers" => [ "Authorization", ... ],
  #     "side_effect" => bool, "timeout" => int|nil,
  #     "group" => string|nil, "tags" => [ "b2b", ... ] }  # Fase 7/D4/F5 (Etapa C)
  #
  # `parameters` é **JSON Schema** (a interlíngua de OpenAI/Anthropic/MCP; Fase 7/D1):
  # objeto aninhável, alimentado direto no `params_schema` do RubyLLM (provider-
  # agnóstico). O **array plano legado** (`[{name,type,required}]`) é AÇÚCAR: sobe
  # automaticamente para JSON Schema no build (zero regressão — R2). A ingestão
  # valida um **subset seguro** de JSON Schema (R1): rejeita composição (oneOf/
  # anyOf/allOf/$ref/…) que nem todo provider suporta.
  #
  # A validação vive AQUI (fonte única): `build`/`from_h` levantam ValidationError
  # em entrada malformada. Unicidade de nome e colisão com tool de código NÃO são
  # validadas aqui (o value object não conhece a registry) — isso é do overlay
  # (Etapa B). Segredos (headers-credencial) são responsabilidade do ToolStore
  # (mascara/reconcilia); a definição em si é agnóstica a masking.
  ToolDefinition = Data.define(
    :name, :description, :parameters, :request, :response,
    :secret_headers, :side_effect, :timeout, :group, :tags
  )

  class ToolDefinition
    PARAM_TYPES = %w[string number boolean array].freeze   # tipos do açúcar plano legado
    HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
    IDEMPOTENT = %w[GET HEAD].freeze              # side_effect default = false
    EXTRACTS = %w[body_raw status json_path].freeze
    NAME_RE = /\A[a-z][a-z0-9_]*\z/               # identificador p/ o modelo
    # `.` no placeholder habilita o namespace de contexto de turno `{{ctx.*}}`
    # (Fase 6/D2), separado dos `{{param}}` do modelo. Params seguem NAME_RE (sem
    # ponto) -> um placeholder com ponto só pode ser um ctx ref.
    PLACEHOLDER_RE = /\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/
    # Namespace de contexto de turno: valores vindos do TURNO (não do modelo),
    # resolvidos pelo DataDefinedTool. Allowlist fechada (um typo vira erro de
    # validação, não header silenciosamente vazio).
    CTX_PREFIX = "ctx."
    CTX_FIELDS = %w[chat_id store_id agent_id tenant].freeze

    # ---- subset seguro de JSON Schema (R1) ------------------------------------
    # Tipos suportados por TODO provider (OpenAI/Anthropic/Gemini/DeepSeek/Bedrock).
    SCHEMA_TYPES = %w[object array string number integer boolean].freeze
    # Construções de composição/refs que NÃO são universalmente suportadas -> erro
    # claro na ingestão (em vez de falha opaca no provider).
    FORBIDDEN_KEYWORDS = %w[
      oneOf anyOf allOf not $ref if then else
      patternProperties dependencies dependentSchemas
      propertyNames unevaluatedProperties $defs definitions
    ].freeze

    # Constrói + valida. Levanta Harness::ValidationError. Aceita keyword args
    # (symbol keys já normalizados); use from_h para um Hash cru do store/UI.
    # `parameters` aceita JSON Schema (Hash) OU o array plano legado.
    def self.build(name:, description:, request:, parameters: nil, response: nil,
                   secret_headers: nil, side_effect: nil, timeout: nil, group: nil, tags: nil)
      name = name.to_s
      raise Harness::ValidationError, "name deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(name)

      desc = description.to_s
      raise Harness::ValidationError, "description é obrigatória" if desc.empty?

      schema = normalize_params(parameters)
      req = normalize_request(request, top_level_names(schema))
      resp = normalize_response(response)

      method = req[:method]
      effect = side_effect.nil? ? !IDEMPOTENT.include?(method) : (side_effect ? true : false)

      new(
        name: name, description: desc, parameters: schema, request: req, response: resp,
        secret_headers: Array(secret_headers).map(&:to_s), side_effect: effect,
        timeout: timeout.nil? ? nil : Integer(timeout),
        group: normalize_group(group), tags: normalize_tags(tags)
      )
    end

    # Hash cru (string ou symbol keys, vindo do store/payload) -> ToolDefinition.
    def self.from_h(hash)
      h = deep_symbolize(hash)
      build(
        name: h[:name], description: h[:description], parameters: h[:parameters],
        request: h[:request] || {}, response: h[:response],
        secret_headers: h[:secret_headers], side_effect: h[:side_effect], timeout: h[:timeout],
        group: h[:group], tags: h[:tags]
      )
    end

    # Grupo (Fase 7/D4/F5): rótulo de enablement por DADO (não convenção-de-nome),
    # alvo do `tools_allow_groups` do AgentProfile. Trimmed; vazio/nil -> nil.
    def self.normalize_group(group)
      g = group.to_s.strip
      g.empty? ? nil : g
    end
    private_class_method :normalize_group

    # Tags livres (metadados/descoberta). Lista de strings não-vazias, únicas.
    def self.normalize_tags(tags)
      Array(tags).map { |t| t.to_s.strip }.reject(&:empty?).uniq
    end
    private_class_method :normalize_tags

    # ---- validação/normalização de parâmetros (privadas de classe) ------------

    # Entrada (Hash=JSON Schema | Array=açúcar plano | nil) -> JSON Schema
    # string-keyed canônico, validado contra o subset seguro.
    def self.normalize_params(params)
      schema =
        case params
        when nil then empty_schema
        when Array then lift_flat_params(params)
        when Hash then deep_stringify(params)
        else raise Harness::ValidationError, "parameters deve ser JSON Schema (objeto) ou lista de params"
        end

      schema = coerce_object_schema(schema)
      validate_schema!(schema, path: "parameters")
      validate_top_level_names!(schema)
      schema
    end
    private_class_method :normalize_params

    def self.empty_schema = { "type" => "object", "properties" => {}, "required" => [] }
    private_class_method :empty_schema

    # Açúcar plano legado -> JSON Schema. Preserva a validação da Fase 5 (NAME_RE,
    # duplicados, PARAM_TYPES). `array` legado (sem items) ganha items string,
    # espelhando o default do RubyLLM (zero regressão).
    def self.lift_flat_params(list)
      seen = {}
      properties = {}
      required = []
      Array(list).each do |p|
        p = deep_symbolize(p)
        pname = p[:name].to_s
        raise Harness::ValidationError, "param name deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(pname)
        raise Harness::ValidationError, "param '#{pname}' duplicado" if seen[pname]

        seen[pname] = true
        type = (p[:type] || "string").to_s
        raise Harness::ValidationError, "param '#{pname}': type inválido #{type.inspect}" unless PARAM_TYPES.include?(type)

        prop = { "type" => type }
        prop["description"] = p[:description].to_s unless p[:description].to_s.empty?
        prop["items"] = { "type" => "string" } if type == "array"
        properties[pname] = prop
        required << pname if p.fetch(:required, true)
      end
      { "type" => "object", "properties" => properties, "required" => required }
    end
    private_class_method :lift_flat_params

    # Topo é sempre um objeto (o modelo sempre manda um objeto de args). Um Hash sem
    # "type" mas com "properties" é assumido objeto; qualquer outro type no topo é erro.
    def self.coerce_object_schema(schema)
      s = schema.dup
      s["type"] ||= "object" if s.key?("properties") || !s.key?("type")
      unless s["type"].to_s == "object"
        raise Harness::ValidationError, "parameters (topo) deve ser type object, não #{s['type'].inspect}"
      end

      s["properties"] ||= {}
      s["required"] ||= []
      s
    end
    private_class_method :coerce_object_schema

    # Valida recursivamente o subset seguro: type ∈ SCHEMA_TYPES, sem construções
    # de composição/ref, object recorre em properties, array exige items.
    def self.validate_schema!(node, path:)
      raise Harness::ValidationError, "#{path}: schema deve ser um objeto JSON Schema" unless node.is_a?(Hash)

      forbidden = node.keys.map(&:to_s) & FORBIDDEN_KEYWORDS
      unless forbidden.empty?
        raise Harness::ValidationError,
              "#{path}: construção não suportada (#{forbidden.join(', ')}); subset seguro: #{SCHEMA_TYPES.join('/')}/enum"
      end

      type = node["type"].to_s
      raise Harness::ValidationError, "#{path}: 'type' é obrigatório" if type.empty?
      raise Harness::ValidationError, "#{path}: type inválido #{node['type'].inspect}" unless SCHEMA_TYPES.include?(type)

      case type
      when "object" then validate_object!(node, path)
      when "array" then validate_array!(node, path)
      end

      validate_enum!(node, path)
    end
    private_class_method :validate_schema!

    def self.validate_object!(node, path)
      props = node["properties"] || {}
      raise Harness::ValidationError, "#{path}: 'properties' deve ser objeto" unless props.is_a?(Hash)

      props.each { |pname, pschema| validate_schema!(pschema, path: "#{path}.#{pname}") }

      required = node["required"] || []
      raise Harness::ValidationError, "#{path}: 'required' deve ser lista" unless required.is_a?(Array)

      unknown = required.map(&:to_s) - props.keys.map(&:to_s)
      raise Harness::ValidationError, "#{path}: required cita propriedade inexistente: #{unknown.join(', ')}" unless unknown.empty?
    end
    private_class_method :validate_object!

    def self.validate_array!(node, path)
      items = node["items"]
      raise Harness::ValidationError, "#{path}: array exige 'items'" if items.nil?

      validate_schema!(items, path: "#{path}[]")
    end
    private_class_method :validate_array!

    def self.validate_enum!(node, path)
      return unless node.key?("enum")

      enum = node["enum"]
      raise Harness::ValidationError, "#{path}: 'enum' deve ser uma lista não-vazia" unless enum.is_a?(Array) && !enum.empty?
    end
    private_class_method :validate_enum!

    # Nomes de propriedade de TOPO são args do modelo E alvos de {{placeholder}} ->
    # exigem NAME_RE (sem ponto, minúsculo). Propriedades aninhadas podem ser livres.
    def self.validate_top_level_names!(schema)
      (schema["properties"] || {}).each_key do |pname|
        raise Harness::ValidationError, "param de topo '#{pname}' deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(pname.to_s)
      end
    end
    private_class_method :validate_top_level_names!

    def self.top_level_names(schema) = (schema["properties"] || {}).keys.map(&:to_s)
    private_class_method :top_level_names

    # ---- validação/normalização de request/response (privadas de classe) ------

    def self.normalize_request(request, param_names)
      r = deep_symbolize(request)
      method = (r[:method] || "GET").to_s.upcase
      raise Harness::ValidationError, "method inválido #{method.inspect}" unless HTTP_METHODS.include?(method)

      url = r[:url].to_s
      raise Harness::ValidationError, "url é obrigatória" if url.empty?

      # URL é um TEMPLATE: {{x}} não é caractere de URI válido. Valida sobre uma
      # sonda com os placeholders trocados por um token seguro.
      probe = url.gsub(PLACEHOLDER_RE, "x")
      uri = begin
        URI.parse(probe)
      rescue URI::InvalidURIError
        raise Harness::ValidationError, "url inválida"
      end
      raise Harness::ValidationError, "url deve ser http/https" unless %w[http https].include?(uri.scheme)

      headers = stringify_values(r[:headers])
      query = stringify_values(r[:query])
      body = r[:body].nil? ? nil : r[:body].to_s

      check_placeholders!([url, *headers.values, *query.values, body].compact, param_names)

      { method: method, url: url, headers: headers, query: query, body: body }
    end
    private_class_method :normalize_request

    def self.normalize_response(response)
      r = deep_symbolize(response || {})
      extract = (r[:extract] || "body_raw").to_s
      raise Harness::ValidationError, "extract inválido #{extract.inspect}" unless EXTRACTS.include?(extract)

      path = r[:path].nil? ? nil : r[:path].to_s
      raise Harness::ValidationError, "extract 'json_path' exige path" if extract == "json_path" && (path.nil? || path.empty?)

      { extract: extract, path: path }
    end
    private_class_method :normalize_response

    # Todo {{x}} nos templates deve referenciar um parâmetro de TOPO declarado OU um
    # campo de contexto de turno conhecido ({{ctx.chat_id}} etc.). Os ctx refs
    # NÃO são parâmetros do modelo — são resolvidos por-turno pelo motor.
    def self.check_placeholders!(strings, param_names)
      used = strings.flat_map { |s| s.to_s.scan(PLACEHOLDER_RE).flatten }.uniq
      ctx_refs, params = used.partition { |u| u.start_with?(CTX_PREFIX) }

      unknown_ctx = ctx_refs.reject { |u| CTX_FIELDS.include?(u.delete_prefix(CTX_PREFIX)) }
      unless unknown_ctx.empty?
        raise Harness::ValidationError,
              "contexto de turno desconhecido: #{unknown_ctx.join(', ')} " \
              "(disponível: #{CTX_FIELDS.map { |f| CTX_PREFIX + f }.join(', ')})"
      end

      unknown = params - param_names
      raise Harness::ValidationError, "placeholder(s) sem parâmetro: #{unknown.join(', ')}" unless unknown.empty?
    end
    private_class_method :check_placeholders!

    def self.stringify_values(hash)
      (deep_symbolize(hash || {})).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
    end
    private_class_method :stringify_values

    def self.deep_symbolize(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = deep_symbolize(v) }
      when Array then obj.map { |v| deep_symbolize(v) }
      else obj
      end
    end
    private_class_method :deep_symbolize

    # Canônico JSON-clean: chaves E símbolos viram string (JSON não tem símbolo).
    def self.deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
    private_class_method :deep_stringify

    # ---- instância ------------------------------------------------------------

    # Hash string-keyed para persistência (ConfigStore stringifica de novo, mas
    # normalizamos aqui p/ o record ser estável entre backends).
    def to_h
      {
        "name" => name, "description" => description,
        "parameters" => parameters,
        "request" => request.transform_keys(&:to_s),
        "response" => response.transform_keys(&:to_s),
        "secret_headers" => secret_headers,
        "side_effect" => side_effect, "timeout" => timeout,
        "group" => group, "tags" => tags
      }
    end

    # Nome dos parâmetros de topo exigidos (o DataDefinedTool valida presença antes
    # da call). Deriva do `required` do JSON Schema.
    def required_params = Array(parameters["required"]).map(&:to_s)

    # Visão PLANA das propriedades de topo (nome/tipo/descrição/required) — para o
    # `#parameters` do RubyLLM (discovery/tool_search) e a UI de autoria simples.
    # O schema aninhado completo vai pelo `params_schema` (DataDefinedTool). Symbol-
    # keyed p/ compat com quem já consumia os params planos.
    def top_level_params
      props = parameters["properties"] || {}
      required = required_params
      props.map do |pname, pschema|
        pschema ||= {}
        { name: pname.to_s, type: (pschema["type"] || "string").to_s,
          description: pschema["description"].to_s, required: required.include?(pname.to_s) }
      end
    end
  end
end
