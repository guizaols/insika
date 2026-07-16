# frozen_string_literal: true

# Deployment CONCRETO de demo — "rodar de verdade" (sem mocks): DeepSeek real +
# 1 agente (Bia) com prompts no padrão OpenClaw + tools/skills reais + memória.
# Constrói o mesmo grafo do config/wiring.rb, mas com PROFILES/tools reais.
#
# Uso: DEEPSEEK_API_KEY=... ruby -r ./config/deployment (ou via scripts/run_real.rb).

require_relative "../lib/harness"
require "ruby_llm"
require_relative "../deploy/tools"

module Deploy
  DEEPSEEK_KEY = ENV["DEEPSEEK_API_KEY"].to_s
  raise "DEEPSEEK_API_KEY ausente (exporte a chave do openclaw/.env.local)" if DEEPSEEK_KEY.empty?

  # LLM REAL (mesmo modelo da produção OpenClaw).
  RubyLLM.configure do |c|
    c.deepseek_api_key = DEEPSEEK_KEY
    c.deepseek_api_base = "https://api.deepseek.com/v1"
    c.request_timeout = 120
    c.max_retries = 2
  end

  MODEL = ENV.fetch("DEEPSEEK_MODEL", "deepseek-chat") # v4-flash = "deepseek-chat" na API
  ROOT  = File.expand_path("..", __dir__)
  AGENT_DIR = File.join(ROOT, "deploy", "agents", "bia")

  module Wiring
    # Backend durável-aware: HARNESS_DB -> SQLite (config + execução
    # sobrevivem a restart — single-tenant em produção roda em SQLite com volume);
    # ausente -> Memory (dev/demo). O mesmo backend guarda execução E configuração.
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

    # Tools REAIS (factory por bloco — instância nova por turno).
    Deploy::Tools::ALL.each { |name, klass| REGISTRY.register(name, plugin: "pizzaria") { klass.new } }

    CAPABILITY_REGISTRY = Harness::CapabilityRegistry.new

    # Config durável: profiles + workspace de prompts + skills
    # autoradas vivem AQUI (SQLite quando HARNESS_DB; senão Memory efêmero).
    CONFIG_STORE      = Harness::ConfigStore.new(store: BACKEND)
    AGENT_FILE_STORE  = Harness::AgentFileStore.new(config_store: CONFIG_STORE)
    SKILL_STORE       = Harness::SkillStore.new(config_store: CONFIG_STORE)

    # Tools POR DADOS (Fase 5): definições no ToolStore; o overlay compõe as tools
    # de CÓDIGO (REGISTRY) com as por-dados. É o `tool_registry` do Executor e do
    # ToolCatalog (drop-in) — data-tools novas valem sem restart via reload.
    TOOL_STORE    = Harness::ToolStore.new(config_store: CONFIG_STORE)
    # Egress das data-tools (SSRF guard). Default = estrito (só https público).
    # Para o motor CHAMAR DE VOLTA a API interna do consumidor (achei-b2b
    # /api/internal/*), que é http/loopback no local, ligue via env — de
    # preferência PARANDO num host conhecido (NF4):
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

    # Settings gerais + providers de LLM autoráveis em runtime: durável no mesmo
    # backend. O LLMConfigurator reaplica os providers no
    # RubyLLM sem restart (chave/base por-provider). Semente: o provider deepseek
    # do boot já vive na config global (RubyLLM.configure acima) — o store é a
    # fonte editável daqui pra frente.
    SETTINGS_STORE    = Harness::SettingsStore.new(config_store: CONFIG_STORE)
    LLM_PROVIDER_STORE = Harness::LLMProviderStore.new(config_store: CONFIG_STORE)
    LLM_CONFIGURATOR  = Harness::LLMConfigurator.new(provider_store: LLM_PROVIDER_STORE)

    # MCP + arquivos de sistema globais. Instâncias MCP com
    # credenciais mascaradas (config durável); arquivos de sistema valem para
    # TODOS os agentes (injetados pelo Prompt provider antes da identidade).
    MCP_STORE          = Harness::McpStore.new(config_store: CONFIG_STORE)
    SYSTEM_FILE_STORE  = Harness::SystemFileStore.new(config_store: CONFIG_STORE)

    # Catálogos com overlay do Store: disco = seed,
    # Store = autorado (vence). reload torna edições hot (sem restart).
    CATALOG        = Harness::SkillCatalog.new([File.join(Deploy::ROOT, "deploy", "skills")], store: SKILL_STORE)
    PROMPT_CATALOG = Harness::PromptCatalog.new([])

    HOOKS      = Harness::Hooks.new
    MIDDLEWARE = Harness::MiddlewareStack.new([])

    # Prompts padrão OpenClaw viram a IDENTIDADE (pinned) via o Prompt provider.
    # IDENTITY_FILES é o DEFAULT de deployment (usado por um agente SEM
    # prompt_files próprios). Um agente com `profile.prompt_files` lê o
    # conteúdo do AGENT_FILE_STORE (identidade própria), não estes — resolvendo a
    # herança do prompt da Bia por agentes novos.
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

    # Profiles DINÂMICOS: persistidos no ConfigStore (definido
    # acima), editáveis em runtime pelo Studio (create/update/delete_agent). Não
    # é mais um Hash congelado — o Executor e os Commands de turno resolvem no
    # dispatch.
    PROFILE_SOURCE = Harness::StoredProfileSource.new(config_store: CONFIG_STORE)

    # Seed do agente Bia (idempotente): só cria se ainda não existe. Em Memory
    # re-semeia a cada boot; em SQLite persiste e o dono pode criar outras BIAs.
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
      tool_catalog: TOOL_CATALOG, memory_store: MEMORY_STORE
    )

    BUS = Harness::CommandBus.new
    BUS.register(:create_session, Harness::Commands::CreateSession.new(session_store: SESSION_STORE, event_stream: EVENT_STREAM))
    BUS.register(:send_message, Harness::Commands::SendMessage.new(profiles: PROFILE_SOURCE, session_store: SESSION_STORE, task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:resume_task, Harness::Commands::ResumeTask.new(profiles: PROFILE_SOURCE, task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, executor: EXECUTOR))

    # Autoria de agente em runtime — o "cada um cria sua BIA".
    BUS.register(:create_agent, Harness::Commands::CreateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:update_agent, Harness::Commands::UpdateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent, Harness::Commands::DeleteAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:set_agent_tools, Harness::Commands::SetAgentTools.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Prompts/skills por-agente — "cada um cria sua BIA com
    # identidade própria". Conteúdo no Store, hot via reload/ProfileSource.
    BUS.register(:write_agent_file, Harness::Commands::WriteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent_file, Harness::Commands::DeleteAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_agent_file, Harness::Commands::RestoreAgentFile.new(profile_source: PROFILE_SOURCE, agent_file_store: AGENT_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:write_skill, Harness::Commands::WriteSkill.new(skill_store: SKILL_STORE, skill_catalog: CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:set_skill_agents, Harness::Commands::SetSkillAgents.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    # Memória + settings + LLM — a memória vira editável por HTTP
    # (não só via tool `remember`); settings e providers ganham CRUD durável.
    BUS.register(:memory_put_fact, Harness::Commands::MemoryPutFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:memory_forget_fact, Harness::Commands::MemoryForgetFact.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:memory_add_note, Harness::Commands::MemoryAddNote.new(memory_store: MEMORY_STORE, event_stream: EVENT_STREAM))
    BUS.register(:update_settings, Harness::Commands::UpdateSettings.new(settings_store: SETTINGS_STORE, event_stream: EVENT_STREAM))
    BUS.register(:upsert_llm_provider, Harness::Commands::UpsertLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))
    BUS.register(:delete_llm_provider, Harness::Commands::DeleteLLMProvider.new(provider_store: LLM_PROVIDER_STORE, configurator: LLM_CONFIGURATOR, event_stream: EVENT_STREAM))

    # MCP + arquivos de sistema: CRUD de instâncias MCP e dos
    # arquivos globais que valem para todos os agentes.
    BUS.register(:upsert_mcp, Harness::Commands::UpsertMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_mcp, Harness::Commands::DeleteMcp.new(mcp_store: MCP_STORE, event_stream: EVENT_STREAM))
    BUS.register(:write_system_file, Harness::Commands::WriteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:delete_system_file, Harness::Commands::DeleteSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))
    BUS.register(:restore_system_file, Harness::Commands::RestoreSystemFile.new(system_file_store: SYSTEM_FILE_STORE, event_stream: EVENT_STREAM))

    # Tools por dados (Fase 5): autoria sem código. registry = overlay (reload hot);
    # tool_catalog recarrega o nível-1/tool_search. Segredos mascarados no store.
    BUS.register(:write_data_tool, Harness::Commands::WriteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:delete_data_tool, Harness::Commands::DeleteDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))
    BUS.register(:restore_data_tool, Harness::Commands::RestoreDataTool.new(tool_store: TOOL_STORE, registry: TOOL_REGISTRY, tool_catalog: TOOL_CATALOG, event_stream: EVENT_STREAM))

    # Provisionamento por pack (Fase 6/D4): importa um agente a partir de um pack
    # padronizado emitindo os Commands acima. Consome o bus + LÊ o ProfileSource
    # (upsert). É o que a API de provisionamento (o GatewayClient) aciona.
    PACK_IMPORTER = Harness::PackImporter.new(bus: BUS, profiles: PROFILE_SOURCE)

    # Observabilidade OPT-IN (Fase 6): OTEL só liga com HARNESS_OTEL / envs OTEL.
    # nil = desligado (paridade, gem nem carregada). Ligado no reactor via
    # Telemetry.attach (arm de serving) — consome o EVENT_STREAM em spans.
    TELEMETRY = Harness::Telemetry.setup(service_name: ENV.fetch("OTEL_SERVICE_NAME", "harness"))

    def self.stores = { session: SESSION_STORE, task: TASK_STORE, checkpoint: CHECKPOINT_STORE, pending: PENDING_ACTION_STORE, memory: MEMORY_STORE }
  end
end
