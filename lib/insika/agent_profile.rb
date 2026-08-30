# frozen_string_literal: true

require_relative "coercion"
require_relative "tool_definition"

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
    :tools_allow_groups,              # per-GROUP allowlist:
    #                                   union with tools_allow; deny wins; both
    #                                   nil = all (parity). Expands to the group's
    #                                   tools in the ToolAllowlist policy.
    :skills,
    :skills_eager,                    # progressive disclosure OFF, wholly or in part:
    #                                   nil/false = level 1 + load_skill (parity); true = every
    #                                   allowed skill; [names] = exactly these. An eager skill's
    #                                   BODY enters the prompt each turn, it leaves the
    #                                   <available_skills> catalog and load_skill refuses it.
    #                                   Removes the activation DECISION (no miss rate) at the
    #                                   cost of the bodies' tokens — measure them against
    #                                   context_budget before turning it on. Same opt-in as
    #                                   `memory`. It lives HERE and not in the SKILL.md
    #                                   frontmatter because skills are shared between agents:
    #                                   a per-skill flag forced one decision onto every
    #                                   allowlist holding the skill. NOT `Allowlist`
    #                                   semantics — nil means NONE here (SkillCatalog#eager_for).
    :context_providers,               # provider allowlist
    :workflows_allow,                 # applied by WorkflowAllowlist
    :policies,                        # names in the Policy Registry
    :prompt_refs,                     # names in the Prompt Catalog
    :limits,                          # timeouts/budgets
    :approvals_required,              # tools that require approval (ApprovalRequired)
    :capabilities,                    # intents the agent can trigger.
    #                                   nil = NONE (opt-in, see above).
    :subagents,                       # allowlist of child agent ids this agent MAY spawn
    # CAPACITY field — NEVER inherits;
    #                                   opt-in like `capabilities`: nil/absent = NONE (do NOT
    #                                   "fix" to nil = all). Present => the `spawn_subagent`
    #                                   system tool is wired (ChatBuilder), gated by this set.
    :tools_deferred,                  # searchable-not-wired tools (Tool Search).
    #                                   nil = no deferred (all eager — parity);
    #                                   [names] ⊆ allowed_tools, exposed via tool_search.
    :memory,                          # cross-session memory.
    #                                   nil/false = OFF (parity: provider []; the `remember`
    #                                   tool not wired); true = ON. Same opt-in as capabilities.
    :prompt_caching,                  # Anthropic prompt caching (R3): nil/false = OFF
    #                                   (parity); true = ON. Same opt-in as `memory`. When ON
    #                                   AND the resolved provider is Anthropic, ChatBuilder sets
    #                                   ONE cache breakpoint at the end of the system block
    #                                   (caches tools+system by the tools->system->messages
    #                                   prefix order; immune to history eviction). PRE-AUDIT:
    #                                   the system prompt MUST be byte-stable between turns —
    #                                   a context provider injecting volatile content into
    #                                   :system turns every turn into a paid cache WRITE with
    #                                   no read hit. Enable only for stable-system agents.
    :tool_persistence,                # the engine's "Tool discipline" block in the system
    #                                   prompt (retry weak/empty tool results with a different
    #                                   approach before giving up). THE ONE OPT-OUT FIELD:
    #                                   nil/true = ON (the proven default — every reference
    #                                   harness ships it), false = OFF. Deliberately inverted
    #                                   from the opt-in fields above: the exception here is
    #                                   turning the good behavior OFF, so that is what an
    #                                   operator declares. Read by Context::Providers::Prompt.
    :tool_output_compression,          # MECHANICAL tool-result dedupe in the replayed
    #                                   history (A3/C3): nil/false = OFF (parity); true = ON.
    #                                   Same opt-in as `memory`. When ON, the history the
    #                                   Session provider seeds replaces byte-identical repeated
    #                                   tool results with a compact back-reference (first
    #                                   occurrence stays full) — no LLM involved. CHANGES WHAT
    #                                   THE MODEL SEES: an older full result is only the first
    #                                   occurrence; a model that wants an older detail re-calls
    #                                   the tool. Cheap half of compaction for bloated histories.
    :params,                          # LLM generation params: a Hash with
    #                                   temperature/max_tokens/thinking, applied to the chat at
    #                                   stage 5. {} = provider defaults (parity).
    :budget,                          # spend caps per (tenant, agent) over
    #                                   CALENDAR windows (WS2): { "daily" => int,
    #                                   "monthly" => int, "soft" => bool, "alert_at" => 0.8 }.
    #                                   HARD is the default: absent/"soft": false, a turn
    #                                   arriving at/over the cap fails with Insika::BudgetExceeded
    #                                   and the envelope quotes `budget_exceeded` + retry_after.
    #                                   "soft": true crosses the cap and still runs
    #                                   (one budget_warning event per window + a note in the
    #                                   context).
    #                                   Tokens count the billed spend (input+output+cached+
    #                                   cache_creation). nil/absent = no budget (parity).
    :reliability,                     # the provider-interaction reliability policy (WS3):
    #                                   { "retries" => 3, "backoff" => "exponential",
    #                                   "fallback" => ["gpt-4o-mini", ...],
    #                                   "circuit_breaker" => { "after" => 10, "within" => 60,
    #                                   "cooldown" => 300 }, "timeout" => 30 }. Data, never
    #                                   DSL: retries + exponential backoff on :retryable /
    #                                   :rate_limited_* failures (never :fatal), mid-turn
    #                                   rotation across the fallback chain (profile's first,
    #                                   then the platform's resolved fallbacks), and a circuit
    #                                   breaker per (tenant, provider/model) that fail-fasts
    #                                   with circuit_open + retry_after once the window count
    #                                   trips. nil/absent = the plain single attempt (parity).
    :alerts,                          # operator alert delivery (WS6): { "webhook" => url }.
    #                                   When present, the agent's budget_warning /
    #                                   breaker_open / delivery_failed events are POSTed to
    #                                   the URL as JSON (outbox + claim, at-most-once).
    #                                   nil/absent = no webhook (parity).
    :routes,                          # intent routing (WS4): { "route" => "description" or a
    #                                   Hash with description/delegate/stuck/message,
    #                                   "default" => route, "model" => cheap classifier }.
    #                                   When present, the message is classified BEFORE the
    #                                   ask with the cheap model; the route lands on the
    #                                   turn (state.route + :route_classified) and may
    #                                   delegate to an existing agent or end the turn :stuck
    #                                   (WS5). nil/absent = no routing (parity).
    :stuck_signal,                    # the agent may signal it cannot proceed (WS5):
    #                                   nil/false = OFF (parity — the signal_stuck system
    #                                   tool is not wired); true = ON (the model may call
    #                                   signal_stuck, which ends the turn with
    #                                   `outcome: :stuck` + a final message + a :turn_stuck
    #                                   event the consumer acts on). Same opt-in as
    #                                   `memory`. What "stuck" MEANS is the consumer's call
    #                                   (escalation via CRM/operator), never the engine's.
    :stt_prompt,                     # STT vocabulary hint (WS9): domain words
    #                                   (product names, brand terms) the transcriber should
    #                                   expect on this agent's voice notes — passed straight
    #                                   through to the Whisper-family provider's `prompt:`.
    #                                   nil/absent = the deployment default (INSIKA_STT_PROMPT
    #                                   env) or nothing. OPERATOR config, never customer input.
    :outputs,                         # generated-media output policy (WS9, saída):
    #                                   { "image" => { "model" => …, "size" => "1024x1024" },
    #                                   "tts" => { "model" => "tts-1", "voice" => "alloy",
    #                                   "format" => "mp3" } }. THE AGENT'S HALF of the
    #                                   media-output gate — nil/absent = the agent never
    #                                   generates media (opt-in like `capabilities`, do NOT
    #                                   "fix" to nil = all). The other half is the CHANNEL'S:
    #                                   the request must declare it can receive the media
    #                                   (`channel.capabilities` — "image_output" /
    #                                   "audio_output"); only with BOTH does the model see
    #                                   the generate_image/tts tools (the abstraction admits
    #                                   only what leaks). Generated media rides the turn's
    #                                   `output_parts` in the envelope, never the answer text.
    :model_policy,                    # governance of WHICH models the agent may use:
    #                                   { "allow" => [refs] }. nil = NO fence (all models —
    #                                   parity). Enforced on the RESOLVED model (ModelResolver).
    :guardrails,                      # content-safety config: { input:, output:,
    #                                   moderator:, strictness: }. OPT-IN like capabilities —
    #                                   nil/absent = the conservative default (Safety::Config:
    #                                   deterministic on, moderator off). Parsed, never a policy.
    :sandbox,                         # confined-execution config:
    #                                   { provider: "local"|"docker", root:, timeout:, ...+provider
    #                                   keys }. Declarative provider selection (config-over-code) —
    #                                   consumed by Insika::Sandbox.build. {} = absent (a
    #                                   deployment builds a `local` sandbox by default). It is
    #                                   CONFIG, never a policy — it does not decide security by
    #                                   itself; the FS boundary + approvals do.
    :refinement,                      # self-improvement config:
    #                                   { mode: "report"|"propose"|"auto_apply", window: {…},
    #                                   files: [allowlist], proposers: [refs], budget: {tokens:},
    #                                   auto_apply_max_edits:, max_findings:, … }. nil/absent =
    #                                   REPORT-ONLY (writes nothing to the agent, so
    #                                   reading your own traces needs no opt-in); `propose`
    #                                   and above must be enabled explicitly. It is CONFIG,
    #                                   never a policy — the write allowlist it carries is
    #                                   enforced by the applier, not by this field.
    :capabilities_declared,           # FACTS ABOUT THIS DEPLOYMENT that are not tools
    # %w[promotions human_handoff
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
    :grounding,                     # the pack's grounding policy —
    #                                   { "mode" => "flag"|"enforce"|"off",
    #                                   "matcher" => { "sku" => …,
    #                                   "name_keys" => [...] } }. OPT-IN:
    #                                   nil/absent = OFF (parity, zero allocations).
    #                                   Deep-stringified like the other hashes.
    :metadata,                      # free-form agent metadata, stable per agent
                                   # (from the pack `agent.config.json`). Home of the `store_id`
                                   # that becomes turn context (ctx.store_id).
                                   # It is NOT a policy — never decides security. {} = absent.
    :briefing_fields,                # the per-session working-state schema this agent
                                   # keeps and asks for: a flat [String] of
                                   # field names the pack declares. []/nil/absent = the
                                   # feature is OFF (no provider output, no tools — visibly
                                   # removable). Names are engine-owned store keys
                                   # and tool text, so they are validated against NAME_RE at
                                   # build time. Data, never a policy: the engine owns the
                                   # briefing object, the pack owns the fields.
    :funnel,                         # the outcome funnel declaration — pack
                                   # data, exactly like budget/reliability:
                                   # { "stages" => ["greeted", "qualified", "cart", "paid"],
                                   #   "advance_on" => { "pix_paid" => "paid", … },
                                   #   "primary" => "paid", "attribution_window" => "72h" }.
                                   # The ENGINE never hard-codes a stage name: the fold,
                                   # the doctor and the Studio read this declaration (D1).
                                   # nil/absent = no funnel (parity — nothing folds).
                                   # Deep-stringified like the other free-form hashes;
                                   # shape-validated by FunnelDeclaration, never here (D8).
    :followup,                       # the follow-up declaration — pack data,
                                   # exactly like budget/funnel:
                                   # { "arm" => "schedule",
                                   #   "policy" => { "quiet_hours" => { "timezone" => "…",
                                   #       "start" => "21:30", "end" => "09:00" },
                                   #     "max_frequency" => "2/24h",
                                   #     "cancel_keywords" => ["não quero mais contato"],
                                   #     "silence_after_sends" => 3 } }.
                                   # The engine OWNS the firing, never a policy value (D1);
                                   # shape-validated by FollowupPolicy, never here (D9).
                                   # nil/absent = the feature is off (parity).
                                   # Deep-stringified like the other free-form hashes.
    :distill,                        # the session-distillation declaration — pack
                                   # data, exactly like refinement/followup:
                                   # { "enabled" => bool, "prompt" => "<pack-authored markdown
                                   #   — what counts as a fact for this store>",
                                   #   "model" => "<ref — absent = the platform utility_model>",
                                   #   "idle_hours" => 6, "min_messages" => 3,
                                   #   "max_proposals" => 10 }.
                                   # The ENGINE assembles the scope from the session; the
                                   # model only names facts (D1). nil/absent = the feature is
                                   # off (parity, byte-identical engine). Shape-validated by
                                   # the command/engine, never here (the refinement precedent).
                                   # Deep-stringified like the other free-form hashes.
    :harvest,                        # the gated-harvest declaration — pack data,
                                     # exactly like refinement/distill:
                                     # { "enabled" => bool,
                                     #   "negative_list" => [ { "rule" => "…", "pattern" => "…",
                                     #                          "note" => "…" } ],
                                     #   "miner" => { "model" => "<ref — absent = the platform
                                     #       utility_model>", "window" => { "last_sessions" => N },
                                     #       "max_proposals" => N, "budget" => { "tokens" => N } },
                                     #   "idle_hours" => 24, "min_messages" => 3 }.
                                     # The ENGINE mines (reads sessions, asks the miner, filters
                                     # through the negative list + grounding), never authors a
                                     # rule (D4). nil/absent = the loop is off (parity).
                                     # Shape-validated by the command/engine/doctor, never here.
                                     # Deep-stringified like the other free-form hashes.
    :knowledge,                       # the post-turn learning declaration — pack
                                   # data, exactly like distill/harvest:
                                   # { "extract" => true, "retrieve" => true,
                                   #   "model" => "<ref — absent = the platform
                                   #       utility_model>", "top_k" => 5,
                                   #   "index" => "scan", "types" => ["fact", …] }.
                                   # The ENGINE extracts concepts after the turn and
                                   # stamps their provenance/confidence/sources;
                                   # the model only names concepts (same D1
                                   # discipline as distill). nil/absent = the
                                   # loop is off (parity). Shape-validated by
                                   # the extractor/doctor, never here.
                                   # Deep-stringified like the other free-form hashes.
    :schedules                       # the recurring-schedule declarations — pack
                                     # data, exactly like followup/distill:
                                     # [ { "id" => "daily_report",
                                     #     "cron" | "every" => …,
                                     #     "tz" => "America/Sao_Paulo",
                                     #     "message" => "<the synthetic inbound>",
                                     #     "session_mode" => "new"|"fixed",
                                     #     "overrides" => { "turn_timeout" => N,
                                     #                        "max_tool_calls" => N,
                                     #                        "model" => … },
                                     #     "enabled" => bool }, … ].
                                     # The ENGINE owns the firing (the
                                     # ScheduleEngine, the tick's duty); the
                                     # store rows are declared-derived.
                                     # Shape-validated by Insika::Schedule,
                                     # never here. nil/empty = the feature is
                                     # off for that agent (parity).
  )

  # Reopened class (not a Data.define block): a constant assigned inside
  # the block would leak into the lexical scope (Insika::DEFAULT_LIMITS).
  class AgentProfile
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_tool_calls: 50,
      # consecutive identical (tool, args) calls that trigger the ONE
      # loop warning; a repeat after it aborts like max_tool_calls. < 2 = off.
      max_tool_repeat: 3,
      approval_timeout: 3_600, # cap on the wait for human approval (~1h)
      # parallel tool calls. ONE number is both the switch and the cap
      # (nil/0/1 = serial, the default; N > 1 = at most N tool calls in flight).
      # It sits next to tool_timeout/max_tool_calls because it is the third bound
      # on tool execution. Read through TurnState#tool_concurrency, which also
      # applies the approval gate.
      tool_concurrency: 1
    }.freeze

    # `model` is OPTIONAL as of v2: an agent without one resolves the
    # platform `default_model` (Settings) at turn start via the ModelResolver.
    def self.build(id:, model: nil, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], tools_allow_groups: nil, skills: nil,
                   skills_eager: nil, context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, subagents: nil, tools_deferred: nil, memory: nil,
                   prompt_caching: nil, tool_persistence: nil, tool_output_compression: nil,
                    params: {}, model_policy: nil, guardrails: nil, sandbox: nil,
                    refinement: nil, capabilities_declared: nil, edge_stream: nil, metadata: {},
                     budget: nil, reliability: nil, alerts: nil, routes: nil, stuck_signal: nil,
