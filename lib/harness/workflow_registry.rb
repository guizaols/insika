# frozen_string_literal: true

module Harness
  # Workflow registry. A workflow is a Ruby callable with the signature
  # `#call(input, context:, tools:)` that orchestrates RubyLLM Agents/Workflows FROM
  # WITHIN (RubyLLM First): `context:` is the ContextPackage, `tools:` are
  # instances already filtered by the Resolution. Execution = one logical turn;
  # checkpoint at the end. Nothing is validated at registration (the callable may come
  # via a factory block). Consumed by the TriggerWorkflow handler.
  class WorkflowRegistry < Registry
  end
end
