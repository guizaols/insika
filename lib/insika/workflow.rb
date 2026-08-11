# frozen_string_literal: true

module Insika
  # Workflow surface (COMPETITIVE-ANALYSIS). A workflow is a Ruby
  # callable orchestrating RubyLLM Agents/Workflows FROM WITHIN (RubyLLM First);
  # its durable RUN is a Task (checkpointed, recoverable — stronger than Flue's
  # at-most-once run record). This module adds the EXPOSED surface the consumer
  # asked for, matching the honest Flue scope (not Temporal):
  #   · runId          — the run id (== task id; the Task IS the run record).
  #   · event stream   — :workflow_started / :workflow_completed on the task stream.
  #   · I/O by schema  — optional input_schema / output_schema validated at the edges.
  #
  # A schema is any dry-schema-compatible validator: `#call(value)` returning a
  # result that responds to `#success?` and `#errors` (dry-schema's own contract).
  # As a batteries-included default, a plain JSON Schema Hash (the interlingua the
  # ToolDefinition already speaks) is accepted and validated by the zero-dependency
  # Schema below — "config over convention": bring dry-schema for richer contracts,
  # or hand a JSON Schema for the common case.
  module Workflow
    # Bundles a registered workflow's callable factory with its metadata (schemas +
    # description). Built lazily by WorkflowRegistry#definition — it does NOT resolve
    # the factory (the Executor resolves inside the fiber; the contract forbids
    # instantiating outside it). Schema validation touches only the schemas.
    Definition = Data.define(:name, :description, :input_schema, :output_schema, :factory) do
      # Raises WorkflowSchemaError (< ValidationError) when the input does not
      # conform. No-op without an input_schema (parity). Called synchronously by
      # TriggerWorkflow -> a bad input is a 422 with no run created.
      def validate_input!(input) = enforce!(input_schema, input, :input)

      # Raises WorkflowSchemaError when the RETURN does not conform. No-op without an
      # output_schema. Called inside the fiber after the workflow returns -> a bad
      # output fails the run at the :workflow_schema stage.
      def validate_output!(output) = enforce!(output_schema, output, :output)

      # Resolves the factory (INSIDE the fiber) and invokes the orchestrator with the
      # canonical signature `#call(input, context:, tools:)`.
      def call(input, context:, tools:)
        factory.call.call(input, context: context, tools: tools)
      end

      # Discovery view (GET /v1/workflows): name + description + the I/O contract.
      # A JSON-Schema-backed schema exposes its schema Hash; a duck-typed validator
      # (dry-schema etc.) is opaque to introspection -> "opaque".
      def catalog_entry
        {
          "name" => name,
          "description" => description,
          "input_schema" => schema_view(input_schema),
          "output_schema" => schema_view(output_schema)
        }
      end

      private

      def enforce!(schema, value, phase)
        return if schema.nil?

        result = schema.call(value)
        return if result.success?

        raise Insika::WorkflowSchemaError.new(
          "workflow '#{name}' #{phase}", phase: phase, errors: normalize_errors(result.errors)
        )
      end

      # dry-schema returns a MessageSet (responds to #to_h); the built-in Schema
      # already returns a Hash.
      def normalize_errors(errors) = errors.respond_to?(:to_h) ? errors.to_h : errors

      def schema_view(schema)
        return nil if schema.nil?

        schema.respond_to?(:json_schema) ? schema.json_schema : "opaque"
      end
    end

    # Zero-dependency instance validator for a plain JSON Schema Hash, speaking the
    # same safe subset (object/array/string/number/integer/boolean + enum) the
    # ToolDefinition validates its parameters against. It implements the SAME
    # `#call(value) -> result{#success?, #errors}` contract as dry-schema, so the
    # Definition treats both uniformly. Not a full JSON Schema engine (no
    # composition/$ref — the subset the insika supports everywhere); permissive on
    # unknown keys (JSON Schema's additionalProperties default).
    class Schema
      # dry-schema-compatible result. `errors` is { "field.path" => ["message", …] }.
      Result = Data.define(:errors) do
        def success? = errors.empty?
      end

      # nil -> nil; a callable (dry-schema / proc) -> as-is; a JSON Schema Hash ->
      # wrapped. Idempotent for an existing Schema (it is callable).
      def self.coerce(schema)
        return nil if schema.nil?
        return schema if schema.respond_to?(:call)

        new(schema)
      end

      attr_reader :json_schema

      def initialize(json_schema)
        unless json_schema.is_a?(Hash)
          raise Insika::ValidationError, "workflow schema must be a JSON Schema object or a #call-able validator"
        end

        @json_schema = Insika::Coercion.deep_stringify(json_schema)
      end

      def call(value)
        Result.new(errors: collect(@json_schema, value, "").freeze)
      end

      private

      # -> { path => [messages] }. Empty = valid.
      def collect(schema, value, path)
        type = schema["type"].to_s
        return { key(path) => ["must be #{type}, got #{ruby_type(value)}"] } unless type.empty? || matches?(type, value)

        errors = {}
        case type
        when "object" then check_object(schema, value, path, errors)
        when "array"  then check_array(schema, value, path, errors)
        end
        check_enum(schema, value, path, errors)
        errors
      end

      def check_object(schema, value, path, errors)
        props = schema["properties"] || {}
        Array(schema["required"]).each do |name|
          errors[key(join(path, name))] = ["is required"] unless value.key?(name.to_s) || value.key?(name.to_sym)
        end
        props.each do |name, subschema|
          next unless value.key?(name.to_s) || value.key?(name.to_sym)

          sub = value[name.to_s] || value[name.to_sym]
          errors.merge!(collect(subschema || {}, sub, join(path, name)))
        end
      end

      def check_array(schema, value, path, errors)
        items = schema["items"]
        return if items.nil?

        value.each_with_index { |el, i| errors.merge!(collect(items, el, "#{join(path, i)}")) }
      end

      def check_enum(schema, value, path, errors)
        return unless schema.key?("enum")

        allowed = Array(schema["enum"])
        errors[key(path)] = ["must be one of #{allowed.inspect}"] unless allowed.include?(value)
      end

      def matches?(type, value)
        case type
        when "object"  then value.is_a?(Hash)
        when "array"   then value.is_a?(Array)
        when "string"  then value.is_a?(String)
        when "integer" then value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "number"  then value.is_a?(Numeric) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "boolean" then value == true || value == false
        else true # unknown type in the schema -> do not block (permissive)
        end
      end

      def ruby_type(value)
        case value
        when Hash then "object"
        when Array then "array"
        when String then "string"
        when Integer then "integer"
        when Numeric then "number"
        when true, false then "boolean"
        when nil then "null"
        else value.class.name.downcase
        end
      end

      def join(path, segment) = path.empty? ? segment.to_s : "#{path}.#{segment}"
      def key(path) = path.empty? ? "(root)" : path
    end
  end
end
