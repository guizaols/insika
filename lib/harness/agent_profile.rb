# frozen_string_literal: true

module Harness
  # Único ponto de política por agente.
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  #
  # EXCEÇÃO deliberada: `capabilities` NÃO segue a regra do
  # `nil = todas`. nil/ausente = NENHUMA capability (opt-in explícito — expor
  # toda capability registrada por engano acoplaria o agente a plugins que ele
  # não pediu). NÃO "corrija" para ficar consistente com tools_allow.
  AgentProfile = Data.define(
    :id, :model, :provider,
    :base_prompt, :prompt_files,
    :tools_allow, :tools_deny,
    :skills,
    :context_providers,               # allowlist de providers
    :workflows_allow,                 # aplicado pela WorkflowAllowlist
    :policies,                        # nomes no Policy Registry
    :prompt_refs,                     # nomes do Prompt Catalog
    :limits,                          # timeouts/orçamentos
    :approvals_required,              # tools que exigem aprovação (ApprovalRequired)
    :capabilities,                    # intenções que o agente pode acionar.
    #                                   nil = NENHUMA (opt-in, ver acima).
    :tools_deferred,                  # tools searchable-not-wired (Tool Search).
    #                                   nil = nenhuma deferred (tudo eager — paridade);
    #                                   [names] ⊆ allowed_tools, expostas via tool_search.
    :memory                           # memória cross-session.
    #                                   nil/false = OFF (paridade: provider []; tool `remember`
    #                                   não cabeada); true = ON. Mesmo opt-in de capabilities.
  )

  # Classe reaberta (não bloco do Data.define): constante atribuída dentro
  # do bloco vazaria para o escopo léxico (Harness::DEFAULT_LIMITS).
  class AgentProfile
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_turns: 25, max_tool_calls: 50,
      approval_timeout: 3_600 # teto da espera por aprovação humana (~1h)
    }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, tools_deferred: nil, memory: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities, tools_deferred: tools_deferred, memory: memory
      )
    end

    # opt-in de tool optional = estar na allow do agente.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
