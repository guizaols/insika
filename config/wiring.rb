# frozen_string_literal: true

# The SINGLE composition root: the place where the
# dependencies are built and injected. `APP` is born by injection
# — the global constants (REGISTRY, CATALOG, PROFILES, ...) are kept as a
# read SHORTCUT, but nothing depends on them for testing (the class accepts
# injection).
#
# Here it assembles the minimal graph needed for `APP` to serve: Memory backend,
# empty catalogs/registries and empty `PROFILES` (a concrete deployment — or the
# smoke test wiring — fills in profiles and tools). Requiring this file does NOT
# load `ruby_llm`: the Executor only touches the gem lazily at stage 6.

require_relative "../lib/harness"
require_relative "../server/app"
# A2A outbound: client/http/remotes do NOT pull ruby_llm at load (only the remote
# tool's registration block pulls it). The tool itself (a2a_remote.rb) is lazy.
require_relative "../server/a2a/client"
require_relative "../server/a2a/http"
require_relative "../server/a2a/remotes"

module Harness
  module Wiring
    ROOT = File.expand_path("..", __dir__)

    # --- Persistence. Backend by CONFIG:
    # HARNESS_DB set -> Stores::SQLite (durable — survives kill -9 +
    # reboot, which is the phase's criterion); missing -> Stores::Memory
    # (dev/ephemeral). Production MUST set HARNESS_DB for Recovery to have something to
    # resume. Memory/SQLite parity is guaranteed by the contract suite.
    BACKEND =
      if (db_path = ENV["HARNESS_DB"]) && !db_path.empty?
        Harness::Stores::SQLite.new(path: db_path)
      else
        Harness::Stores::Memory.new
      end

    SESSION_STORE    = Harness::SessionStore.new(store: BACKEND)
    TASK_STORE       = Harness::TaskStore.new(store: BACKEND)
    CHECKPOINT_STORE = Harness::CheckpointStore.new(store: BACKEND)
    PENDING_ACTION_STORE = Harness::PendingActionStore.new(store: BACKEND)

    # --- Event Stream + registries/catalogs ----------------------
    EVENT_STREAM = Harness::EventStream.new

    REGISTRY          = Harness::ToolRegistry.new
    WORKFLOW_REGISTRY = Harness::WorkflowRegistry.new
    POLICY_REGISTRY   = Harness::PolicyRegistry.new

    # Stage 3 builtins: registered AT BOOT by the composition
    # root, not by the registry. Consumed via `fetch(name)`.
    POLICY_REGISTRY.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
    POLICY_REGISTRY.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
    POLICY_REGISTRY.register(:workflow_allowlist, Harness::Policy::Builtin::WorkflowAllowlist)
    POLICY_REGISTRY.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)

    # --- Capability Registry + Tool Catalog ----------
    # CapabilityRegistry is INDIRECTION: it holds Providers, resolves to the impl_name
    # that the REGISTRY instantiates. Zero execution here. ToolCatalog reads metadata from the
    # already-built REGISTRY (same pattern as SkillCatalog over skills/).
    CAPABILITY_REGISTRY = Harness::CapabilityRegistry.new
    TOOL_CATALOG        = Harness::ToolCatalog.new(tool_registry: REGISTRY)

    # --- Cross-session memory over the durable BACKEND ------
    # SQLite when HARNESS_DB is set (memory survives restart); ephemeral Memory
    # in dev. Domain store (≠ Stores::Memory backend).
    MEMORY_STORE = Harness::MemoryStore.new(store: BACKEND)

    # Catalogs: workspace skills/prompts roots (empty if absent).
    CATALOG        = Harness::SkillCatalog.new([File.join(ROOT, "skills")])
    PROMPT_CATALOG = Harness::PromptCatalog.new([File.join(ROOT, "prompts")])

    # --- Cross-cutting stages ------------------------------------
    HOOKS      = Harness::Hooks.new
    MIDDLEWARE = Harness::MiddlewareStack.new([])

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      # Level-1 Tool Search: emits <available_tools> from
      # profile.tools_deferred. Inert for agents without tools_deferred (returns []).
      Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      # Cross-session memory: read path. Inert for agents without
      # `memory` (enabled_for? cuts by profile; empty store -> []).
      Harness::Context::Providers::Memory.new(store: MEMORY_STORE),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze

    CONTEXT_BUILDER = Harness::ContextBuilder.new(
      providers: CONTEXT_PROVIDERS, event_stream: EVENT_STREAM, hooks: HOOKS
    )

    POLICY_ENGINE = Harness::Policy::Engine.new(
      policy_registry: POLICY_REGISTRY, event_stream: EVENT_STREAM
    )

    # Agent profiles (data-driven). EMPTY at the base — a concrete
    # deployment (or the smoke test wiring) registers the profiles.
    PROFILES = {}.freeze

    # --- Execution ---------------------------------------------------
    EXECUTOR = Harness::Executor.new(
      context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
      middleware: MIDDLEWARE, hooks: HOOKS,
      tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
      workflow_registry: WORKFLOW_REGISTRY, pending_action_store: PENDING_ACTION_STORE,
      capability_registry: CAPABILITY_REGISTRY, tool_catalog: TOOL_CATALOG,
      memory_store: MEMORY_STORE
    )

    # --- Command Bus + handlers -------------------------------
    BUS = Harness::CommandBus.new
    BUS.register(:create_session,
                 Harness::Commands::CreateSession.new(session_store: SESSION_STORE,
                                                      event_stream: EVENT_STREAM))
    BUS.register(:cancel_task,
                 Harness::Commands::CancelTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:pause_task,
                 Harness::Commands::PauseTask.new(task_store: TASK_STORE, executor: EXECUTOR))
    BUS.register(:approve_action,
                 Harness::Commands::ApproveAction.new(pending_action_store: PENDING_ACTION_STORE,
                                                      executor: EXECUTOR, event_stream: EVENT_STREAM))
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

    # --- Transport --------------------------------------------------
    CONFIG = {
      bind: ENV.fetch("HARNESS_BIND", "http://0.0.0.0"),
      port: Integer(ENV.fetch("HARNESS_PORT", "9292")),
      admin_token: ENV["HARNESS_ADMIN_TOKEN"], # fail-closed: no token -> /admin 503
      # Strict CORS: strip/reject avoids the footgun of "a.com, b.com" becoming " b.com"
      allowed_origins: ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    }.freeze

    # --- A2A edge — inbound federation, OPT-IN -------------
    # Exposed only when HARNESS_A2A_AGENT points to an existing profile (PROFILES is
    # empty at the base — real profiles/plugins are a concrete
    # deployment). Without the env / a missing agent -> nil -> server does not expose A2A.
    A2A_APP =
      if (a2a_agent = ENV["HARNESS_A2A_AGENT"]) && PROFILES[a2a_agent]
        Harness::Server::A2A::App.new(
          command_bus: BUS, task_store: TASK_STORE, session_store: SESSION_STORE,
          profiles: PROFILES, skill_catalog: CATALOG,
          config: { a2a_agent: a2a_agent,
                    base_url: ENV["HARNESS_PUBLIC_URL"] || "http://localhost:#{CONFIG[:port]}" }
        )
      end

    # --- A2A outbound — outbound federation, OPT-IN --------
    # The harness calls remote A2A agents as tools. One tool per remote from
    # HARNESS_A2A_REMOTES ("id=url,.."); without the env -> nothing registered (parity).
    # The gem's `require` lives IN THE BLOCK (loaded on the 1st instance, turn time
    # -> wiring-load stays gem-free).
    A2A_CLIENT = Harness::Server::A2A::Client.new(http: Harness::Server::A2A::Http.new)
    Harness::Server::A2A::Remotes.parse(ENV["HARNESS_A2A_REMOTES"].to_s).each do |remote|
      REGISTRY.register("remote_#{remote.id}", plugin: "a2a") do
        require "ruby_llm"
        require_relative "../lib/harness/tools/a2a_remote"
        Harness::Tools::A2ARemote.new(
          client: A2A_CLIENT, url: remote.url, tool_name: "remote_#{remote.id}",
          description: remote.description || "Delega a tarefa ao agente A2A remoto '#{remote.id}'.",
          event_stream: EVENT_STREAM
        )
      end
    end

    APP = Harness::Server::App.new(
      command_bus: BUS, event_stream: EVENT_STREAM,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      checkpoint_store: CHECKPOINT_STORE, # read for /admin/tasks/:id
      pending_action_store: PENDING_ACTION_STORE, # approvals in /admin + read
      catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
      registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
      a2a: A2A_APP, # nil at the base (opt-in) -> A2A routes respond 404
      config: CONFIG
    )

    # Boot recovery: discovers interrupted tasks and resumes them through the
    # SAME path as ResumeTask, BEFORE the server accepts requests.
    RECOVERY = Harness::Recovery.new(
      task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, command_bus: BUS
    )

    # Named steps consumed by Server::Boot. The graph above is
    # built EAGERLY at require (shortcut constants); the
    # steps expose the SEQUENCE that Boot orchestrates. `load_plugins`/
    # `build_stores` are no-ops at the base (no external plugins configured; a
    # concrete deployment or autodiscovery extends them) — the
    # "recovery before the listen" guarantee comes from `recovery.run` running inside Boot,
    # before `run APP`.
    # NB: when this no-op becomes a real Harness::Plugin::Loader.new, the
    # registries hash MUST include `capabilities: CAPABILITY_REGISTRY`
    # (contracts.capabilities) — the missing key is safe (the loader ignores
    # capabilities), but without it no plugin can register a capability.
    def self.load_plugins = nil
    def self.build_stores = nil
    def self.recovery = RECOVERY
    def self.app = APP

    # Backend durability: SQLite survives restart, Memory does
    # not. Boot logs this so the operator doesn't come up without durability by
    # mistake (HARNESS_DB not set).
    def self.durable? = BACKEND.is_a?(Harness::Stores::SQLite)
  end
end

# Global shortcuts: `APP` and the constants stay
# accessible at the top. `config.ru` -> `Server::Boot` consumes `WIRING`.
APP = Harness::Wiring::APP
WIRING = Harness::Wiring
