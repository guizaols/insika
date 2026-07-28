# frozen_string_literal: true

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
  # Scope: the safe subset ToolDefinition already validates
  # (object/array/string/number/integer/boolean + enum + minItems/maxItems). Only what
  # the schema DECLARES is checked; undeclared keys pass (providers add nothing, and
  # `additionalProperties` is a tool author's business, not ours).
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

      problems = []
      (schema["properties"] || {}).each do |pname, pschema|
        value = values[pname.to_s]
        next if value.nil?

        problems.concat(check(value, pschema, pname.to_s))
        break if problems.length >= MAX_REPORTED
      end
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

    # -> [String] problems found at/below `path`.
    def check(value, schema, path)
      return [] unless schema.is_a?(Hash)

      case schema["type"].to_s
      when "object" then check_object(value, schema, path)
      when "array" then check_array(value, schema, path)
      else check_scalar(value, schema, path)
      end
    end

    def check_object(value, schema, path)
      return ["#{path}: expected an object, got #{kind(value)}"] unless value.is_a?(Hash)

      props = schema["properties"] || {}
      missing = Array(schema["required"]).map(&:to_s).reject { |k| value.key?(k) }
      problems = missing.map { |k| "#{path}.#{k}: missing (required)" }

      props.each do |pname, pschema|
        child = value[pname.to_s]
        next if child.nil?

        problems.concat(check(child, pschema, "#{path}.#{pname}"))
      end
      problems
    end

    def check_array(value, schema, path)
      return ["#{path}: expected a list, got #{kind(value)}"] unless value.is_a?(Array)

      problems = size_problems(value, schema, path)
      problems + value.each_with_index.flat_map { |item, i| check(item, schema["items"], "#{path}[#{i}]") }
    end

    # minItems/maxItems are the only cardinality the authors actually write (a search
    # that takes "1 or more pairs"), and an empty list is exactly the call that reads as
    # success and returns nothing.
    def size_problems(value, schema, path)
      min = schema["minItems"]
      max = schema["maxItems"]
      problems = []
      problems << "#{path}: needs at least #{min} item(s), got #{value.length}" if min.is_a?(Numeric) && value.length < min
      problems << "#{path}: accepts at most #{max} item(s), got #{value.length}" if max.is_a?(Numeric) && value.length > max
      problems
    end

    def check_scalar(value, schema, path)
      type = schema["type"].to_s
      return ["#{path}: expected #{type}, got #{kind(value)}"] unless scalar_ok?(value, type)

      enum = schema["enum"]
      return [] unless enum.is_a?(Array) && !enum.empty?
      return [] if enum.map(&:to_s).include?(value.to_s)

      ["#{path}: #{value.to_s.inspect} is not one of #{enum.map(&:to_s).join('/')}"]
    end

    def scalar_ok?(value, type)
      return false if value.is_a?(Hash) || value.is_a?(Array)

      case type
      when "string" then true                       # any scalar stringifies losslessly
      when "number" then value.is_a?(Numeric) || NUMERIC_RE.match?(value.to_s)
      when "integer" then value.is_a?(Integer) || INTEGER_RE.match?(value.to_s)
      when "boolean" then [true, false].include?(value) || BOOLEAN_STRINGS.include?(value.to_s)
      else true                                     # unknown type: not ours to police
      end
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
