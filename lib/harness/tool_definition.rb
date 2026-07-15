# frozen_string_literal: true

require "uri"

module Harness
  # Definição de uma TOOL POR DADOS (sem código Ruby): nome, descrição, parâmetros
  # e uma chamada HTTP. Value object imutável, persistido pelo ToolStore e
  # materializado em runtime por Tools::DataDefinedTool (uma classe, N instâncias —
  # o mesmo padrão do A2ARemote). Fase 5, Etapa A.
  #
  # Forma persistida (Hash JSON-serializável; ConfigStore stringifica as chaves):
  #   { "name", "description",
  #     "parameters" => [ { "name","type","description","required" }, ... ],
  #     "request"    => { "method","url","headers"=>{},"query"=>{},"body" },
  #     "response"   => { "extract","path" },
  #     "secret_headers" => [ "Authorization", ... ],
  #     "side_effect" => bool, "timeout" => int|nil }
  #
  # A validação vive AQUI (fonte única): `build`/`from_h` levantam ValidationError
  # em entrada malformada. Unicidade de nome e colisão com tool de código NÃO são
  # validadas aqui (o value object não conhece a registry) — isso é do overlay
  # (Etapa B). Segredos (headers-credencial) são responsabilidade do ToolStore
  # (mascara/reconcilia); a definição em si é agnóstica a masking.
  ToolDefinition = Data.define(
    :name, :description, :parameters, :request, :response,
    :secret_headers, :side_effect, :timeout
  )

  class ToolDefinition
    PARAM_TYPES = %w[string number boolean array].freeze
    HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
    IDEMPOTENT = %w[GET HEAD].freeze              # side_effect default = false
    EXTRACTS = %w[body_raw status json_path].freeze
    NAME_RE = /\A[a-z][a-z0-9_]*\z/               # identificador p/ o modelo
    PLACEHOLDER_RE = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

    # Constrói + valida. Levanta Harness::ValidationError. Aceita keyword args
    # (symbol keys já normalizados); use from_h para um Hash cru do store/UI.
    def self.build(name:, description:, request:, parameters: [], response: nil,
                   secret_headers: nil, side_effect: nil, timeout: nil)
      name = name.to_s
      raise Harness::ValidationError, "name deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(name)

      desc = description.to_s
      raise Harness::ValidationError, "description é obrigatória" if desc.empty?

      params = normalize_params(parameters)
      req = normalize_request(request, params)
      resp = normalize_response(response)

      method = req[:method]
      effect = side_effect.nil? ? !IDEMPOTENT.include?(method) : (side_effect ? true : false)

      new(
        name: name, description: desc, parameters: params, request: req, response: resp,
        secret_headers: Array(secret_headers).map(&:to_s), side_effect: effect,
        timeout: timeout.nil? ? nil : Integer(timeout)
      )
    end

    # Hash cru (string ou symbol keys, vindo do store/payload) -> ToolDefinition.
    def self.from_h(hash)
      h = deep_symbolize(hash)
      build(
        name: h[:name], description: h[:description], parameters: h[:parameters] || [],
        request: h[:request] || {}, response: h[:response],
        secret_headers: h[:secret_headers], side_effect: h[:side_effect], timeout: h[:timeout]
      )
    end

    # ---- validação/normalização (privadas de classe) --------------------------

    def self.normalize_params(list)
      seen = {}
      Array(list).map do |p|
        p = deep_symbolize(p)
        pname = p[:name].to_s
        raise Harness::ValidationError, "param name deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(pname)
        raise Harness::ValidationError, "param '#{pname}' duplicado" if seen[pname]

        seen[pname] = true
        type = (p[:type] || "string").to_s
        raise Harness::ValidationError, "param '#{pname}': type inválido #{type.inspect}" unless PARAM_TYPES.include?(type)

        { name: pname, type: type, description: p[:description].to_s,
          required: p.fetch(:required, true) ? true : false }
      end
    end
    private_class_method :normalize_params

    def self.normalize_request(request, params)
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

      param_names = params.map { |p| p[:name] }
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

    # Todo {{x}} nos templates deve referenciar um parâmetro declarado.
    def self.check_placeholders!(strings, param_names)
      used = strings.flat_map { |s| s.to_s.scan(PLACEHOLDER_RE).flatten }.uniq
      unknown = used - param_names
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

    # ---- instância ------------------------------------------------------------

    # Hash string-keyed para persistência (ConfigStore stringifica de novo, mas
    # normalizamos aqui p/ o record ser estável entre backends).
    def to_h
      {
        "name" => name, "description" => description,
        "parameters" => parameters.map { |p| p.transform_keys(&:to_s) },
        "request" => request.transform_keys(&:to_s),
        "response" => response.transform_keys(&:to_s),
        "secret_headers" => secret_headers,
        "side_effect" => side_effect, "timeout" => timeout
      }
    end

    # Nome dos parâmetros exigidos (o DataDefinedTool valida presença antes da call).
    def required_params = parameters.select { |p| p[:required] }.map { |p| p[:name] }
  end
end
