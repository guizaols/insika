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
    # Backend durável-aware (Fase 4): HARNESS_DB -> SQLite (config + execução
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
    TOOL_CATALOG        = Harness::ToolCatalog.new(tool_registry: REGISTRY)
    CATALOG        = Harness::SkillCatalog.new([File.join(Deploy::ROOT, "deploy", "skills")])
    PROMPT_CATALOG = Harness::PromptCatalog.new([])

    HOOKS      = Harness::Hooks.new
    MIDDLEWARE = Harness::MiddlewareStack.new([])

    # Prompts padrão OpenClaw viram a IDENTIDADE (pinned) via o Prompt provider.
    # NB (achado ao rodar): o Prompt provider lê os `files:` do WIRING, não
    # `profile.prompt_files` — ok p/ 1 agente; multi-agente exige o provider ler
    # do profile (enhancement pequeno em context/providers/prompt.rb).
    IDENTITY_FILES = %w[IDENTITY.md SOUL.md TOOLS.md].map { |f| File.join(Deploy::AGENT_DIR, f) }

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: IDENTITY_FILES, catalog: PROMPT_CATALOG),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      Harness::Context::Providers::Memory.new(store: MEMORY_STORE),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze
    CONTEXT_BUILDER = Harness::ContextBuilder.new(providers: CONTEXT_PROVIDERS, event_stream: EVENT_STREAM, hooks: HOOKS)
    POLICY_ENGINE   = Harness::Policy::Engine.new(policy_registry: POLICY_REGISTRY, event_stream: EVENT_STREAM)

    # Profiles DINÂMICOS (Fase 4 D2): persistidos no ConfigStore, editáveis em
    # runtime pelo Studio (create/update/delete_agent). Não é mais um Hash
    # congelado — o Executor e os Commands de turno resolvem no dispatch.
    CONFIG_STORE   = Harness::ConfigStore.new(store: BACKEND)
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
      tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILE_SOURCE,
      session_store: SESSION_STORE, task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE,
      event_stream: EVENT_STREAM, workflow_registry: WORKFLOW_REGISTRY,
      pending_action_store: PENDING_ACTION_STORE, capability_registry: CAPABILITY_REGISTRY,
      tool_catalog: TOOL_CATALOG, memory_store: MEMORY_STORE
    )

    BUS = Harness::CommandBus.new(event_stream: EVENT_STREAM)
    BUS.register(:create_session, Harness::Commands::CreateSession.new(session_store: SESSION_STORE, event_stream: EVENT_STREAM))
    BUS.register(:send_message, Harness::Commands::SendMessage.new(profiles: PROFILE_SOURCE, session_store: SESSION_STORE, task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:resume_task, Harness::Commands::ResumeTask.new(profiles: PROFILE_SOURCE, task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, executor: EXECUTOR))

    # Autoria de agente em runtime (Fase 4 Etapa B) — o "cada um cria sua BIA".
    BUS.register(:create_agent, Harness::Commands::CreateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:update_agent, Harness::Commands::UpdateAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:delete_agent, Harness::Commands::DeleteAgent.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))
    BUS.register(:set_agent_tools, Harness::Commands::SetAgentTools.new(profile_source: PROFILE_SOURCE, event_stream: EVENT_STREAM))

    def self.stores = { session: SESSION_STORE, task: TASK_STORE, checkpoint: CHECKPOINT_STORE, pending: PENDING_ACTION_STORE, memory: MEMORY_STORE }
  end
end
