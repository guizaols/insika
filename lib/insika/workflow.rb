# frozen_string_literal: true

require "json_schemer"

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
  # ToolDefinition already speaks) is accepted and validated by JSONSchemer.
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

    # JSON Schema validation with the same result contract as dry-schema.
    # References may resolve within the supplied document, never over the network.
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
        @validator = JSONSchemer.schema(@json_schema, ref_resolver: ->(uri) {
          raise Insika::ValidationError, "external schema reference is not allowed: #{uri}"
        })
      end

      def call(value)
        errors = {}
        @validator.validate(Insika::Coercion.deep_stringify(value)).each do |error|
          path = error["data_pointer"].split("/").drop(1).map { |part| part.gsub("~1", "/").gsub("~0", "~") }.join(".")
          if error["type"] == "required"
            error.fetch("details").fetch("missing_keys").each do |name|
              (errors[join(path, name)] ||= []) << "is required"
            end
          else
            message = case error["type"]
                      when "object", "array", "string", "integer", "number", "boolean", "null"
                        "must be #{error['type']}, got #{ruby_type(error['data'])}"
                      when "enum" then "must be one of #{error['schema']['enum'].inspect}"
                      else error["error"]
                      end
            (errors[path.empty? ? "(root)" : path] ||= []) << message
          end
        end
        Result.new(errors: errors.freeze)
      end

      private

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
    end
  end
end
