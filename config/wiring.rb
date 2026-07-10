# frozen_string_literal: true

# Composition root ÚNICO da Fase 1 (doc 07 §8, RFC-0001 §4): o lugar onde as
# dependências são construídas e injetadas. A `APP` (task 24) nasce por injeção
# — as constantes globais (REGISTRY, CATALOG, PROFILES, ...) são mantidas como
# ATALHO de leitura, mas nada depende delas para testar (a classe aceita
# injeção).
#
# NB (fronteira com a task 26): este arquivo será REFATORADO pela task 26 para
# expor passos nomeados (load_plugins/build_stores/recovery/app), plugar o
# `Server::Boot` e escolher o backend por config. Aqui ele monta o grafo mínimo
# necessário para a `APP` servir: backend Memory, catálogos/registries vazios e
# `PROFILES` vazio (um deployment concreto — ou o wiring de teste do smoke —
# preenche perfis e tools). Requerer este arquivo NÃO carrega `ruby_llm` (D9):
# o Executor só toca a gem lazy no estágio 6.

require_relative "../lib/harness"
require_relative "../server/app"

module Harness
  module Wiring
    ROOT = File.expand_path("..", __dir__)

    # --- Persistência (doc 01/02). Backend por CONFIG (doc 07 §4, task 26):
    # HARNESS_DB definido -> Stores::SQLite (durável — sobrevive a kill -9 +
    # reboot, que é o critério da fase, doc 00 §6); ausente -> Stores::Memory
    # (dev/efêmero). Produção DEVE definir HARNESS_DB para o Recovery ter o que
    # retomar. A paridade Memory/SQLite é garantida pela suíte de contrato (01).
    BACKEND =
      if (db_path = ENV["HARNESS_DB"]) && !db_path.empty?
        Harness::Stores::SQLite.new(path: db_path)
      else
        Harness::Stores::Memory.new
      end

    SESSION_STORE    = Harness::SessionStore.new(store: BACKEND)
    TASK_STORE       = Harness::TaskStore.new(store: BACKEND)
    CHECKPOINT_STORE = Harness::CheckpointStore.new(store: BACKEND)

    # --- Event Stream + registries/catalogs (doc 03/06) ----------------------
    EVENT_STREAM = Harness::EventStream.new

    REGISTRY          = Harness::ToolRegistry.new
    WORKFLOW_REGISTRY = Harness::WorkflowRegistry.new
    POLICY_REGISTRY   = Harness::PolicyRegistry.new

    # Builtins do estágio 3 (doc 05 §2): registrados NO BOOT pelo composition
    # root, não pelo registry (doc 05/06). Consumidos via `fetch(name)`.
    POLICY_REGISTRY.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
    POLICY_REGISTRY.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
    POLICY_REGISTRY.register(:workflow_allowlist, Harness::Policy::Builtin::WorkflowAllowlist)

    # Catálogos: roots de skills/prompts do workspace (vazios se ausentes; a
    # task 26 acrescenta os dirs dos plugins pela precedência do doc 06 §4).
    CATALOG        = Harness::SkillCatalog.new([File.join(ROOT, "skills")])
    PROMPT_CATALOG = Harness::PromptCatalog.new([File.join(ROOT, "prompts")])

    # --- Estágios transversais (doc 04/05) -----------------------------------
    HOOKS      = Harness::Hooks.new
    MIDDLEWARE = Harness::MiddlewareStack.new([])

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze

    CONTEXT_BUILDER = Harness::ContextBuilder.new(
      providers: CONTEXT_PROVIDERS, event_stream: EVENT_STREAM, hooks: HOOKS
    )

    POLICY_ENGINE = Harness::Policy::Engine.new(
      policy_registry: POLICY_REGISTRY, event_stream: EVENT_STREAM
    )

    # Perfis de agente (data-driven, D6). VAZIO na Fase 1 base — um deployment
    # concreto (ou o wiring de teste do smoke, task 26) registra os perfis.
    PROFILES = {}.freeze

    # --- Execução (doc 03) ----------------------------------------------------
    EXECUTOR = Harness::Executor.new(
      context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
      middleware: MIDDLEWARE, hooks: HOOKS,
      tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
      workflow_registry: WORKFLOW_REGISTRY
    )

    # --- Command Bus + handlers (doc 03 §2-§3) -------------------------------
    BUS = Harness::CommandBus.new(event_stream: EVENT_STREAM)
    BUS.register(:create_session,
                 Harness::Commands::CreateSession.new(session_store: SESSION_STORE,
                                                      event_stream: EVENT_STREAM))
    BUS.register(:cancel_task,
                 Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: PROFILES,
                                                    session_store: SESSION_STORE,
                                                    task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:resume_task,
                 Harness::Commands::ResumeTask.new(profiles: PROFILES, task_store: TASK_STORE,
                                                   checkpoint_store: CHECKPOINT_STORE,
                                                   executor: EXECUTOR))
    BUS.register(:trigger_workflow,
                 Harness::Commands::TriggerWorkflow.new(profiles: PROFILES,
                                                        session_store: SESSION_STORE,
                                                        task_store: TASK_STORE, executor: EXECUTOR,
                                                        workflow_registry: WORKFLOW_REGISTRY))

    # --- Transporte (task 24) -------------------------------------------------
    CONFIG = {
      bind: ENV.fetch("HARNESS_BIND", "http://0.0.0.0"),
      port: Integer(ENV.fetch("HARNESS_PORT", "9292")),
      admin_token: ENV["HARNESS_ADMIN_TOKEN"], # fail-closed: sem token -> /admin 503
      # CORS estrito: strip/reject evita footgun de "a.com, b.com" virar " b.com"
      allowed_origins: ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    }.freeze

    APP = Harness::Server::App.new(
      command_bus: BUS, event_stream: EVENT_STREAM,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, # leitura p/ /admin/tasks/:id
      catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
      registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
      config: CONFIG
    )

    # Recovery do boot (doc 02 §4): descobre tasks interrompidas e as retoma pelo
    # MESMO caminho do ResumeTask (D3), ANTES de o servidor aceitar requests.
    RECOVERY = Harness::Recovery.new(
      task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, command_bus: BUS
    )

    # Passos nomeados consumidos pelo Server::Boot (doc 07 §4). O grafo acima é
    # construído de forma EAGER no require (constantes-atalho da Fase 0); os
    # passos expõem a SEQUÊNCIA que o Boot orquestra. `load_plugins`/
    # `build_stores` são no-op na base (sem plugins externos configurados; um
    # deployment concreto ou a autodiscovery da task 22 os estende) — a garantia
    # "recovery antes do listen" vem de `recovery.run` rodar dentro do Boot,
    # antes de `run APP`.
    def self.load_plugins = nil
    def self.build_stores = nil
    def self.recovery = RECOVERY
    def self.app = APP

    # Durabilidade do backend (doc 02 §6): SQLite sobrevive a restart, Memory
    # não. O Boot loga isso para o operador não subir sem durabilidade por
    # engano (HARNESS_DB não definido).
    def self.durable? = BACKEND.is_a?(Harness::Stores::SQLite)
  end
end

# Atalhos globais (paridade Fase 0, doc 07 §8): a `APP` e as constantes seguem
# acessíveis no topo. A task 26 (`config.ru` -> `Server::Boot`) consome `WIRING`.
APP = Harness::Wiring::APP
WIRING = Harness::Wiring