outputs: nil, stt_prompt: nil, briefing_fields: nil, grounding: nil, funnel: nil,
                      followup: nil, distill: nil, harvest: nil, knowledge: nil, schedules: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), tools_allow_groups: tools_allow_groups, skills: skills,
        skills_eager: skills_eager,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: normalize_policies(policies, tools_allow: tools_allow, tools_deny: tools_deny,
                                     tools_allow_groups: tools_allow_groups),
        prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities,
        # opt-in like capabilities: nil => NONE. Array-normalize a present value so
        # readers get a clean [] and the ChatBuilder gate (present? => wire) is stable.
        subagents: subagents.nil? ? nil : Array(subagents).map(&:to_s),
        tools_deferred: tools_deferred, memory: memory,
        prompt_caching: prompt_caching, tool_persistence: tool_persistence,
        tool_output_compression: tool_output_compression,
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
        metadata: Coercion.deep_stringify(metadata || {}),
        budget: Coercion.deep_stringify(budget),
        reliability: Coercion.deep_stringify(reliability),
        alerts: Coercion.deep_stringify(alerts),
        routes: Coercion.deep_stringify(routes),
        stuck_signal: stuck_signal,
        outputs: Coercion.deep_stringify(outputs),
        # plain vocabulary string, like `base_prompt` — no deep_stringify (not
        # a Hash/Array). "" round-trips as nil (Coercion.presence).
        stt_prompt: Coercion.presence(stt_prompt),
        # Flat [String] — same discipline as capabilities_declared: a
        # symbol/string mix would be a silent miss in the provider's known-set.
        briefing_fields: normalize_briefing_fields(briefing_fields),
        # grounding is profile DATA, deep-stringified like the other
        # free-form hashes; parsed into a Grounding per turn by the validator/
        # enforcer. nil = off (parity).
        grounding: Coercion.deep_stringify(grounding),
        # funnel is profile DATA, deep-stringified like the other
        # free-form hashes; parsed into a FunnelDeclaration by the fold/doctor/
        # Studio (shape-validated THERE, never here — D8). nil = no funnel (parity).
        funnel: Coercion.deep_stringify(funnel),
        # followup is profile DATA, deep-stringified like the other
        # free-form hashes; parsed into a FollowupPolicy by the tool/engine/
        # doctor/Studio (shape-validated THERE, never here — D9). nil = off (parity).
        followup: Coercion.deep_stringify(followup),
        # distill is profile DATA, deep-stringified like the other
        # free-form hashes; shape-validated by the command/engine/doctor
        # (never here — the refinement precedent). nil = off (parity).
        distill: Coercion.deep_stringify(distill),
        # harvest is profile DATA, deep-stringified like the other
        # free-form hashes; shape-validated by the command/engine/doctor
        # (never here — the refinement precedent). nil = off (parity).
        harvest: Coercion.deep_stringify(harvest),
        # knowledge is profile DATA, deep-stringified like the other
        # free-form hashes; shape-validated by the extractor/doctor
        # (never here — the refinement precedent). nil = off (parity).
        knowledge: Coercion.deep_stringify(knowledge),
        # schedules is profile DATA, deep-stringified like the other
        # free-form hashes (an ARRAY of declarations); parsed into
        # Insika::Schedule entries by the engine/doctor/Studio (shape-validated
        # THERE, never here). nil/[] = the feature is off (parity).
        schedules: normalize_schedules(schedules)
      )
    end

    # Declaring a tool allow/deny list IS opting into it. The list is only ever
    # applied by the builtin `tool_allowlist` policy, and the Policy::Engine runs
    # ONLY the policies a profile names — so a profile with `tools_allow: [a, b]`
    # and no policies sent EVERY registered tool to the model, silently. A
    # declared allowlist that does nothing is the failure mode; same rule as the
    # "mcp:<name>" group auto-added to `tools_allow_groups` by the DSL.
    #
    # Presence, not emptiness, is the trigger for the two nil-able lists:
    # `tools_allow: []` means "no tools" and must enforce just as hard.
    # `tools_deny` has no nil state (it defaults to []), so only a non-empty
    # deny list counts as a declaration.
    #
    # Appended, never prepended: profile-declared policies keep their order. The
    # engine intersects allows and unions denies, so position changes only the
    # audit order, not the outcome.
    def self.normalize_policies(policies, tools_allow:, tools_deny:, tools_allow_groups:)
      names = Array(policies)
      declared = !tools_allow.nil? || !tools_allow_groups.nil? || !Array(tools_deny).empty?
      return names unless declared && names.none? { |n| n.to_s == "tool_allowlist" }

      names + ["tool_allowlist"]
    end

    # nil/absent -> nil; a single Hash -> [Hash]; else an Array of Hashes —
    # deep-stringified so JSON round-trips stay stable.
    def self.normalize_schedules(list)
      return nil if list.nil?

      entries = list.is_a?(Hash) ? [list] : Array(list)
      entries.empty? ? nil : Coercion.deep_stringify(entries)
    end

    # nil -> []; strings; trim + drop empties + uniq (stable order); every name
    # must match ToolDefinition::NAME_RE (\A[a-z][a-z0-9_]*\z) or it is a
    # ValidationError at build time — the names become tool-description text,
    # store keys and context-block lines, so "size ok" or "tamanho do cliente"
    # is refused here, not corrupted later.
    def self.normalize_briefing_fields(list)
      names = Array(list).map { |f| f.to_s.strip }.reject(&:empty?).uniq
      bad = names.reject { |n| ToolDefinition::NAME_RE.match?(n) }
      unless bad.empty?
        raise Insika::ValidationError,
              "briefing_fields must match #{ToolDefinition::NAME_RE.inspect}: #{bad.join(', ')}"
      end
      names
    end

    # opt-in for an optional tool = being in the agent's allow list.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end

    # store_id of the turn context (ctx.store_id): lives in `metadata` (stable
    # per store, comes from the pack). `build` string-keys metadata, so a plain
    # string lookup is enough. nil = absent (the data-tool emits an empty header).
    # It is NOT consumer-specific: `store_id` is a field of the turn-context contract
    # generic per project.
    def store_id = (metadata || {})["store_id"]

    # May this channel (:thinking / :intermediate) cross to the customer? Tolerant
    # of the string values a form or a pack round-trip produces ("1"/"true"), and
    # of anything else being absent: the safe reading is the default one.
    def stream_public?(channel)
      v = (edge_stream || {})[channel.to_s]
      Coercion.truthy?(v)
    end
  end
end
