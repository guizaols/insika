# frozen_string_literal: true

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  AgentProfile = Data.define(
    :id, :model, :provider,           # Fase 0
    :base_prompt, :prompt_files,      # Fase 0
    :tools_allow, :tools_deny,        # Fase 0
    :skills,                          # Fase 0
    :context_providers,               # NOVO — allowlist de providers (RFC-0005 §4.1)
    :workflows_allow,                 # NOVO — aplicado pela WorkflowAllowlist (doc 05 §2)
    :policies,                        # NOVO — nomes no Policy Registry (estágio 3)
    :prompt_refs,                     # NOVO — nomes do Prompt Catalog (doc 04 §2)
    :limits,                          # NOVO — timeouts/orçamentos (D4/D8)
    :approvals_required               # P2 — tools que exigem aprovação (ApprovalRequired)
  )

  # Classe reaberta (não bloco do Data.define): constante atribuída dentro
  # do bloco vazaria para o escopo léxico (Harness::DEFAULT_LIMITS).
  class AgentProfile
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_turns: 25, max_tool_calls: 50
    }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required
      )
    end

    # opt-in de tool optional = estar na allow do agente (Fase 0, inalterado).
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
