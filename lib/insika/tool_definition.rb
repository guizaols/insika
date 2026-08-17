# frozen_string_literal: true

require "uri"
require "json"

module Insika
  # Definition of a DATA-DEFINED TOOL (no Ruby code): name, description, parameters
  # and an HTTP call. Immutable value object, persisted by ToolStore and
  # materialized at runtime by Tools::DataDefinedTool (one class, N instances —
  # the same pattern as A2ARemote).,; parameters migrated to JSON
  # Schema in,.
  #
  # Persisted form (JSON-serializable Hash; ConfigStore stringifies the keys):
  #   { "name", "description",
  #     "parameters" => <JSON Schema>,        # { "type":"object", "properties":{…}, "required":[…] }
  #     "request"    => { "method","url","headers"=>{},"query"=>{},"body" },
  #     "response"   => { "extract","path" },
  #     "secret_headers" => [ "Authorization", ... ],
  #     "side_effect" => bool, "timeout" => int|nil,
  #     "group" => string|nil, "tags" => ["b2b",...] }  #//
  #
  # `parameters` is **JSON Schema** (the interlingua of OpenAI/Anthropic/MCP):
  # a nestable object, fed straight into RubyLLM's `params_schema` (provider-
  # agnostic). The **flat array** (`[{name,type,required}]`) is SUGAR for the simple
  # case: it is lifted to JSON Schema at build time. The sugar covers scalars and
  # `array:<scalar>` — it CANNOT express an array of objects, and says so instead of
  # guessing an item type. Ingestion validates a **safe subset** of JSON Schema (R1):
  # it rejects composition (oneOf/anyOf/allOf/$ref/…) that not every provider supports.
  #
  # Validation lives HERE (single source): `build`/`from_h` raise ValidationError
  # on malformed input. Name uniqueness and collision with a code tool are NOT
  # validated here (the value object does not know the registry) — that belongs to the
  # overlay. Secrets (credential headers) are the ToolStore's responsibility
  # (masks/reconciles); the definition itself is agnostic to masking.
  ToolDefinition = Data.define(
    :name, :description, :parameters, :request, :response,
    :secret_headers, :side_effect, :timeout, :group, :tags, :halt_when,
    :evidence                       # Insika::Evidence::Spec | nil (RFC-0029)
  )

  class ToolDefinition
    # Flat-sugar types: the SCALARS, plus `array:<scalar>` for a list. There is no bare
    # `array`: an array without an item type is an INCOMPLETE declaration, and the
    # engine refuses to guess one (see lift_flat_params).
    PARAM_TYPES = %w[string number integer boolean].freeze
    ARRAY_SUGAR_RE = /\Aarray:(string|number|integer|boolean)\z/
    ARRAY_SUGAR = PARAM_TYPES.map { |t| "array:#{t}" }.freeze
    HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
    IDEMPOTENT = %w[GET HEAD].freeze              # side_effect default = false
    EXTRACTS = %w[body_raw status json_path evidence_envelope].freeze
    NAME_RE = /\A[a-z][a-z0-9_]*\z/               # identifier for the model
    # A `.` in the placeholder enables the turn-context namespace `{{ctx.*}}`
    # separate from the model's `{{param}}`. Params follow NAME_RE (no
    # dot) -> a placeholder with a dot can only be a ctx ref.
    PLACEHOLDER_RE = /\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/
    # Turn-context namespace: values coming from the TURN (not the model),
    # resolved by DataDefinedTool. Closed allowlist (a typo becomes a validation
    # error, not a silently empty header).
    CTX_PREFIX = "ctx."
    CTX_FIELDS = %w[chat_id store_id agent_id tenant image_url].freeze

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

    # Builds + validates. Raises Insika::ValidationError. Accepts keyword args
    # (already-normalized symbol keys); use from_h for a raw Hash from the store/UI.
    # `parameters` accepts JSON Schema (Hash) OR the legacy flat array.
    def self.build(name:, description:, request:, parameters: nil, response: nil,
                   secret_headers: nil, side_effect: nil, timeout: nil, group: nil, tags: nil,
                   halt_when: nil, evidence: nil)
      name = name.to_s
      raise Insika::ValidationError, "name must match #{NAME_RE.inspect}" unless NAME_RE.match?(name)

      desc = description.to_s
      raise Insika::ValidationError, "description is required" if desc.empty?

      schema = normalize_params(parameters)
      req = normalize_request(request, top_level_names(schema))
      resp = normalize_response(response)
      if resp[:extract] == "evidence_envelope" && evidence.nil?
        raise Insika::ValidationError,
              "extract 'evidence_envelope' requires an 'evidence' declaration"
      end

      method = req[:method]
      effect = side_effect.nil? ? !IDEMPOTENT.include?(method) : (side_effect ? true : false)

      new(
        name: name, description: desc, parameters: schema, request: req, response: resp,
        secret_headers: Array(secret_headers).map(&:to_s), side_effect: effect,
        timeout: timeout.nil? ? nil : Integer(timeout),
        group: normalize_group(group), tags: normalize_tags(tags),
        halt_when: normalize_halt_when(halt_when),
        evidence: Insika::Evidence::Spec.parse(evidence)
      )
    end

    # Raw Hash (string or symbol keys, from the store/payload) -> ToolDefinition.
    def self.from_h(hash)
      h = deep_symbolize(hash)
      build(
        name: h[:name], description: h[:description], parameters: h[:parameters],
        request: h[:request] || {}, response: h[:response],
        secret_headers: h[:secret_headers], side_effect: h[:side_effect], timeout: h[:timeout],
        group: h[:group], tags: h[:tags], halt_when: h[:halt_when], evidence: h[:evidence]
      )
    end

    # Group: enablement label by DATA (not name convention),
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
        else raise Insika::ValidationError, "parameters must be JSON Schema (object) or a list of params"
        end

      schema = coerce_object_schema(schema)
      validate_schema!(schema, path: "parameters")
      validate_top_level_names!(schema)
      schema
    end
    private_class_method :normalize_params

    def self.empty_schema = { "type" => "object", "properties" => {}, "required" => [] }
    private_class_method :empty_schema

    # Flat sugar -> JSON Schema. Preserves validation (NAME_RE, duplicates,
    # PARAM_TYPES) and lifts `array:<scalar>` into proper `items`.
    #
    # A bare `array` is REFUSED. It used to lift to `items: {type:"string"}` — the
    # engine inventing half the contract. That default is invisible in the authoring
    # UI and silently correct-looking, so an array-of-OBJECTS param (the common shape:
    # `[{query, filters}]`) reached the provider declared as an array of STRINGS. The
    # model then obeyed the schema it was given, the backend answered 200, and the
    # results were garbage — a failure with no error anywhere. The JSON Schema path
    # already refuses `array` without `items` (validate_array!); the sugar now agrees.
    def self.lift_flat_params(list)
      seen = {}
      properties = {}
      required = []
      Array(list).each do |p|
        p = deep_symbolize(p)
        pname = p[:name].to_s
        raise Insika::ValidationError, "param name must match #{NAME_RE.inspect}" unless NAME_RE.match?(pname)
        raise Insika::ValidationError, "param '#{pname}' duplicated" if seen[pname]

        seen[pname] = true
        prop = flat_property(pname, (p[:type] || "string").to_s)
        prop["description"] = p[:description].to_s unless p[:description].to_s.empty?
        properties[pname] = prop
        required << pname if p.fetch(:required, true)
      end
      { "type" => "object", "properties" => properties, "required" => required }
    end
    private_class_method :lift_flat_params

    # One flat type -> the property schema. Raises on a bare `array` with the spelling
    # that fixes it, and on anything else unknown.
    def self.flat_property(pname, type)
      if (m = ARRAY_SUGAR_RE.match(type))
        { "type" => "array", "items" => { "type" => m[1] } }
      elsif PARAM_TYPES.include?(type)
        { "type" => type }
      elsif type == "array"
        raise Insika::ValidationError,
              "param '#{pname}': type 'array' needs an item type — use #{ARRAY_SUGAR.join('/')} " \
              "for a list of scalars, or declare the full JSON Schema for a list of objects"
      else
        raise Insika::ValidationError,
              "param '#{pname}': invalid type #{type.inspect} (#{(PARAM_TYPES + ARRAY_SUGAR).join('/')})"
      end
    end
    private_class_method :flat_property

    # The top level is always an object (the model always sends an args object). A Hash
    # without "type" but with "properties" is assumed to be an object; any other top-level
    # type is an error.
    def self.coerce_object_schema(schema)
      s = schema.dup
      s["type"] ||= "object" if s.key?("properties") || !s.key?("type")
      unless s["type"].to_s == "object"
        raise Insika::ValidationError, "parameters (top) must be type object, not #{s['type'].inspect}"
      end

      s["properties"] ||= {}
      s["required"] ||= []
      s
    end
    private_class_method :coerce_object_schema

    # Recursively validates the safe subset: type ∈ SCHEMA_TYPES, no composition/ref
    # constructs, an object recurses into its properties, an array requires items.
    def self.validate_schema!(node, path:)
      raise Insika::ValidationError, "#{path}: schema must be a JSON Schema object" unless node.is_a?(Hash)

      forbidden = node.keys.map(&:to_s) & FORBIDDEN_KEYWORDS
      unless forbidden.empty?
        raise Insika::ValidationError,
              "#{path}: unsupported construct (#{forbidden.join(', ')}); safe subset: #{SCHEMA_TYPES.join('/')}/enum"
      end

      type = node["type"].to_s
      raise Insika::ValidationError, "#{path}: 'type' is required" if type.empty?
      raise Insika::ValidationError, "#{path}: invalid type #{node['type'].inspect}" unless SCHEMA_TYPES.include?(type)

      case type
      when "object" then validate_object!(node, path)
      when "array" then validate_array!(node, path)
      end

      validate_enum!(node, path)
    end
    private_class_method :validate_schema!

    def self.validate_object!(node, path)
      props = node["properties"] || {}
      raise Insika::ValidationError, "#{path}: 'properties' must be an object" unless props.is_a?(Hash)

      props.each { |pname, pschema| validate_schema!(pschema, path: "#{path}.#{pname}") }

      required = node["required"] || []
      raise Insika::ValidationError, "#{path}: 'required' must be a list" unless required.is_a?(Array)

      unknown = required.map(&:to_s) - props.keys.map(&:to_s)
      raise Insika::ValidationError, "#{path}: required cites nonexistent property: #{unknown.join(', ')}" unless unknown.empty?
    end
    private_class_method :validate_object!

    def self.validate_array!(node, path)
      items = node["items"]
      raise Insika::ValidationError, "#{path}: array requires 'items'" if items.nil?

      validate_schema!(items, path: "#{path}[]")
    end
    private_class_method :validate_array!

    def self.validate_enum!(node, path)
      return unless node.key?("enum")

      enum = node["enum"]
      raise Insika::ValidationError, "#{path}: 'enum' must be a non-empty list" unless enum.is_a?(Array) && !enum.empty?
    end
    private_class_method :validate_enum!

    # TOP-LEVEL property names are both model args AND {{placeholder}} targets ->
    # they require NAME_RE (no dot, lowercase). Nested properties may be free-form.
    def self.validate_top_level_names!(schema)
      (schema["properties"] || {}).each_key do |pname|
        raise Insika::ValidationError, "top-level param '#{pname}' must match #{NAME_RE.inspect}" unless NAME_RE.match?(pname.to_s)
      end
    end
    private_class_method :validate_top_level_names!

    def self.top_level_names(schema) = (schema["properties"] || {}).keys.map(&:to_s)
    private_class_method :top_level_names

    # ---- request/response validation/normalization (class-private) ------------

    def self.normalize_request(request, param_names)
      r = deep_symbolize(request)
      method = (r[:method] || "GET").to_s.upcase
      raise Insika::ValidationError, "invalid method #{method.inspect}" unless HTTP_METHODS.include?(method)

      url = r[:url].to_s
      raise Insika::ValidationError, "url is required" if url.empty?

      # The URL is a TEMPLATE: {{x}} is not a valid URI character. Validate against a
      # probe with the placeholders swapped for a safe token.
      probe = url.gsub(PLACEHOLDER_RE, "x")
      uri = begin
        URI.parse(probe)
      rescue URI::InvalidURIError
        raise Insika::ValidationError, "invalid url"
      end
      raise Insika::ValidationError, "url must be http/https" unless %w[http https].include?(uri.scheme)

      headers = stringify_values(r[:headers])
      query = stringify_values(r[:query])
      body = r[:body].nil? ? nil : r[:body].to_s

      check_placeholders!([url, *headers.values, *query.values, body].compact, param_names)

      { method: method, url: url, headers: headers, query: query, body: body }
    end
    private_class_method :normalize_request

    # HALT CONDITION (optional): when the tool's RESPONSE says the turn is already
    # answered, the model must not speak again. The classic case is a backend that
    # performs the side effect AND sends its own confirmation to the customer: with
    # the model free to comment, the person gets the message twice.
    #
    #   "halt_when" => { "json_path" => "tool_result.status", "equals" => ["SUBSCRIBED"] }
    #
    # By RESULT, not by tool: the same call that halts on SUBSCRIBED must let the
    # model explain a SUBSCRIPTION_FAILED. Evaluated against the parsed response
    # body (independent of `response.extract`, which shapes what the MODEL sees) —
    # a non-JSON body simply never matches. `equals` is compared as strings: JSON
    # gives no type guarantee across backends and a status is a label, not a number.
    # -> { json_path:, equals: [String] } | nil
    def self.normalize_halt_when(halt_when)
      return nil if halt_when.nil?

      h = deep_symbolize(halt_when)
      path = h[:json_path].to_s
      raise Insika::ValidationError, "halt_when requires json_path" if path.empty?

      values = Array(h[:equals]).map(&:to_s)
      raise Insika::ValidationError, "halt_when requires a non-empty equals list" if values.empty?

      { json_path: path, equals: values, say: normalize_halt_say(h[:say]) }.compact
    end
    private_class_method :normalize_halt_when

    # `say` is EITHER a literal or a path, never both — two answers to "what does the
    # customer get" is a configuration nobody can read. Refused at load rather than
    # resolved by precedence: a silently ignored half would publish the wrong one.
    def self.normalize_halt_say(say)
      return nil if say.nil?

      s = deep_symbolize(say)
      text = s[:text].nil? ? nil : s[:text].to_s
      path = s[:json_path].nil? ? nil : s[:json_path].to_s
      given = [text, path].compact.reject(&:empty?)
      if given.length != 1
        raise Insika::ValidationError,
              "halt_when.say takes exactly one of 'text' or 'json_path' (got #{given.length})"
      end

      text.nil? || text.empty? ? { json_path: path } : { text: text }
    end
    private_class_method :normalize_halt_say

    def self.normalize_response(response)
      r = deep_symbolize(response || {})
      extract = (r[:extract] || "body_raw").to_s
      raise Insika::ValidationError, "invalid extract #{extract.inspect}" unless EXTRACTS.include?(extract)

      path = r[:path].nil? ? nil : r[:path].to_s
      raise Insika::ValidationError, "extract 'json_path' requires path" if extract == "json_path" && (path.nil? || path.empty?)

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
        raise Insika::ValidationError,
              "unknown turn context: #{unknown_ctx.join(', ')} " \
              "(available: #{CTX_FIELDS.map { |f| CTX_PREFIX + f }.join(', ')})"
      end

      unknown = params - param_names
      raise Insika::ValidationError, "placeholder(s) without a parameter: #{unknown.join(', ')}" unless unknown.empty?
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
    def self.deep_stringify(obj) = Insika::Coercion.deep_stringify(obj)
    private_class_method :deep_stringify

    # ---- instance -------------------------------------------------------------

    # String-keyed Hash for persistence (ConfigStore stringifies again, but we
    # normalize here so the record is stable across backends).
    def to_h
      h = {
        "name" => name, "description" => description,
        "parameters" => parameters,
        "request" => request.transform_keys(&:to_s),
        "response" => response.transform_keys(&:to_s),
        "secret_headers" => secret_headers,
        "side_effect" => side_effect, "timeout" => timeout,
        "group" => group, "tags" => tags,
        "halt_when" => halt_when&.transform_keys(&:to_s)
      }
      # present only when declared — a tool without evidence is byte-identical
      # to today (no declaration, no envelope processing).
      h["evidence"] = evidence.to_h if evidence
      h
    end

    # -> true when this response ENDS the turn (no further model call). `body` is the
    # raw response body; a parse failure or a missing path means "does not halt" —
    # never end a turn on a guess.
    def halt?(body)
      return false if halt_when.nil?

      parsed = JSON.parse(body.to_s)
      value = dig_path(parsed, halt_when[:json_path])
      return false if value == PATH_MISS

      halt_when[:equals].include?(value.to_s)
    rescue JSON::ParserError
      false
    end

    # WHAT THE CUSTOMER GETS WHEN THE MODEL SAID NOTHING FIRST (`halt_when.say`).
    #
    # A halt is worth the model's lead-in ("vou te conectar agora") and nothing
    # after — but the model does not always write one, and then the turn published
    # an EMPTY answer. Measured on a real store: two escalation turns in a row
    # delivered silence, where the same agent without the halt at least said "o time
    # de suporte já está cuidando do seu caso".
    #
    # The value cannot be guessed. `json_path` + `equals` cannot supply it either:
    # the matched value is by definition one of the `equals` tokens, so publishing
    # it would ship "SUBSCRIBED" to a person as often as it ships a sentence. So the
    # operator names it, in one of two shapes:
    #
    #   "say" => { "json_path" => "tool_result" }   # the sentence the backend returned
    #   "say" => { "text" => "CALL_SUPPORT" }       # a literal the CHANNEL resolves
    #
    # The literal form is the one that replaces the usual workaround — forcing the
    # prompt to emit a control token and parsing it downstream. The token then comes
    # from the tool's own contract, deterministically, instead of depending on the
    # model complying with an instruction.
    #
    # -> String | nil. nil means "publish nothing", which is the pre-existing
    # behaviour and stays the default for every tool that declares no `say`.
    def halt_say(body)
      say = halt_when && halt_when[:say]
      return nil if say.nil?
      return Coercion.presence(say[:text]) if say[:text]

      parsed = JSON.parse(body.to_s)
      value = dig_path(parsed, say[:json_path])
      # Only a String is publishable: a hash or a number reaching a customer as the
      # answer is never what someone meant.
      value.is_a?(String) ? Coercion.presence(value) : nil
    rescue JSON::ParserError
      nil
    end

    # HOW `say` REACHES THE EXECUTOR. RubyLLM's `Tool::Halt` carries one value, and
    # that value is the tool's payload (the trace records it, and the model never
    # sees it — the halt ends the loop). So a halt that has something to publish
    # carries BOTH, under keys distinctive enough that a trace reader knows what
    # they are on sight. Unwrapped tools are untouched: no `say`, no wrapper.
    SAY_KEY = "__insika_halt_say"
    PAYLOAD_KEY = "__insika_halt_payload"

    def self.wrap_halt(payload, say) = { SAY_KEY => say, PAYLOAD_KEY => payload }

    # -> the text to publish, or nil when this halt carries none.
    def self.halt_say_of(content)
      content.is_a?(Hash) ? Coercion.presence(content[SAY_KEY]) : nil
    end

    # Walks a dotted path. Returns PATH_MISS (not nil) when a segment is absent, so a
    # key whose stored value IS nil stays distinguishable from a missing key.
    PATH_MISS = Object.new.freeze

    def dig_path(parsed, path)
      path.to_s.split(".").reduce(parsed) do |cur, seg|
        return PATH_MISS unless cur.is_a?(Hash) && cur.key?(seg)

        cur[seg]
      end
    end
    private :dig_path

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
