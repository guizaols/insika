# frozen_string_literal: true

module Harness
  # Registry de workflows (doc 06 §2). Um workflow é um callable Ruby
  # (RFC-0001 §5) com assinatura `#call(input, context:, tools:)` que orquestra
  # RubyLLM Agents/Workflows POR DENTRO (RubyLLM First): `context:` é o
  # ContextPackage, `tools:` são instâncias já filtradas pela Resolution
  # (doc 03 §4.1). Execução = um turno lógico; checkpoint ao final. Nada é
  # validado no registro (o callable pode vir por bloco factory). Consumido
  # pelo handler TriggerWorkflow (task 23).
  class WorkflowRegistry < Registry
  end
end
