# frozen_string_literal: true

module Harness
  # Registry de workflows. Um workflow é um callable Ruby com assinatura
  # `#call(input, context:, tools:)` que orquestra RubyLLM Agents/Workflows POR
  # DENTRO (RubyLLM First): `context:` é o ContextPackage, `tools:` são
  # instâncias já filtradas pela Resolution. Execução = um turno lógico;
  # checkpoint ao final. Nada é validado no registro (o callable pode vir por
  # bloco factory). Consumido pelo handler TriggerWorkflow.
  class WorkflowRegistry < Registry
  end
end
