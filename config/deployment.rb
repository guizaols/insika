# frozen_string_literal: true

# CONCRETE demo deployment — "run for real" (no mocks): real DeepSeek +
# 1 agent (Bia) with OpenClaw-style prompts + real tools/skills + memory.
# Builds the same graph as config/wiring.rb, but with real PROFILES/tools.
#
# Usage: DEEPSEEK_API_KEY=... ruby -r ./config/deployment (or via scripts/run_real.rb).

require_relative "../lib/harness"
require "ruby_llm"
require_relative "../deploy/tools"

module Deploy
  # Cloud resilience (FOLLOWUP): without the key, does NOT bring down the process — the engine
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

  MODEL = ENV.fetch("DEEPSEEK_MODEL", "deepseek-chat") # v4-flash = "deepseek-chat" in the API
  ROOT  = File.expand_path("..", __dir__)
  AGENT_DIR = File.join(ROOT, "deploy", "agents", "bia")

  module Wiring
    # Durability-aware backend: HARNESS_DB -> SQLite (config + execution
    # survive restart — single-tenant in production runs on SQLite with a volume);
    # missing -> Memory (dev/demo). The same backend holds execution AND configuration.
    BACKEND =
      if (db = ENV["HARNESS_DB"]) && !db.empty?
        Harness::Stores::SQLite.new(path: db)
      else
        Harness::Stores::Memory.new
      end
    SESSION_STORE    = Harness::SessionStore.new(store: BACKEND)
    TASK_STORE       = Harness::TaskStore.new(store: BACKEND)
    CHECKPOINT_STORE = Harness::CheckpointStore.new(store: BACKEND)
    PENDING_ACTION_STORE = Harness::PendingActionStore.new(store: BACKEND)
    MEMORY_STORE     = Harness::MemoryStore.new(store: BACKEND)
    EVENT_STREAM     = Harness::EventStream.new

    REGISTRY          = Harness::ToolRegistry.new
    WORKFLOW_REGISTRY = Harness::WorkflowRegistry.new
    POLICY_REGISTRY   = Harness::PolicyRegistry.new
    POLICY_REGISTRY.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
    POLICY_REGISTRY.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
    POLICY_REGISTRY.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)

    # REAL tools (block factory — fresh instance per turn).
    Deploy::Tools::ALL.each { |name, klass| REGISTRY.register(name, plugin: "pizzaria") { klass.new } }

    CAPABILITY_REGISTRY = Harness::CapabilityRegistry.new

    # Durable config: profiles + prompt workspace + authored
    # skills live HERE (SQLite when HARNESS_DB; otherwise ephemeral Memory).
    CONFIG_STORE      = Harness::ConfigStore.new(store: BACKEND)
    AGENT_FILE_STORE  = Harness::AgentFileStore.new(config_store: CONFIG_STORE)
    SKILL_STORE       = Harness::SkillStore.new(config_store: CONFIG_STORE)

    # DATA-DEFINED tools (Phase 5): definitions in the ToolStore; the overlay composes the
    # CODE tools (REGISTRY) with the data-defined ones. It is the Executor's and the
    # ToolCatalog's `tool_registry` (drop-in) — new data-tools take effect without a restart via reload.
    TOOL_STORE    = Harness::ToolStore.new(config_store: CONFIG_STORE)
    # Per-session tool-call trace (debug in the Studio; FOLLOWUP §3.1). Durable in the
    # same backend; masking/truncation in the store itself.
    TOOL_TRACE_STORE = Harness::ToolTraceStore.new(store: BACKEND)
    # Egress of the data-tools (SSRF guard). Default = strict (public https only).
    # For the engine to CALL BACK the consumer's internal API (consumer-app
    # /api/internal/*), which is http/loopback locally, enable via env — preferably
    # STOPPING at a known host (NF4):
    #   HARNESS_EGRESS_ALLOW_HTTP=1  HARNESS_EGRESS_ALLOW_PRIVATE=1
    #   HARNESS_EGRESS_HOSTS=localhost,127.0.0.1
    EGRESS_OPTIONS = {
      allow_http: ENV["HARNESS_EGRESS_ALLOW_HTTP"].to_s == "1",
      allow_private: ENV["HARNESS_EGRESS_ALLOW_PRIVATE"].to_s == "1",
      host_allowlist: ENV["HARNESS_EGRESS_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?).then { |l| l.empty? ? nil : l }
    }.compact
    TOOL_REGISTRY = Harness::OverlayToolRegistry.new(
      base: REGISTRY, tool_store: TOOL_STORE, http: Harness::HttpClient.new,
      event_stream: EVENT_STREAM, egress_options: EGRESS_OPTIONS
    )
    TOOL_CATALOG  = Harness::ToolCatalog.new(tool_registry: TOOL_REGISTRY)

    # General settings + LLM providers authorable at runtime: durable in the same
    # backend. The LLMConfigurator re-applies the providers to
    # RubyLLM without a restart (per-provider key/base). Seed: the deepseek provider
    # from boot already lives in the global config (RubyLLM.configure above) — the store is the
    # editable source from here on.
    SETTINGS_STORE    = Harness::SettingsStore.new(config_store: CONFIG_STORE)
    LLM_PROVIDER_STORE = Harness::LLMProviderStore.new(config_store: CONFIG_STORE)
    LLM_CONFIGURATOR  = Harness::LLMConfigurator.new(provider_store: LLM_PROVIDER_STORE)

    # MCP + global system files. MCP instances with
    # masked credentials (durable config); system files apply to
    # ALL agents (injected by the Prompt provider before the identity).
    MCP_STORE          = Harness::McpStore.new(config_store: CONFIG_STORE)
    SYSTEM_FILE_STORE  = Harness::SystemFileStore.new(config_store: CONFIG_STORE)

    # Catalogs with a Store overlay: disk = seed,
    # Store = authored (wins). reload makes edits hot (no restart).
    CATALOG        = Harness::SkillCatalog.new([File.join(Deploy::ROOT, "deploy", "skills")], store: SKILL_STORE)
    PROMPT_CATALOG = Harness::PromptCatalog.new([])

    HOOKS      = Harness::Hooks.new
    MIDDLEWARE = Harness::MiddlewareStack.new([])

    # OpenClaw-style prompts become the IDENTITY (pinned) via the Prompt provider.
    # IDENTITY_FILES is the deployment DEFAULT (used by an agent WITHOUT its
    # own prompt_files). An agent with `profile.prompt_files` reads its
    # content from the AGENT_FILE_STORE (its own identity), not these — resolving
    # the inheritance of Bia's prompt by new agents.
    IDENTITY_FILES = %w[IDENTITY.md SOUL.md TOOLS.md].map { |f| File.join(Deploy::AGENT_DIR, f) }

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: IDENTITY_FILES, catalog: PROMPT_CATALOG, agent_files: AGENT_FILE_STORE, system_files: SYSTEM_FILE_STORE),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      Harness::Context::Providers::Memory.new(store: MEMORY_STORE),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze
    CONTEXT_BUILDER = Harness::ContextBuilder.new(providers: CONTEXT_PROVIDERS, event_stream: EVENT_STREAM, hooks: HOOKS)
    POLICY_ENGINE   = Harness::Policy::Engine.new(policy_registry: POLICY_REGISTRY, event_stream: EVENT_STREAM)

    # DYNAMIC profiles: persisted in the ConfigStore (defined
    # above), editable at runtime by the Studio (create/update/delete_agent). No
    # longer a frozen Hash — the Executor and the turn Commands resolve at
    # dispatch.
    PROFILE_SOURCE = Harness::StoredProfileSource.new(config_store: CONFIG_STORE)

    # Bia agent seed (idempotent): only creates if it doesn't exist yet. In Memory
    # it re-seeds every boot; in SQLite it persists and the owner can create other BIAs.
    unless PROFILE_SOURCE.fetch("bia")
      PROFILE_SOURCE.put(Harness::AgentProfile.build(
                           id: "bia", model: Deploy::MODEL, provider: :deepseek,
                           tools_allow: %w[menu calc current_time], skills: %w[pedido],
                           policies: %i[tool_allowlist skill_allowlist], memory: true,
                           limits: { tool_timeout: Integer(ENV.fetch("TOOL_TIMEOUT", "30")),
                                     turn_timeout: Integer(ENV.fetch("TURN_TIMEOUT", "120")) }
                         ))
    end

    EXECUTOR = Harness::Executor.new(
      context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE, middleware: MIDDLEWARE, hooks: HOOKS,
      tool_registry: TOOL_REGISTRY, skill_catalog: CATALOG, profiles: PROFILE_SOURCE,
      session_store: SESSION_STORE, task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE,
      event_stream: EVENT_STREAM, workflow_registry: WORKFLOW_REGISTRY,
      pending_action_store: PENDING_ACTION_STORE, capability_registry: CAPABILITY_REGISTRY,
      tool_catalog: TOOL_CATALOG, memory_store: MEMORY_STORE, tool_trace_store: TOOL_TRACE_STORE
    )

    BUS = Harness::CommandBus.new
    BUS.register(:create_session, Harness::Commands::CreateSession.new(session_store: SESSION_STORE, event_stream: EVENT_STREAM))
    BUS.register(:send_message, Harness::Commands::SendMessage.new(profiles: PROFILE_SOURCE, session_store: SESSION_STORE, task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:resume_task, Harness::Commands::ResumeTask.new(profiles: PROFILE_SOURCE, task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, executor: EXECUTOR))

    # Runtime agent authoring — the "everyone creates their own BIA".
    BUS.register(:create_agent, Harness::Commands::CreateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:update_agent, Harness::Commands::UpdateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent, Harness::Commands::DeleteAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:set_agent_tools, Harness::Commands::SetAgentTools.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Per-agent prompts/skills — "everyone creates their own BIA with
    # its own identity". Content in the Store, hot via reload/ProfileSource.
    BUS.register(:write_agent_file, Harness::Commands::WriteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent_file, Harness::Commands::DeleteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_agent_file, Harness::Commands::RestoreAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:write_skill, Harness::Commands::WriteSkill.new(skill_store: SKILL_STORE, skill_catalog: CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:set_skill_agents, Harness::Commands::SetSkillAgents.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Memory + settings + LLM — memory becomes editable over HTTP
    # (not only via the `remember` tool); settings and providers gain durable CRUD.
    BUS.register(:memory_put_fact, Harness::Commands::MemoryPutFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:memory_forget_fact, Harness::Commands::MemoryForgetFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:memory_add_note, Harness::Commands::MemoryAddNote.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:update_settings, Harness::Commands::UpdateSettings.new(settings_store: SETTINGS_STORE, event_stream: EVENT_STREAM))
    BUS.register(:upsert_llm_provider, Harness::Commands::UpsertLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))
    BUS.register(:delete_llm_provider, Harness::Commands::DeleteLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))

    # MCP + system files: CRUD of MCP instances and of the
    # global files that apply to all agents.
    BUS.register(:upsert_mcp, Harness::Commands::UpsertMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_mcp, Harness::Commands::DeleteMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    BUS.register(:write_system_file, Harness::Commands::WriteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_system_file, Harness::Commands::DeleteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_system_file, Harness::Commands::RestoreSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))

    # Data-defined tools (Phase 5): authoring without code. registry = overlay (hot reload);
    # tool_catalog reloads level-1/tool_search. Secrets masked in the store.
    BUS.register(:write_data_tool, Harness::Commands::WriteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:delete_data_tool, Harness::Commands::DeleteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:restore_data_tool, Harness::Commands::RestoreDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))

    # BATCH ingestion via manifest (Phase 7, Step B): upsert of the data-tools in a
    # standard format (JSON Schema) + declarative binding, hot (no restart). The
    # manifest's `{{secret.*}}`/`{{env.*}}` resolve from the DEPLOYMENT's ENV (the
    # secret never comes in the manifest — D6/R3); the placeholder key is the name of the
    # env var (e.g.: {{secret.BIA_INTERNAL_API_TOKEN}}, {{env.CONSUMER_INTERNAL_URL}}).
    IMPORT_TOOLS = Harness::Commands::ImportTools.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM, secrets: ENV, env: ENV)
    BUS.register(:import_tools, IMPORT_TOOLS)

    # LIVE MCP ingestion (Phase 7, Step E / D8): discovers the tools of an MCP
    # instance at runtime (no manifest) and REUSES :import_tools (upsert + hot reload).
    # The MCP client is INJECTABLE (client_factory): default = a minimal HTTP JSON-RPC
    # client behind the egress guard (same EGRESS_OPTIONS as the data-tools). The tools
    # get group `mcp:<instance>` for Step C's group gating. The REAL MCP
    # transport (stdio, session/initialize, tools/call unwrap) is later work.
    MCP_TOOL_INGESTOR = Harness::McpToolIngestor.new(
      mcp_store: MCP_STORE, import_tools: IMPORT_TOOLS,
      client_factory: ->(record) { Harness::McpHttpClient.new(url: record["url"], egress_options: EGRESS_OPTIONS) }
    )
    BUS.register(:import_mcp_tools, Harness::Commands::ImportMcpTools.new(ingestor: MCP_TOOL_INGESTOR, event_stream: EVENT_STREAM))

    # Pack provisioning (Phase 6/D4): imports an agent from a standardized
    # pack by emitting the Commands above. Consumes the bus + READS the ProfileSource
    # (upsert). It's what the provisioning API (the GatewayClient) triggers.
    PACK_IMPORTER = Harness::PackImporter.new(bus: BUS, profiles: PROFILE_SOURCE)

    # OPT-IN observability (Phase 6): OTEL only turns on with HARNESS_OTEL / OTEL envs.
    # nil = off (parity, gem not even loaded). Turned on in the reactor via
    # Telemetry.attach (serving arm) — consumes the EVENT_STREAM into spans.
    TELEMETRY = Harness::Telemetry.setup(service_name: ENV.fetch("OTEL_SERVICE_NAME", "harness"))

    def self.stores = { session: SESSION_STORE, task: TASK_STORE, checkpoint: CHECKPOINT_STORE, pending: PENDING_ACTION_STORE, memory: MEMORY_STORE }
  end
end
