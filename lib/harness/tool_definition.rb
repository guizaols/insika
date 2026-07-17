# frozen_string_literal: true

require "uri"

module Harness
  # Definition of a DATA-DEFINED TOOL (no Ruby code): name, description, parameters
  # and an HTTP call. Immutable value object, persisted by ToolStore and
  # materialized at runtime by Tools::DataDefinedTool (one class, N instances —
  # the same pattern as A2ARemote). Phase 5, Step A; parameters migrated to JSON
  # Schema in Phase 7, Step A.
  #
  # Persisted form (JSON-serializable Hash; ConfigStore stringifies the keys):
  #   { "name", "description",
  #     "parameters" => <JSON Schema>,        # { "type":"object", "properties":{…}, "required":[…] }
  #     "request"    => { "method","url","headers"=>{},"query"=>{},"body" },
  #     "response"   => { "extract","path" },
  #     "secret_headers" => [ "Authorization", ... ],
  #     "side_effect" => bool, "timeout" => int|nil,
  #     "group" => string|nil, "tags" => [ "b2b", ... ] }  # Phase 7/D4/F5 (Step C)
  #
  # `parameters` is **JSON Schema** (the interlingua of OpenAI/Anthropic/MCP; Phase 7/D1):
  # a nestable object, fed straight into RubyLLM's `params_schema` (provider-
  # agnostic). The **legacy flat array** (`[{name,type,required}]`) is SUGAR: it is
  # automatically lifted to JSON Schema at build time (zero regression — R2). Ingestion
  # validates a **safe subset** of JSON Schema (R1): it rejects composition (oneOf/
  # anyOf/allOf/$ref/…) that not every provider supports.
  #
  # Validation lives HERE (single source): `build`/`from_h` raise ValidationError
  # on malformed input. Name uniqueness and collision with a code tool are NOT
  # validated here (the value object does not know the registry) — that belongs to the
  # overlay (Step B). Secrets (credential headers) are the ToolStore's responsibility
  # (masks/reconciles); the definition itself is agnostic to masking.
  ToolDefinition = Data.define(
    :name, :description, :parameters, :request, :response,
    :secret_headers, :side_effect, :timeout, :group, :tags
  )

  class ToolDefinition
    PARAM_TYPES = %w[string number boolean array].freeze   # legacy flat-sugar types
    HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
    IDEMPOTENT = %w[GET HEAD].freeze              # side_effect default = false
    EXTRACTS = %w[body_raw status json_path].freeze
    NAME_RE = /\A[a-z][a-z0-9_]*\z/               # identifier for the model
    # A `.` in the placeholder enables the turn-context namespace `{{ctx.*}}`
    # (Phase 6/D2), separate from the model's `{{param}}`. Params follow NAME_RE (no
    # dot) -> a placeholder with a dot can only be a ctx ref.
    PLACEHOLDER_RE = /\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/
    # Turn-context namespace: values coming from the TURN (not the model),
    # resolved by DataDefinedTool. Closed allowlist (a typo becomes a validation
    # error, not a silently empty header).
    CTX_PREFIX = "ctx."
    CTX_FIELDS = %w[chat_id store_id agent_id tenant].freeze

    # ---- safe subset of JSON Schema (R1) --------------------------------------
    # Types supported by EVERY provider (OpenAI/Anthropic/Gemini/DeepSeek/Bedrock).
    SCHEMA_TYPES = %w[object array string number integer boolean].freeze
    # Composition/ref constructs that are NOT universally supported -> a clear error
    # at ingestion time (instead of an opaque failure in the provider).
    FORBIDDEN_KEYWORDS = %w[
      oneOf anyOf allOf not $ref if then else
      patternProperties dependencies dependentSchemas
      propertyNames unevaluatedProperties $defs definitions
    ].freeze

    # Builds + validates. Raises Harness::ValidationError. Accepts keyword args
    # (already-normalized symbol keys); use from_h for a raw Hash from the store/UI.
    # `parameters` accepts JSON Schema (Hash) OR the legacy flat array.
    def self.build(name:, description:, request:, parameters: nil, response: nil,
                   secret_headers: nil, side_effect: nil, timeout: nil, group: nil, tags: nil)
      name = name.to_s
      raise Harness::ValidationError, "name deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(name)

      desc = description.to_s
      raise Harness::ValidationError, "description is required" if desc.empty?

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

    # Raw Hash (string or symbol keys, from the store/payload) -> ToolDefinition.
    def self.from_h(hash)
      h = deep_symbolize(hash)
      build(
        name: h[:name], description: h[:description], parameters: h[:parameters],
        request: h[:request] || {}, response: h[:response],
        secret_headers: h[:secret_headers], side_effect: h[:side_effect], timeout: h[:timeout],
        group: h[:group], tags: h[:tags]
      )
    end

    # Group (Phase 7/D4/F5): enablement label by DATA (not name convention),
    # target of AgentProfile's `tools_allow_groups`. Trimmed; empty/nil -> nil.
    def self.normalize_group(group)
      g = group.to_s.strip
      g.empty? ? nil : g
    end
    private_class_method :normalize_group

    # Free-form tags (metadata/discovery). List of non-empty, unique strings.
    def self.normalize_tags(tags)
      Array(tags).map { |t| t.to_s.strip }.reject(&:empty?).uniq
    end
    private_class_method :normalize_tags

    # ---- parameter validation/normalization (class-private) -------------------

    # Input (Hash=JSON Schema | Array=flat sugar | nil) -> canonical string-keyed
    # JSON Schema, validated against the safe subset.
    def self.normalize_params(params)
      schema =
        case params
        when nil then empty_schema
        when Array then lift_flat_params(params)
        when Hash then deep_stringify(params)
        else raise Harness::ValidationError, "parameters must be JSON Schema (object) or a list of params"
        end

      schema = coerce_object_schema(schema)
      validate_schema!(schema, path: "parameters")
      validate_top_level_names!(schema)
      schema
    end
    private_class_method :normalize_params

    def self.empty_schema = { "type" => "object", "properties" => {}, "required" => [] }
    private_class_method :empty_schema

    # Legacy flat sugar -> JSON Schema. Preserves Phase 5 validation (NAME_RE,
    # duplicates, PARAM_TYPES). A legacy `array` (without items) gets string items,
    # mirroring RubyLLM's default (zero regression).
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

    # The top level is always an object (the model always sends an args object). A Hash
    # without "type" but with "properties" is assumed to be an object; any other top-level
    # type is an error.
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

    # Recursively validates the safe subset: type ∈ SCHEMA_TYPES, no composition/ref
    # constructs, an object recurses into its properties, an array requires items.
    def self.validate_schema!(node, path:)
      raise Harness::ValidationError, "#{path}: schema must be a JSON Schema object" unless node.is_a?(Hash)

      forbidden = node.keys.map(&:to_s) & FORBIDDEN_KEYWORDS
      unless forbidden.empty?
        raise Harness::ValidationError,
              "#{path}: construção não suportada (#{forbidden.join(', ')}); subset seguro: #{SCHEMA_TYPES.join('/')}/enum"
      end

      type = node["type"].to_s
      raise Harness::ValidationError, "#{path}: 'type' is required" if type.empty?
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
      raise Harness::ValidationError, "#{path}: 'properties' must be an object" unless props.is_a?(Hash)

      props.each { |pname, pschema| validate_schema!(pschema, path: "#{path}.#{pname}") }

      required = node["required"] || []
      raise Harness::ValidationError, "#{path}: 'required' must be a list" unless required.is_a?(Array)

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
      raise Harness::ValidationError, "#{path}: 'enum' must be a non-empty list" unless enum.is_a?(Array) && !enum.empty?
    end
    private_class_method :validate_enum!

    # TOP-LEVEL property names are both model args AND {{placeholder}} targets ->
    # they require NAME_RE (no dot, lowercase). Nested properties may be free-form.
    def self.validate_top_level_names!(schema)
      (schema["properties"] || {}).each_key do |pname|
        raise Harness::ValidationError, "param de topo '#{pname}' deve casar #{NAME_RE.inspect}" unless NAME_RE.match?(pname.to_s)
      end
    end
    private_class_method :validate_top_level_names!

    def self.top_level_names(schema) = (schema["properties"] || {}).keys.map(&:to_s)
    private_class_method :top_level_names

    # ---- request/response validation/normalization (class-private) ------------

    def self.normalize_request(request, param_names)
      r = deep_symbolize(request)
      method = (r[:method] || "GET").to_s.upcase
      raise Harness::ValidationError, "invalid method #{method.inspect}" unless HTTP_METHODS.include?(method)

      url = r[:url].to_s
      raise Harness::ValidationError, "url é obrigatória" if url.empty?

      # The URL is a TEMPLATE: {{x}} is not a valid URI character. Validate against a
      # probe with the placeholders swapped for a safe token.
      probe = url.gsub(PLACEHOLDER_RE, "x")
      uri = begin
        URI.parse(probe)
      rescue URI::InvalidURIError
        raise Harness::ValidationError, "invalid url"
      end
      raise Harness::ValidationError, "url must be http/https" unless %w[http https].include?(uri.scheme)

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
      raise Harness::ValidationError, "invalid extract #{extract.inspect}" unless EXTRACTS.include?(extract)

      path = r[:path].nil? ? nil : r[:path].to_s
      raise Harness::ValidationError, "extract 'json_path' exige path" if extract == "json_path" && (path.nil? || path.empty?)

      { extract: extract, path: path }
    end
    private_class_method :normalize_response

    # Every {{x}} in the templates must reference a declared TOP-LEVEL parameter OR a
    # known turn-context field ({{ctx.chat_id}} etc.). The ctx refs are
    # NOT model parameters — they are resolved per-turn by the engine.
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
      raise Harness::ValidationError, "placeholder(s) without a parameter: #{unknown.join(', ')}" unless unknown.empty?
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

    # Canonical JSON-clean: keys AND symbols become strings (JSON has no symbol).
    def self.deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
    private_class_method :deep_stringify

    # ---- instance -------------------------------------------------------------

    # String-keyed Hash for persistence (ConfigStore stringifies again, but we
    # normalize here so the record is stable across backends).
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

    # Names of the required top-level parameters (DataDefinedTool validates presence
    # before the call). Derived from the JSON Schema's `required`.
    def required_params = Array(parameters["required"]).map(&:to_s)

    # FLAT view of the top-level properties (name/type/description/required) — for
    # RubyLLM's `#parameters` (discovery/tool_search) and the simple authoring UI.
    # The full nested schema goes through `params_schema` (DataDefinedTool). Symbol-
    # keyed for compat with callers that already consumed the flat params.
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
