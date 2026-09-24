# frozen_string_literal: true

require "json_schemer"

module Insika
  # Checks a tool call's ARGUMENTS against the tool's JSON Schema, at call time.
  # `violation` returns nil (fine) or ONE message describing what is wrong —
  # the same idiom as EgressGuard, and consumed the same way: DataDefinedTool turns
  # it into `{ error: … }` for the model, so a malformed call is a correctable
  # answer instead of a request that goes out shaped wrong.
  #
  # Why this exists: the schema declares the contract, but nothing used to hold the
  # model to it. A call carrying `["arroz"]` where the schema says
  # `[{query, filters}]` was interpolated into the body as-is, the backend answered
  # 200, and the wrong results came back with no error anywhere. Validating here
  # closes that loop *and* names the fix in the message the model reads next.
  #
  # JSONSchemer enforces declared constraints, including explicit null types and
  # additionalProperties. External references are disabled.
  #
  # NEVER coerces. The value the model sent is what reaches the request — the guard
  # only decides whether the call may proceed, so turning it on cannot change the
  # bytes of a call that was already correct.
  module SchemaGuard
    # A scalar the schema calls a number/integer/boolean may arrive as its string
    # form ("2", "true") — providers do that, it is lossless, and rejecting it would
    # break working tools for no gain. Structure (object/array) is NEVER lenient.
    NUMERIC_RE = /\A-?\d+(?:\.\d+)?\z/
    INTEGER_RE = /\A-?\d+\z/
    BOOLEAN_STRINGS = %w[true false].freeze
    MAX_REPORTED = 5

    module_function

    # schema: canonical JSON Schema (ToolDefinition#parameters). args: the model's
    # kwargs (symbol keys). -> nil | String.
    def violation(schema, args)
      return nil unless schema.is_a?(Hash)

      values = Insika::Coercion.deep_stringify(args || {})
      missing = missing_top_level(schema, values)
      return "missing required parameter(s): #{missing.join(', ')}" unless missing.empty?

      validator = JSONSchemer.schema(schema, ref_resolver: ->(uri) {
        raise Insika::ValidationError, "external schema reference is not allowed: #{uri}"
      })
      problems = validator.validate(validation_value(values, schema)).lazy.flat_map { |error| messages(error) }
                          .take(MAX_REPORTED).to_a
      return nil if problems.empty?

      "invalid arguments: #{problems.first(MAX_REPORTED).join('; ')}"
    end

    # Top-level `required` uses PRESENCE (an empty string is missing), because these
    # values feed `{{placeholder}}` interpolation — an empty one produces a silently
    # broken URL/body. Nested `required` uses JSON Schema semantics (key present),
    # where "" can be a legitimate value.
    def missing_top_level(schema, values)
      Array(schema["required"]).map(&:to_s).reject { |n| Insika::Coercion.present?(values[n]) }
    end

    # Normalize only a validation copy; request interpolation still gets the
    # original arguments. Legacy scalar leniency applies to direct properties/items.
    def validation_value(value, schema)
      return value unless schema.is_a?(Hash)

      case value
      when Hash
        value.to_h { |name, child| [name, validation_value(child, schema.fetch("properties", {})[name])] }
      when Array
        value.map { |child| validation_value(child, schema["items"]) }
      when nil then nil
      else
        case schema["type"]
        when "string" then value.to_s
        when "integer" then INTEGER_RE.match?(value.to_s) ? value.to_i : value
        when "number"
          value.is_a?(String) && NUMERIC_RE.match?(value) ? BigDecimal(value) : value
        when "boolean" then BOOLEAN_STRINGS.include?(value.to_s) ? value.to_s == "true" : value
        else value
        end
      end
    end

    def messages(error)
      path = error["data_pointer"].split("/").drop(1).map { |part| part.gsub("~1", "/").gsub("~0", "~") }
                  .map { |part| /\A\d+\z/.match?(part) ? "[#{part}]" : ".#{part}" }.join.sub(/\A\./, "")
      value, schema, type = error.values_at("data", "schema", "type")
      if type == "required"
        return error.fetch("details").fetch("missing_keys").map { |name| "#{path}.#{name}: missing (required)" }
      end

      message = case type
                when "object" then "expected an object, got #{kind(value)}"
                when "array" then "expected a list, got #{kind(value)}"
                when "string", "number", "integer", "boolean", "null" then "expected #{type}, got #{kind(value)}"
                when "enum" then "#{value.to_s.inspect} is not one of #{schema['enum'].map(&:to_s).join('/')}"
                when "minItems" then "needs at least #{schema['minItems']} item(s), got #{value.length}"
                when "maxItems" then "accepts at most #{schema['maxItems']} item(s), got #{value.length}"
                else error["error"]
                end
      ["#{path}: #{message}"]
    end

    # Walks a dotted path on a plain object: nil when a segment
    # is absent or the intermediate is not a Hash. Shared by the evidence output
    # check and the Processor's extraction.
    def dig(obj, path)
      path.to_s.split(".").reduce(obj) do |cur, seg|
        return nil unless cur.is_a?(Hash) && cur.key?(seg)

        cur[seg]
      end
    end

    # The evidence RESULT contract: {items: [{id, line}]} .
    # -> nil | String. Same idiom as `violation`: nil = fine, one message = what
    # is wrong. A malformed evidence result is a correctable TOOL answer — the
    # envelope returns it to the model as `{error:}`, exactly like a malformed
    # call is today. A raw body that is NOT an object (a bare JSON array from a
    # search, a string, nil) is a violation — never a silent `{items: []}` that
    # the model reads as "no products".
    def violation_output(spec, raw)
      return nil if spec.nil?
      return "evidence: result must be an object" unless raw.is_a?(Hash)

      items = dig(raw, spec.items_path)
      return "evidence: items is missing" if items.nil?
      return "evidence: items must be a list" unless items.is_a?(Array)

      # The FIELDS the spec named, not the words "id" and "line": a store that calls
      # them `product_id` and `line` is describable, and a guard that only knows the
      # defaults would turn every one of its answers into an error the model reads as
      # "the catalogue is down".
      id_field = spec.id_field
      line_field = spec.line_field
      items.each_with_index do |item, i|
        ok = item.is_a?(Hash) &&
             Coercion.present?(item[id_field] || item[id_field.to_sym]) &&
             (item[line_field] || item[line_field.to_sym]).is_a?(String)
        return "evidence: items[#{i}] must be {#{id_field}, #{line_field}}" unless ok
      end
      nil
    end

    # Name the shape the way a model reads it, not the way Ruby does.
    def kind(value)
      case value
      when Hash then "an object"
      when Array then "a list"
      when String then "a string"
      when Numeric then "a number"
      when true, false then "a boolean"
      when nil then "nothing"
      else value.class.name.downcase
      end
    end
  end
end
