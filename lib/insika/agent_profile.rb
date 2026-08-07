# frozen_string_literal: true

require_relative "coercion"

module Insika
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
    :subagents,                       # allowlist of child agent ids this agent MAY spawn
    #                                   (RFC-0010, item 21). CAPACITY field — NEVER inherits;
    #                                   opt-in like `capabilities`: nil/absent = NONE (do NOT
    #                                   "fix" to nil = all). Present => the `spawn_subagent`
    #                                   system tool is wired (ChatBuilder), gated by this set.
    :tools_deferred,                  # searchable-not-wired tools (Tool Search).
    #                                   nil = no deferred (all eager — parity);
    #                                   [names] ⊆ allowed_tools, exposed via tool_search.
    :memory,                          # cross-session memory.
    #                                   nil/false = OFF (parity: provider []; the `remember`
    #                                   tool not wired); true = ON. Same opt-in as capabilities.
    :prompt_caching,                  # Anthropic prompt caching (§11 R3): nil/false = OFF
    #                                   (parity); true = ON. Same opt-in as `memory`. When ON
    #                                   AND the resolved provider is Anthropic, ChatBuilder sets
    #                                   ONE cache breakpoint at the end of the system block
    #                                   (caches tools+system by the tools->system->messages
    #                                   prefix order; immune to history eviction). PRE-AUDIT:
    #                                   the system prompt MUST be byte-stable between turns —
    #                                   a context provider injecting volatile content into
    #                                   :system turns every turn into a paid cache WRITE with
    #                                   no read hit. Enable only for stable-system agents.
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
    :sandbox,                         # confined-execution config (item 35, §4.6):
    #                                   { provider: "local"|"docker", root:, timeout:, ...+provider
    #                                   keys }. Declarative provider selection (config-over-code) —
    #                                   consumed by Insika::Sandbox.build. {} = absent (a
    #                                   deployment builds a `local` sandbox by default). It is
    #                                   CONFIG, never a policy — it does not decide security by
    #                                   itself; the FS boundary + approvals do.
    :refinement,                      # self-improvement config (RFC-0013 §3.8):
    #                                   { mode: "report"|"propose"|"auto_apply", window: {…},
    #                                   files: [allowlist], proposers: [refs], budget: {tokens:},
    #                                   auto_apply_max_edits:, max_findings:, … }. nil/absent =
    #                                   REPORT-ONLY (phase A writes nothing to the agent, so
    #                                   reading your own traces needs no opt-in); `propose`
    #                                   and above must be enabled explicitly. It is CONFIG,
    #                                   never a policy — the write allowlist it carries is
    #                                   enforced by the applier, not by this field.
    :capabilities_declared,           # FACTS ABOUT THIS DEPLOYMENT that are not tools
    #                                   (RFC-0014 §3.5): %w[promotions human_handoff
    #                                   b2b_pricing]. An eval case declares what it
    #                                   `requires` and is SKIPPED — never failed — where
    #                                   the deployment lacks it, which is what makes one
    #                                   corpus usable across stores. A flat list the
    #                                   OPERATOR writes: inferring "this store has
    #                                   promotions" from data is how a suite starts lying.
    #                                   nil/[] = declares nothing.
    #                                   NOT `capabilities` above — that one is the
    #                                   capability-resolution intents the agent may
    #                                   trigger, a runtime allowlist. This one decides
    #                                   nothing at runtime and is read only by the evals.
    :edge_stream,                     # WHICH INTERNAL CHANNELS MAY CROSS TO THE CUSTOMER:
    #                                   { "thinking" => bool, "intermediate" => bool }.
    #                                   {} / absent = NEITHER, which is the safe default and
    #                                   the reason the engine holds them back at all: the
    #                                   answer is `:content`, and a turn's other text (the
    #                                   provider's reasoning, the model narrating its tool
    #                                   loop) is for the Studio and the trace. A product that
    #                                   WANTS to show reasoning — a chat UI with a "thinking"
    #                                   panel — opts in per agent, and each channel then gets
    #                                   its OWN frame type at `/v1/responses`, never the
    #                                   answer's. Turning it on for a channel where the
    #                                   consumer concatenates every delta into one message
    #                                   (WhatsApp) puts the deliberation in front of a
    #                                   customer; that is the operator's call to make, not a
    #                                   default to inherit.
    :metadata                         # free-form agent metadata, stable per agent
    #                                   (from the pack `agent.config.json`). Home of the `store_id`
    #                                   that becomes turn context (ctx.store_id, Phase 6/D2).
    #                                   It is NOT a policy — never decides security. {} = absent.
  )

  # Reopened class (not a Data.define block): a constant assigned inside
  # the block would leak into the lexical scope (Insika::DEFAULT_LIMITS).
  class AgentProfile
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_tool_calls: 50,
      approval_timeout: 3_600, # cap on the wait for human approval (~1h)
      # Item 30: parallel tool calls. ONE number is both the switch and the cap
      # (nil/0/1 = serial, the default; N > 1 = at most N tool calls in flight).
      # It sits next to tool_timeout/max_tool_calls because it is the third bound
      # on tool execution. Read through TurnState#tool_concurrency, which also
      # applies the approval gate (D3).
      tool_concurrency: 1
    }.freeze

    # `model` is OPTIONAL as of v2 (§10): an agent without one resolves the
    # platform `default_model` (Settings) at turn start via the ModelResolver.
    def self.build(id:, model: nil, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], tools_allow_groups: nil, skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, subagents: nil, tools_deferred: nil, memory: nil,
                   prompt_caching: nil,
                   params: {}, model_policy: nil, guardrails: nil, sandbox: nil,
                   refinement: nil, capabilities_declared: nil, edge_stream: nil, metadata: {})
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), tools_allow_groups: tools_allow_groups, skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities,
        # opt-in like capabilities: nil => NONE. Array-normalize a present value so
        # readers get a clean [] and the ChatBuilder gate (present? => wire) is stable.
        subagents: subagents.nil? ? nil : Array(subagents).map(&:to_s),
        tools_deferred: tools_deferred, memory: memory,
        prompt_caching: prompt_caching,
        # The free-form hashes arrive with symbol keys (internal build) OR string
        # keys (StoredProfileSource JSON round-trip). Normalize to string keys ONCE
        # here — the single front door every profile passes through — so no reader
        # downstream has to defend against both (store_id, model_policy, Studio forms).
        params: Coercion.deep_stringify(params || {}),
        model_policy: Coercion.deep_stringify(model_policy),
        guardrails: Coercion.deep_stringify(guardrails),
        sandbox: Coercion.deep_stringify(sandbox),
        refinement: Coercion.deep_stringify(refinement),
        # Flat [String] — the evals compare it against a case's `requires`, and a
        # symbol/string mix there would be a silent miss.
        capabilities_declared: Array(capabilities_declared).map(&:to_s),
        edge_stream: Coercion.deep_stringify(edge_stream || {}),
        metadata: Coercion.deep_stringify(metadata || {})
      )
    end

    # opt-in for an optional tool = being in the agent's allow list.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end

    # store_id of the turn context (ctx.store_id): lives in `metadata` (stable
    # per store, comes from the pack). `build` string-keys metadata, so a plain
    # string lookup is enough. nil = absent (the data-tool emits an empty header).
    # It is NOT achei-specific: `store_id` is a field of the turn-context contract
    # (§5), generic per project.
    def store_id = (metadata || {})["store_id"]

    # May this channel (:thinking / :intermediate) cross to the customer? Tolerant
    # of the string values a form or a pack round-trip produces ("1"/"true"), and
    # of anything else being absent: the safe reading is the default one.
    def stream_public?(channel)
      v = (edge_stream || {})[channel.to_s]
      [true, "true", "1", "yes", "on"].include?(v)
    end
  end
end
