# frozen_string_literal: true

# CONCRETE demo deployment — "run for real" (no mocks): real DeepSeek +
# 1 agent (demo) with OpenClaw-style prompts + real tools/skills + memory.
# Builds on the SAME shared graph as config/wiring.rb (Insika::Wiring::Graph),
# then layers on the real PROFILES/tools + the full runtime-authoring surface.
#
# Usage: DEEPSEEK_API_KEY=... ruby -r ./config/deployment (or via scripts/run_real.rb).

require_relative "../lib/insika"
require "ruby_llm"
require_relative "../deploy/tools"

module Deploy
  # STRICT config gate. Validates the environment against the engine
  # schema PLUS this deployment's own keys. Default = WARN (last-known-good: a rotated
  # key or a typo must never take the whole service down — same reasoning as the
  # resilient DEEPSEEK boot below); set INSIKA_CONFIG_STRICT=1 to refuse boot instead.
  # `insika doctor` gives the same report on demand.
  #
  # Env rename (pass 2): backfill INSIKA_* from any legacy HARNESS_* alias BEFORE the
  # gate and before any read below — the process ENV speaks the new names from here on
  # (a deprecation warning names the ones still set under the old prefix).
  Insika::EnvSchema.reconcile_legacy!
  ENV_SPECS = [
    Insika::EnvSchema.spec(name: "DEEPSEEK_API_KEY", secret: true, description: "DeepSeek API key (turns fail until set — env or Studio)."),
    Insika::EnvSchema.spec(name: "DEEPSEEK_MODEL", description: "DeepSeek model id (default: deepseek-v4-flash)."),
    Insika::EnvSchema.spec(name: "TOOL_TIMEOUT", type: :integer, description: "Per-tool-call timeout (s)."),
    Insika::EnvSchema.spec(name: "TURN_TIMEOUT", type: :integer, description: "Per-turn timeout (s)."),
    Insika::EnvSchema.spec(name: "CONSUMER_INTERNAL_URL", type: :url, description: "Consumer internal API base (data-tool callbacks)."),
    Insika::EnvSchema.spec(name: "INSIKA_INTERNAL_API_TOKEN", secret: true, description: "Bearer for the consumer internal API.")
  ].freeze
  Insika::EnvSchema.enforce!(extra: ENV_SPECS)

  # Cloud resilience: without the key, does NOT bring down the process — the engine
  # comes up (/up green) and turns fail with a clear error until the key exists (via env
  # OR via Studio > LLM providers, which reconfigures RubyLLM at runtime). A
  # `raise` here would take the whole service down over a missing/rotating env.
  DEEPSEEK_KEY = ENV["DEEPSEEK_API_KEY"].to_s
  warn "[deploy] WARNING: DEEPSEEK_API_KEY missing — engine comes up, but turns fail until configured (env or Studio > LLM providers)." if DEEPSEEK_KEY.empty?

  # REAL LLM (same model as OpenClaw production).
  RubyLLM.configure do |c|
    c.deepseek_api_key = DEEPSEEK_KEY
    c.deepseek_api_base = "https://api.deepseek.com/v1"
    c.request_timeout = 120
    c.max_retries = 2
  end

  MODEL = ENV.fetch("DEEPSEEK_MODEL", "deepseek-v4-flash") # the old "deepseek-chat" alias is retired
  ROOT  = File.expand_path("..", __dir__)
  AGENT_DIR = File.join(ROOT, "deploy", "agents", "demo")

  module Wiring
    # --- Shared spine (Insika::Wiring::Graph) --------------------
    # Durability-aware backend: INSIKA_DB -> SQLite (config + execution survive
    # restart); missing -> Memory (dev/demo). The same backend holds execution AND
    # configuration. Policy builtins: tool/skill allowlist + approval_required (no
    # :workflow_allowlist — the deployment does not expose workflows).
    BACKEND = Insika::Wiring::Graph.backend_from_env
    SPINE   = Insika::Wiring::Graph.spine(backend: BACKEND)

    # Promote the spine to the historic public constants (read shortcuts; the Studio,
    # serve_real, and the smoke consume Deploy::Wiring::SESSION_STORE etc.).
    EVENT_STREAM         = SPINE.event_stream
    SESSION_STORE        = SPINE.session_store
    TASK_STORE           = SPINE.task_store
    CHECKPOINT_STORE     = SPINE.checkpoint_store
    PENDING_ACTION_STORE = SPINE.pending_action_store
    MEMORY_STORE         = SPINE.memory_store
    # the append-only, content-free operator-mutation audit.
    MEMORY_AUDIT_STORE   = SPINE.memory_audit_store
    REFINEMENT_STORE     = SPINE.refinement_store
    REGISTRY             = SPINE.code_tool_registry
    WORKFLOW_REGISTRY    = SPINE.workflow_registry
    POLICY_REGISTRY      = SPINE.policy_registry
    CAPABILITY_REGISTRY  = SPINE.capability_registry
    HOOKS                = SPINE.hooks

    # REAL tools (block factory — fresh instance per turn).
    Deploy::Tools::ALL.each { |name, klass| REGISTRY.register(name, plugin: "pizzaria") { klass.new } }

    # Durable config: profiles + prompt workspace + authored skills live HERE (SQLite
    # when INSIKA_DB; otherwise ephemeral Memory).
    CONFIG_STORE      = Insika::ConfigStore.new(store: BACKEND)
    AGENT_FILE_STORE  = Insika::AgentFileStore.new(config_store: CONFIG_STORE)
    SKILL_STORE       = Insika::SkillStore.new(config_store: CONFIG_STORE)

    # DATA-DEFINED tools: definitions in the ToolStore; the overlay composes the
    # CODE tools (REGISTRY) with the data-defined ones. It is the Executor's and the
    # ToolCatalog's `tool_registry` (drop-in) — new data-tools take effect without a restart via reload.
    TOOL_STORE    = Insika::ToolStore.new(config_store: CONFIG_STORE)
    # Per-session tool-call trace (debug in the Studio). Durable in the
    # same backend; masking/truncation in the store itself.
    TOOL_TRACE_STORE = Insika::ToolTraceStore.new(store: BACKEND)
    # Per-session context breakdown (tokens by category + budget) for the
    # Studio session card. Counts and provider ids only — no content, no masking.
    CONTEXT_TRACE_STORE = Insika::ContextTraceStore.new(store: BACKEND)
    # per-AGENT cache-hit series (Studio agent-detail card). Sessions
    # do not stamp their agent, so this capped list is the only way to answer
    # "cache-hit over time for THIS agent". Percentages and counts — no content.
    CACHE_SERIES_STORE = Insika::CacheSeriesStore.new(store: BACKEND)
    # Egress of the data-tools (SSRF guard). Default = strict (public https only).
    # For the engine to CALL BACK the consumer's internal API (its
    # /api/internal/*), which is http/loopback locally, enable via env — preferably
    # STOPPING at a known host:
    #   INSIKA_EGRESS_ALLOW_HTTP=1  INSIKA_EGRESS_ALLOW_PRIVATE=1
    #   INSIKA_EGRESS_HOSTS=localhost,127.0.0.1
    #
    # Read through EnvSchema.truthy? (1/true/yes/on), which is what the schema
    # ADVERTISES for a :boolean key. This used to be a hand-rolled `== "1"`, so
    # `INSIKA_EGRESS_ALLOW_HTTP=true` — valid per `insika env`, and the spelling
    # anyone writes first — was read as FALSE and every data-tool died with
    # "destination blocked: http not allowed", pointing at the URL instead of the flag.
    EGRESS_OPTIONS = {
      allow_http: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_HTTP"]),
      allow_private: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_PRIVATE"]),
      host_allowlist: ENV["INSIKA_EGRESS_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?).then { |l| l.empty? ? nil : l }
    }.compact
    # MCP instances (durable config, masked credentials) — created here
    # (rather than by its usual spot below, with SYSTEM_FILE_STORE) so
    # TOOL_REGISTRY can fold in its LIVE tools.
    MCP_STORE = Insika::McpStore.new(config_store: CONFIG_STORE)
    # `entries` is cheap (McpStore#tools_cache, no I/O) — `refresh` (below,
    # wired to :refresh_mcp_tools) is the only thing that connects live.
    MCP_TOOL_REGISTRY = Insika::McpToolRegistry.new(mcp_store: MCP_STORE)
    TOOL_REGISTRY = Insika::OverlayToolRegistry.new(
      base: REGISTRY, tool_store: TOOL_STORE, http: Insika::HttpClient.new,
      event_stream: EVENT_STREAM, egress_options: EGRESS_OPTIONS,
      mcp_registry: MCP_TOOL_REGISTRY
    )
    TOOL_CATALOG  = Insika::ToolCatalog.new(tool_registry: TOOL_REGISTRY)

    # General settings + LLM providers authorable at runtime: durable in the same
    # backend. The LLMConfigurator re-applies the providers to RubyLLM without a
    # restart (per-provider key/base). Seed: the deepseek provider from boot already
    # lives in the global config (RubyLLM.configure above) — the store is the editable
    # source from here on.
    SETTINGS_STORE    = Insika::SettingsStore.new(config_store: CONFIG_STORE)
    LLM_PROVIDER_STORE = Insika::LLMProviderStore.new(config_store: CONFIG_STORE)
    LLM_CONFIGURATOR  = Insika::LLMConfigurator.new(provider_store: LLM_PROVIDER_STORE)

    # LLM config v2: seed the PLATFORM default so a modelless agent works out of
    # the box (Chat > Agent > platform default). Idempotent — only seeds when the
    # operator hasn't set one; mirrors the boot provider (DeepSeek). The demo seed below
    # still pins its own model, so this only kicks in for agents created WITHOUT one.
    if Insika::Coercion.presence(SETTINGS_STORE.get["default_model"]).nil?
      SETTINGS_STORE.update("default_model" => Deploy::MODEL, "default_provider" => "deepseek")
    end

    # Global system files, applied to ALL agents (injected by the Prompt
    # provider before the identity). MCP_STORE is defined earlier, alongside
    # TOOL_REGISTRY.
    SYSTEM_FILE_STORE  = Insika::SystemFileStore.new(config_store: CONFIG_STORE)

    # Catalogs with a Store overlay: disk = seed, Store = authored (wins). reload
    # makes edits hot (no restart).
    CATALOG        = Insika::SkillCatalog.new([File.join(Deploy::ROOT, "deploy", "skills")], store: SKILL_STORE)
    PROMPT_CATALOG = Insika::PromptCatalog.new([])

    # Guardrails / content safety. One Factory composes the three seams:
    # the InputGuardrail Middleware, the OutputValidator after_task hook, and the
    # per-turn OutputFilter (stream redaction) injected into the Executor. Per-agent
    # `guardrails:` config auto-enables/disables each turn; the moderator resolves the
    # platform utility_model (SettingsStore, #18) as its fallback model.
    GUARDRAILS = Insika::Safety::Factory.new(settings_store: SETTINGS_STORE)

    # Production edge: rate-limit per chat + token ceiling per
    # agent, both opt-in (Studio > Settings > Edge limits; per-agent overrides in
    # the agent config). Counters durable in the SAME backend as everything else.
    # WS2 calendar budgets (AgentProfile#budget) ride the BudgetLedger +
    # the event stream (budget_warning).
    EDGE_LIMITER = Insika::EdgeLimiter.new(
      ledger: Insika::UsageLedger.new(store: BACKEND), settings_store: SETTINGS_STORE,
      budget_ledger: SPINE.budget_ledger, event_stream: EVENT_STREAM
    )

    # OpenClaw-style prompts become the IDENTITY (pinned) via the Prompt provider.
    # `demo`'s own `prompt_files` below point here — there is no deployment-wide
    # fallback identity: an agent without its own prompt_files/base_prompt refuses
    # to run (Prompt#call) rather than inherit another agent's persona.
    IDENTITY_FILES = %w[IDENTITY.md SOUL.md TOOLS.md].map { |f| File.join(Deploy::AGENT_DIR, f) }

    CONTEXT_PROVIDERS = [
      Insika::Context::Providers::Request.new,
      Insika::Context::Providers::Prompt.new(base: "", catalog: PROMPT_CATALOG, agent_files: AGENT_FILE_STORE, system_files: SYSTEM_FILE_STORE),
      Insika::Context::Providers::Skill.new(catalog: CATALOG),
      Insika::Context::Providers::SkillTrigger.new(catalog: CATALOG),
      Insika::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      Insika::Context::Providers::Memory.new(store: MEMORY_STORE),
      Insika::Context::Providers::Knowledge.new(store: SPINE.knowledge_store),
      Insika::Context::Providers::Briefing.new(session_store: SESSION_STORE),
      Insika::Context::Providers::Session.new(session_store: SESSION_STORE)
    ] # NOT frozen: load_plugins appends plugin providers at boot (pre-listen)

    # DYNAMIC profiles: persisted in the ConfigStore, editable at runtime by the
    # Studio (create/update/delete_agent). The Executor and the turn Commands resolve
    # at dispatch.
    PROFILE_SOURCE = Insika::StoredProfileSource.new(config_store: CONFIG_STORE)

    # `demo` agent seed (idempotent — the docs' neutral id): only
    # creates if it doesn't exist yet. In Memory it re-seeds every boot; in SQLite
    # it persists and the owner can create other agents.
    unless PROFILE_SOURCE.fetch("demo")
      PROFILE_SOURCE.put(Insika::AgentProfile.build(
                           id: "demo", model: Deploy::MODEL, provider: :deepseek,
                           prompt_files: IDENTITY_FILES,
                           tools_allow: %w[menu calc current_time], skills: %w[pedido],
                           policies: %i[tool_allowlist skill_allowlist], memory: true,
                           limits: { tool_timeout: Integer(ENV.fetch("TOOL_TIMEOUT", "30")),
                                     turn_timeout: Integer(ENV.fetch("TURN_TIMEOUT", "120")) }
                         ))
    end

    # --- Assemble the graph (Executor + core Command Bus) ---------
    # The core bus already carries pause_task/approve_action — no more config.ru /
    # serve_real.rb patch. executor_extra adds the deployment-only stores.
    GRAPH = Insika::Wiring::Graph.build(
      spine: SPINE, profiles: PROFILE_SOURCE,
      tool_registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG,
      skill_catalog: CATALOG, prompt_catalog: PROMPT_CATALOG,
      guardrails: GUARDRAILS, context_providers: CONTEXT_PROVIDERS,
      edge_limiter: EDGE_LIMITER,
      executor_extra: {
        settings_store: SETTINGS_STORE,  # v2 model resolution: platform default_model + fallbacks
        tool_trace_store: TOOL_TRACE_STORE,
        context_trace_store: CONTEXT_TRACE_STORE,
        cache_series_store: CACHE_SERIES_STORE
      }
    )

    # shadow on + criterion missing/unparseable refuses boot here
    # (the AppBuilder does it for the rack_app path; this root wires its own
    # channel and its own judge command). The sha stamps every pair our half
    # records, through the same criterion object the judge command folds with.
    if Insika::EnvSchema.truthy?(ENV["INSIKA_RELAY_SHADOW"])
      criterion_path = Insika::EnvSchema.read("INSIKA_PARITY_CRITERION")
      raise Insika::ConfigError, "shadow mode requires INSIKA_PARITY_CRITERION (the frozen criterion)" if criterion_path.nil?

      PARITY_CRITERION = Insika::Parity::Criterion.load(criterion_path)
      GRAPH.channel_delivery.criterion_sha = PARITY_CRITERION.sha
    end

    CONTEXT_BUILDER = GRAPH.context_builder
    POLICY_ENGINE   = GRAPH.policy_engine
    MIDDLEWARE      = GRAPH.middleware
    EXECUTOR        = GRAPH.executor
    BUS             = GRAPH.bus

    # --- Deployment-only command surface (authoring via the bus) --

    # Runtime agent authoring — the "everyone creates their own agent".
    BUS.register(:create_agent, Insika::Commands::CreateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:update_agent, Insika::Commands::UpdateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent, Insika::Commands::DeleteAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:set_agent_tools, Insika::Commands::SetAgentTools.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Per-agent prompts/skills — "everyone creates their own agent with its own
    # identity". Content in the Store, hot via reload/ProfileSource.
    BUS.register(:write_agent_file, Insika::Commands::WriteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent_file, Insika::Commands::DeleteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_agent_file, Insika::Commands::RestoreAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:write_skill, Insika::Commands::WriteSkill.new(skill_store: SKILL_STORE, skill_catalog: CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:delete_skill, Insika::Commands::DeleteSkill.new(skill_store: SKILL_STORE, skill_catalog: CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:set_skill_agents, Insika::Commands::SetSkillAgents.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Memory + settings + LLM — memory becomes editable over HTTP (not only via the
    # `remember` tool); settings and providers gain durable CRUD.
    # operator edits carry an audit line (content-free digests).
    BUS.register(:memory_put_fact, Insika::Commands::MemoryPutFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM, audit_store: MEMORY_AUDIT_STORE))
    BUS.register(:memory_forget_fact, Insika::Commands::MemoryForgetFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM, audit_store: MEMORY_AUDIT_STORE))
    BUS.register(:memory_add_note, Insika::Commands::MemoryAddNote.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    # the LGPD access right — the Studio Customers drill exports.
    BUS.register(:export_customer_memory, Insika::Commands::ExportCustomerMemory.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    # Refinement: reads the agent's OWN traffic (tasks + sessions +
    # tool traces) and records a ranked failure report. Read-only — no model call and
    # no edit to the agent — so it needs no per-agent opt-in; `propose`/`auto_apply`
    # will. Settings are injected so the collector recognizes the edge
    # limiter's canned reply as evidence.
    REFINEMENT_COLLECTOR = Insika::Refinement::EvidenceCollector.new(
      task_store: TASK_STORE, session_store: SESSION_STORE,
      tool_trace_store: TOOL_TRACE_STORE, profiles: PROFILE_SOURCE,
      settings_store: SETTINGS_STORE
    )
    BUS.register(:run_refinement, Insika::Commands::RunRefinement.new(profiles: PROFILE_SOURCE, refinement_store: REFINEMENT_STORE, collector: REFINEMENT_COLLECTOR, event_stream: EVENT_STREAM))

    # Eval cases as data: authored in the Studio and
    # validated by the same loader the corpus files go through. The corpus on disk stays
    # the seed (`insika evals:import`) and the export format.
    GOLDEN_STORE = Insika::GoldenStore.new(config_store: CONFIG_STORE)
    BUS.register(:write_golden, Insika::Commands::WriteGolden.new(golden_store: GOLDEN_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_golden, Insika::Commands::DeleteGolden.new(golden_store: GOLDEN_STORE, event_stream: EVENT_STREAM))

    # `run_persona_eval` (C3.1): a QA agent's own probe against a sibling agent
    # of THIS deployment's own graph. Not part of `Graph.build` itself (it
    # needs `GOLDEN_STORE`/`SETTINGS_STORE`, and neither lives on the spine —
    # the minimal wiring builds without either) — registered here, the same
    # call `DSL::Runtime` makes for its own graph.
    Insika::Wiring::Graph.register_persona_eval_tool(GRAPH, golden_store: GOLDEN_STORE, settings_store: SETTINGS_STORE)

    # Refinement: a candidate is scored by RUNNING it —
    # clone the agent, apply the edits to the clone, replay the golden set over the
    # deployment's OWN /v1/responses, compare to the accepted baseline. Then a human
    # approves and the write lands versioned in the AgentFileStore.
    #
    # The transport is built per gate rather than once, because it carries the
    # deployment's public URL and gateway token and the operator can rotate either.
    # `INSIKA_PUBLIC_URL` is what the clone is reachable at — the replay is a real HTTP
    # turn on purpose, so the gate measures what a customer would get, tools and
    # guardrails included, instead of a shortcut into the store.
    BASELINE_STORE = Insika::BaselineStore.new(config_store: CONFIG_STORE)
    REFINEMENT_GATE = Insika::Refinement::Gate.new(
      profiles: PROFILE_SOURCE, agent_files: AGENT_FILE_STORE, goldens: GOLDEN_STORE,
      baselines: BASELINE_STORE,
      # Resolved from ENV here rather than closing over `config.ru`'s GATEWAY_TOKEN:
      # the wiring must not depend on a constant its own caller defines, and the rule
      # (gateway token, falling back to the admin token) is the same one every surface
      # applies. Read per call so a rotation takes effect without a restart.
      transport_factory: lambda {
        Insika::Evals::HttpTransport.new(
          base_url: Insika::Coercion.presence(ENV["INSIKA_PUBLIC_URL"]) ||
                    "http://127.0.0.1:#{ENV.fetch('PORT', 9292)}",
          token: ENV["INSIKA_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"]
        )
      },
      # The judges the OPERATOR configured (`settings["evals"]`), through the one
      # builder the CLI also uses — is explicit that a second copy of the judge
      # would be the worst outcome, because the gate would grade against a rubric
      # nobody tuned. nil when nobody is configured: then a rubric'd case reads as
      # judge_pending, which is visible, instead of silently passing.
      # a case the deployment cannot satisfy is SKIPPED, not failed.
      # The eval CLI already resolves that over the same gated `/v1/agents/:id`; the
      # gate has to resolve it the same way or the two disagree about what the corpus
      # measures.
      capabilities_factory: lambda {
        Insika::Evals::HttpCapabilities.new(
          base_url: Insika::Coercion.presence(ENV["INSIKA_PUBLIC_URL"]) ||
                    "http://127.0.0.1:#{ENV.fetch('PORT', 9292)}",
          token: ENV["INSIKA_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"]
        )
      },
      judge_factory: -> { Insika::Evals::JudgePanel.judge((SETTINGS_STORE.get || {})["evals"]) }
    )
    # Who WRITES the candidates. Per agent (`refinement.proposers`, a
    # PANEL — or `refinement.proposer`, one), falling back to the platform
    # utility_model, the same "which model does the cheap side work" setting the
    # judges and the moderator read. Built per call, and for the same reason the
    # transport is: the operator can change either without a restart. Empty when
    # nothing is set, and then the command refuses instead of guessing a model to
    # spend money on.
    PROPOSER_FACTORY = lambda { |config|
      Insika::Refinement::ProposerFactory.panel(
        config, utility_model: (SETTINGS_STORE.get || {})["utility_model"]
      )
    }
    # `mode: auto_apply` reuses this handler rather than writing files itself, so
    # an unattended apply goes through the SAME staleness re-check, versioned write and
    # `:refinement_applied` event a human approval does. Registered first because the
    # gate command holds it.
    RESOLVE_REFINEMENT = Insika::Commands::ResolveRefinement.new(profiles: PROFILE_SOURCE, refinement_store: REFINEMENT_STORE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM)
    BUS.register(:gate_refinement, Insika::Commands::GateRefinement.new(profiles: PROFILE_SOURCE, refinement_store: REFINEMENT_STORE, agent_file_store: AGENT_FILE_STORE, gate: REFINEMENT_GATE, event_stream: EVENT_STREAM, proposer_factory: PROPOSER_FACTORY, resolver: RESOLVE_REFINEMENT))
    BUS.register(:resolve_refinement, RESOLVE_REFINEMENT)

    # the gated harvest — the deployment's half of the double gate
    # (the base graph wires nil factories; the flows refuse with named reasons
    # until THIS root lands).
    #
    # The two pre-registered artifacts: the frozen conversion criterion and the
    # negative-list seed, both read from the deployment's environment and
    # strict-loaded. A missing/unparseable criterion REFUSES (nil — the gate
    # names the hole), it never guesses; the negative list is the injected
    # fallback the per-profile operative list overrides.
    HARVEST_CRITERION = begin
      path = Insika::EnvSchema.read("INSIKA_HARVEST_CRITERION")
      path && Insika::Harvest::Criterion.load(path)
    rescue Insika::ConfigError, Insika::ValidationError => e
      warn "[harvest] no frozen criterion at boot: #{e.message}"
      nil
    end
    HARVEST_NEGATIVE = begin
      path = Insika::EnvSchema.read("INSIKA_HARVEST_NEGATIVE")
      path && Insika::Harvest::NegativeList.parse!(File.read(path))
    rescue Errno::ENOENT, Insika::ValidationError => e
      warn "[harvest] no negative-list seed: #{e.message}"
      Insika::Harvest::NegativeList.parse(nil)
    end
    # The eval gate mirrors REFINEMENT_GATE (same golden set, same baseline
    # store, same transport/judge/capabilities over the deployment's own
    # public URL) plus the skill collaborators, so the clone can SERVE the
    # candidate skill — gated by being usable, not by prose (D7).
    HARVEST_GATE = Insika::Harvest::Gate.new(
      profiles: PROFILE_SOURCE, agent_files: AGENT_FILE_STORE, goldens: GOLDEN_STORE,
      baselines: BASELINE_STORE, skill_store: SKILL_STORE, skill_catalog: CATALOG,
      transport_factory: lambda {
        Insika::Evals::HttpTransport.new(
          base_url: Insika::Coercion.presence(ENV["INSIKA_PUBLIC_URL"]) ||
                    "http://127.0.0.1:#{ENV.fetch('PORT', 9292)}",
          token: ENV["INSIKA_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"]
        )
      },
      capabilities_factory: lambda {
        Insika::Evals::HttpCapabilities.new(
          base_url: Insika::Coercion.presence(ENV["INSIKA_PUBLIC_URL"]) ||
                    "http://127.0.0.1:#{ENV.fetch('PORT', 9292)}",
          token: ENV["INSIKA_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"]
        )
      },
      judge_factory: -> { Insika::Evals::JudgePanel.judge((SETTINGS_STORE.get || {})["evals"]) }
    )
    # The second ruler: the store's funnel metric against the frozen baseline.
    # nil criterion -> the gate refuses with :no_criterion.
    HARVEST_CONVERSION = Insika::Harvest::ConversionGate.new(
      funnel_store: GRAPH.funnel_store, criterion: HARVEST_CRITERION
    )
    HARVEST_RUN = Insika::Commands::RunHarvest.new(
      profiles: PROFILE_SOURCE, harvest_store: GRAPH.harvest_store,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      skill_store: SKILL_STORE, tool_trace_store: TOOL_TRACE_STORE,
      settings_store: SETTINGS_STORE, negative_list: HARVEST_NEGATIVE,
      miner_factory: nil, # resolves harvest.miner.model -> the platform utility_model
      event_stream: EVENT_STREAM
    )
    # the automated loop rides the deployment's own runner (the negative
    # list + the settings-backed miner factory).
    EXECUTOR.harvest_engine.runner = HARVEST_RUN if EXECUTOR.harvest_engine
    BUS.register(:run_harvest, HARVEST_RUN)
    BUS.register(:gate_harvest, Insika::Commands::GateHarvest.new(
      harvest_store: GRAPH.harvest_store, gate: HARVEST_GATE,
      conversion_gate: HARVEST_CONVERSION, criterion: HARVEST_CRITERION,
      event_stream: EVENT_STREAM
    ))
    BUS.register(:promote_harvest, Insika::Commands::PromoteHarvest.new(
      harvest_store: GRAPH.harvest_store, skill_store: SKILL_STORE, skill_catalog: CATALOG,
      profile_source: PROFILE_SOURCE, criterion: HARVEST_CRITERION,
      conversion_gate: HARVEST_CONVERSION, event_stream: EVENT_STREAM
    ))
    BUS.register(:rollback_harvest, Insika::Commands::RollbackHarvest.new(
      harvest_store: GRAPH.harvest_store, skill_store: SKILL_STORE, skill_catalog: CATALOG,
      profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM
    ))
    BUS.register(:reject_harvest, Insika::Commands::RejectHarvest.new(
      harvest_store: GRAPH.harvest_store, event_stream: EVENT_STREAM
    ))

    BUS.register(:update_settings, Insika::Commands::UpdateSettings.new(settings_store: SETTINGS_STORE, event_stream: EVENT_STREAM))
    BUS.register(:upsert_llm_provider, Insika::Commands::UpsertLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))
    BUS.register(:delete_llm_provider, Insika::Commands::DeleteLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))

    # judging shadow pairs is a command on the DEPLOYMENT bus (like
    # the memory and refinement commands — not in the embeddable base). The
    # judges come from settings['evals'] through the one JudgePanel builder.
    # Registered only when shadow is on: the criterion refuses boot above
    # otherwise, and the command without one would be a fake judge.
    if defined?(PARITY_CRITERION) && PARITY_CRITERION
      BUS.register(:judge_shadow_pairs,
                   Insika::Commands::JudgeShadowPairs.new(
                     shadow_pairs: SPINE.shadow_pair_store, settings_store: SETTINGS_STORE,
                     criterion: PARITY_CRITERION, event_stream: EVENT_STREAM
                   ))
    end

    # MCP + system files: CRUD of MCP instances and of the global files that apply to
    # all agents.
    BUS.register(:upsert_mcp, Insika::Commands::UpsertMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_mcp, Insika::Commands::DeleteMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    # LIVE re-discovery — connects, lists, writes
    # MCP_STORE#tools_cache; TOOL_REGISTRY's live tools (MCP_TOOL_REGISTRY,
    # wired above) never depend on this cache to execute.
    BUS.register(:refresh_mcp_tools, Insika::Commands::RefreshMcpTools.new(mcp_registry: MCP_TOOL_REGISTRY, event_stream: EVENT_STREAM))
    BUS.register(:write_system_file, Insika::Commands::WriteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_system_file, Insika::Commands::DeleteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_system_file, Insika::Commands::RestoreSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))

    # Data-defined tools: authoring without code. registry = overlay (hot
    # reload); tool_catalog reloads level-1/tool_search. Secrets masked in the store.
    BUS.register(:write_data_tool, Insika::Commands::WriteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:delete_data_tool, Insika::Commands::DeleteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:restore_data_tool, Insika::Commands::RestoreDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))

    # Learned knowledge: the Studio's write/delete/restore path for a concept.
    BUS.register(:write_concept, Insika::Commands::WriteConcept.new(knowledge_store: GRAPH.knowledge_store, event_stream: EVENT_STREAM))
    BUS.register(:delete_concept, Insika::Commands::DeleteConcept.new(knowledge_store: GRAPH.knowledge_store, event_stream: EVENT_STREAM))
    BUS.register(:restore_concept, Insika::Commands::RestoreConcept.new(knowledge_store: GRAPH.knowledge_store, event_stream: EVENT_STREAM))

    # BATCH ingestion via manifest: upsert of the data-tools in a
    # standard format (JSON Schema) + declarative binding, hot (no restart). The
    # manifest's `{{secret.*}}`/`{{env.*}}` resolve from the DEPLOYMENT's ENV (the
    # secret never comes in the manifest —/R3); the placeholder key is the name of
    # the env var (e.g.: {{secret.INSIKA_INTERNAL_API_TOKEN}}, {{env.CONSUMER_INTERNAL_URL}}).
    IMPORT_TOOLS = Insika::Commands::ImportTools.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM, secrets: ENV, env: ENV)
    BUS.register(:import_tools, IMPORT_TOOLS)

    # RETIRED: this SNAPSHOT path froze each MCP tool as an
    # HTTP data-tool via a minimal JSON-RPC client with no real MCP lifecycle.
    # MCP_TOOL_REGISTRY (above, folded into TOOL_REGISTRY) replaces it with
    # LIVE execution over real transports (stdio/Streamable HTTP/SSE) — the
    # only thing to reach for going forward. Kept wired (never deleting a
    # working command) so any :mcp:* data-tool already ingested by a PAST
    # run of this command keeps executing; `insika doctor` flags such tools
    # with a migration hint.
    MCP_TOOL_INGESTOR = Insika::McpToolIngestor.new(
      mcp_store: MCP_STORE, import_tools: IMPORT_TOOLS,
      client_factory: ->(record) { Insika::McpHttpClient.new(url: record["url"], egress_options: EGRESS_OPTIONS) }
    )
    BUS.register(:import_mcp_tools, Insika::Commands::ImportMcpTools.new(ingestor: MCP_TOOL_INGESTOR, event_stream: EVENT_STREAM))

    # Pack provisioning: imports an agent from a standardized pack by
    # emitting the Commands above. Consumes the bus + READS the ProfileSource (upsert).
    # It's what the provisioning API (the GatewayClient) triggers.
    PACK_IMPORTER = Insika::PackImporter.new(bus: BUS, profiles: PROFILE_SOURCE)

    # Channels --------------------------------------
    # The registry lives on the spine and starts EMPTY, so `/channels/*` 404s until
    # an operator turns a channel on. The bundled relay is the one for an adopter who
    # already owns their messaging stack (a consumer that owns WhatsApp permanently):
    # it takes the turn and hands the reply back to the consumer's own callback.
    #
    # INSIKA_RELAY_TOKEN is the switch AND the credential — a public inbound route
    # with an LLM behind it is a money faucet, so there is no way to mount this
    # without a secret. The deliver side reuses the data-tools' egress posture: same
    # https-only default, same explicit opt-in for a consumer on a private network.
    CHANNEL_REGISTRY = SPINE.channel_registry
    RELAY = Insika::Channels::Relay.from_env(
      http: Insika::HttpClient.new,
      allow_http: !!EGRESS_OPTIONS[:allow_http], allow_private: !!EGRESS_OPTIONS[:allow_private]
    )
    CHANNEL_REGISTRY.register(RELAY.id, RELAY) if RELAY

    # The web widget — the other half of the same seam, for an adopter with no
    # messaging stack at all. Its switch is the two allowlists (which sites may embed
    # it, which agents it may address), and its credential is the chat rate limit:
    # the channel answers 503 until one is configured, because a public endpoint with
    # an LLM behind it and no ceiling is an unmetered bill.
    WEB_WIDGET = Insika::Channels::Web.from_env(
      chat_rate_limit: Insika::Channels::Web.limit_resolver(profiles: PROFILE_SOURCE,
                                                            settings_store: SETTINGS_STORE)
    )
    CHANNEL_REGISTRY.register(WEB_WIDGET.id, WEB_WIDGET) if WEB_WIDGET

    # Boot ---------------------------------------
    # The tested Recovery, finally instantiated in the PRODUCTION wiring: at boot
    # each worker discovers interrupted tasks and resumes them through the SAME
    # path as ResumeTask. Server::Boot runs it before the listen (config.ru).
    RECOVERY = Insika::Recovery.new(
      task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, command_bus: BUS
    )

    # Named steps consumed by Server::Boot, same contract as config/wiring.rb.
    # The graph above is built EAGERLY at require; `load_plugins` registers into
    # it afterwards (safe — see Wiring::Graph.load_plugins). Code-plugin tools
    # land in the base REGISTRY, so the overlay (TOOL_REGISTRY) composes them
    # exactly like the hand-registered ones.
    def self.load_plugins
      Insika::Wiring::Graph.load_plugins(GRAPH, bundled_root: File.join(Deploy::ROOT, "plugins"))
    end

    def self.build_stores = nil
    def self.recovery = RECOVERY

    # the task sweep runs ONCE per boot generation. INSIKA_BOOT_ID
    # is exported by deploy/entrypoint.sh (one id per container start, shared by
    # every Falcon worker); the first worker to claim it sweeps, the rest skip —
    # see docs/DEPLOY.md "The process model". Unset (single process) -> always sweep.
    def self.claim_recovery_sweep
      Insika::Recovery.claim_sweep(store: BACKEND, boot_id: ENV["INSIKA_BOOT_ID"])
    end

    # re-deliver async delegations whose child finished but whose
    # result was not delivered before a crash. Boot calls it after task recovery.
    def self.recover_delegations = EXECUTOR.recover_delegations

    # Boot sweep for replies a previous process committed but never handed over
    # Duck-typed by Server::Boot, exactly like recover_delegations.
    def self.recover_channel_deliveries = EXECUTOR.recover_channel_deliveries

    # Backend durability: Boot warns loudly when nothing will be resumed after a
    # restart (INSIKA_DB not set), instead of coming up "without a net" silently.
    def self.durable? = BACKEND.is_a?(Insika::Stores::SQLite)

    # OPT-IN observability: OTEL only turns on with INSIKA_OTEL / OTEL envs.
    # nil = off (parity, gem not even loaded). Turned on in the reactor via
    # Telemetry.attach (serving arm) — consumes the EVENT_STREAM into spans.
    TELEMETRY = Insika::Telemetry.setup(service_name: ENV.fetch("OTEL_SERVICE_NAME", "insika"))

    def self.stores = { session: SESSION_STORE, task: TASK_STORE, checkpoint: CHECKPOINT_STORE, pending: PENDING_ACTION_STORE, memory: MEMORY_STORE }
  end
end
