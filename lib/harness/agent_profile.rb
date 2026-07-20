# frozen_string_literal: true

module Harness
  # Single point of per-agent policy.
  # ONE allowlist semantics for tools, skills, providers and workflows
  # (nil = all [+ opt-in for optional tools]; [] = none for skills/allow;
  # [names] = the final set; deny always wins) — a single rule, tested once.
  #
  # Deliberate EXCEPTION: `capabilities` does NOT follow the
  # `nil = all` rule. nil/absent = NO capability (explicit opt-in — exposing
  # every registered capability by mistake would couple the agent to plugins it
  # didn't ask for). Do NOT "fix" it to be consistent with tools_allow.
  AgentProfile = Data.define(
    :id, :model, :provider,
    :base_prompt, :prompt_files,
    :tools_allow, :tools_deny,
    :tools_allow_groups,              # per-GROUP allowlist (Phase 7/D4/F5, Stage C):
    #                                   union with tools_allow; deny wins; both
    #                                   nil = all (parity). Expands to the group's
    #                                   tools in the ToolAllowlist policy.
    :skills,
    :context_providers,               # provider allowlist
    :workflows_allow,                 # applied by WorkflowAllowlist
    :policies,                        # names in the Policy Registry
    :prompt_refs,                     # names in the Prompt Catalog
    :limits,                          # timeouts/budgets
    :approvals_required,              # tools that require approval (ApprovalRequired)
    :capabilities,                    # intents the agent can trigger.
    #                                   nil = NONE (opt-in, see above).
    :tools_deferred,                  # searchable-not-wired tools (Tool Search).
    #                                   nil = no deferred (all eager — parity);
    #                                   [names] ⊆ allowed_tools, exposed via tool_search.
    :memory,                          # cross-session memory.
    #                                   nil/false = OFF (parity: provider []; the `remember`
    #                                   tool not wired); true = ON. Same opt-in as capabilities.
    :params,                          # LLM generation params (v2, §10): a Hash with
    #                                   temperature/max_tokens/thinking, applied to the chat at
    #                                   stage 5. {} = provider defaults (parity).
    :model_policy,                    # governance of WHICH models the agent may use (v2, §10):
    #                                   { "allow" => [refs] }. nil = NO fence (all models —
    #                                   parity). Enforced on the RESOLVED model (ModelResolver).
    :guardrails,                      # content-safety config (RFC-0009 §3.3): { input:, output:,
    #                                   moderator:, strictness: }. OPT-IN like capabilities —
    #                                   nil/absent = the conservative default (Safety::Config:
    #                                   deterministic on, moderator off). Parsed, never a policy.
    :metadata                         # free-form agent metadata, stable per agent
    #                                   (from the pack `agent.config.json`). Home of the `store_id`
    #                                   that becomes turn context (ctx.store_id, Phase 6/D2).
    #                                   It is NOT a policy — never decides security. {} = absent.
  )

  # Reopened class (not a Data.define block): a constant assigned inside
  # the block would leak into the lexical scope (Harness::DEFAULT_LIMITS).
  class AgentProfile
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_turns: 25, max_tool_calls: 50,
      approval_timeout: 3_600 # cap on the wait for human approval (~1h)
    }.freeze

    # `model` is OPTIONAL as of v2 (§10): an agent without one resolves the
    # platform `default_model` (Settings) at turn start via the ModelResolver.
    def self.build(id:, model: nil, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], tools_allow_groups: nil, skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, tools_deferred: nil, memory: nil,
                   params: {}, model_policy: nil, guardrails: nil, metadata: {})
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), tools_allow_groups: tools_allow_groups, skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities, tools_deferred: tools_deferred, memory: memory,
        params: params || {}, model_policy: model_policy, guardrails: guardrails,
        metadata: metadata || {}
      )
    end

    # opt-in for an optional tool = being in the agent's allow list.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end

    # store_id of the turn context (ctx.store_id): lives in `metadata` (stable
    # per store, comes from the pack). Tolerates a string|symbol key (the
    # StoredProfileSource JSON round-trip stringifies). nil = absent (the data-tool
    # emits an empty header). It is NOT achei-specific: `store_id` is a field of the
    # turn-context contract (§5), generic per project.
    def store_id
      (metadata || {})["store_id"] || (metadata || {})[:store_id]
    end
  end
end
