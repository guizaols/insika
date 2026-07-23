# frozen_string_literal: true

module Insika
  # Workflow registry. A workflow is a Ruby callable with the signature
  # `#call(input, context:, tools:)` that orchestrates RubyLLM Agents/Workflows FROM
  # WITHIN (RubyLLM First): `context:` is the ContextPackage, `tools:` are
  # instances already filtered by the Resolution. Execution = one logical turn;
  # checkpoint at the end. Nothing is validated at registration (the callable may come
  # via a factory block). Consumed by the TriggerWorkflow handler.
  #
  # Item 22 / §4.4 — the EXPOSED surface: a registration may carry `input_schema:` /
  # `output_schema:` (a JSON Schema Hash or any dry-schema-compatible validator) and a
  # `description:` in its metadata. `definition` bundles them with the factory into a
  # Workflow::Definition (schemas resolved, factory left lazy); `catalog` is the
  # discovery view (GET /v1/workflows).
  class WorkflowRegistry < Registry
    # -> Workflow::Definition (does NOT resolve the factory — the Executor resolves
    # inside the fiber). Raises NotFoundError for an unregistered name.
    def definition(name)
      e = entry(name)
      Insika::Workflow::Definition.new(
        name: e.name,
        description: e.metadata[:description],
        input_schema: Insika::Workflow::Schema.coerce(e.metadata[:input_schema]),
        output_schema: Insika::Workflow::Schema.coerce(e.metadata[:output_schema]),
        factory: e.factory
      )
    end

    # Discovery: [{ "name", "description", "input_schema", "output_schema" }, …].
    def catalog = entries.map { |e| definition(e.name).catalog_entry }
  end
end
