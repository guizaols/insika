# frozen_string_literal: true

# The MINIMAL composition root: assembles the smallest graph needed for `APP` to
# serve — Memory (or SQLite) backend, empty catalogs/registries and empty `PROFILES`
# (a concrete deployment — config/deployment.rb — or the smoke wiring fills in real
# profiles and tools). Requiring this file does NOT load `ruby_llm`: the Executor
# only touches the gem lazily at stage 6.
#
# The shared spine + Executor + core Command Bus come from Harness::Wiring::Graph
# (§12 G4); this file only layers on the base-only pieces: workflow triggering, the
# A2A edges, the APP, and Boot's named steps.
#
# The global constants (REGISTRY, CATALOG, PROFILES, ...) are kept as a read
# SHORTCUT, but nothing depends on them for testing (the classes accept injection).

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

    # --- Shared spine + graph (Harness::Wiring::Graph) ------------
    # HARNESS_DB set -> durable SQLite (survives kill -9 + reboot, the phase's
    # criterion); missing -> ephemeral Memory. Production MUST set HARNESS_DB for
    # Recovery to have something to resume. Memory/SQLite parity is in the contract
    # suite. The minimal wiring ALSO registers :workflow_allowlist (workflows are a
    # base capability; the deployment does not expose them).
    BACKEND = Graph.backend_from_env
    SPINE   = Graph.spine(
      backend: BACKEND,
      extra_policy_builtins: { workflow_allowlist: Harness::Policy::Builtin::WorkflowAllowlist }
    )

    # Promote the spine to the historic public constants (read shortcuts).
    EVENT_STREAM         = SPINE.event_stream
    SESSION_STORE        = SPINE.session_store
    TASK_STORE           = SPINE.task_store
    CHECKPOINT_STORE     = SPINE.checkpoint_store
    PENDING_ACTION_STORE = SPINE.pending_action_store
    MEMORY_STORE         = SPINE.memory_store
    REGISTRY             = SPINE.code_tool_registry
    WORKFLOW_REGISTRY    = SPINE.workflow_registry
    POLICY_REGISTRY      = SPINE.policy_registry
    CAPABILITY_REGISTRY  = SPINE.capability_registry
    HOOKS                = SPINE.hooks

    # ToolCatalog reads metadata from the already-built REGISTRY. Catalogs point at
    # the workspace skills/prompts roots (empty if absent).
    TOOL_CATALOG   = Harness::ToolCatalog.new(tool_registry: REGISTRY)
    CATALOG        = Harness::SkillCatalog.new([File.join(ROOT, "skills")])
    PROMPT_CATALOG = Harness::PromptCatalog.new([File.join(ROOT, "prompts")])

    # Guardrails / content safety (RFC-0009). No SettingsStore in the minimal wiring,
    # so the LLM moderator only runs for an agent that pins its own `guardrails.
    # moderator` model ref; the deterministic net (input scan + output redaction) is
    # always on for agents that opt in. See config/deployment.rb for the full graph.
    GUARDRAILS = Harness::Safety::Factory.new

    # Production edge (item 33). No SettingsStore at the base, so only an agent
    # that carries its own limits (chat_rate_limit / agent_token_ceiling) is
    # limited; without them the link is pass-through (parity).
    EDGE_LIMITER = Harness::EdgeLimiter.new(ledger: Harness::UsageLedger.new(store: BACKEND))

    # Agent profiles (data-driven). EMPTY at the base — a concrete deployment (or the
    # smoke wiring) registers the profiles.
    PROFILES = {}.freeze

    CONTEXT_PROVIDERS = [
      Harness::Context::Providers::Request.new,
      Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
      Harness::Context::Providers::Skill.new(catalog: CATALOG),
      # Level-1 Tool Search: emits <available_tools> from profile.tools_deferred.
      # Inert for agents without tools_deferred (returns []).
      Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
      # Cross-session memory: read path. Inert for agents without `memory`.
      Harness::Context::Providers::Memory.new(store: MEMORY_STORE),
      Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
    ].freeze

    GRAPH = Graph.build(
      spine: SPINE, profiles: PROFILES,
      tool_registry: REGISTRY, tool_catalog: TOOL_CATALOG,
      skill_catalog: CATALOG, prompt_catalog: PROMPT_CATALOG,
      guardrails: GUARDRAILS, context_providers: CONTEXT_PROVIDERS,
      edge_limiter: EDGE_LIMITER
    )

    CONTEXT_BUILDER = GRAPH.context_builder
    POLICY_ENGINE   = GRAPH.policy_engine
    MIDDLEWARE      = GRAPH.middleware
    EXECUTOR        = GRAPH.executor
    # The bus already carries the 6 core commands (incl. pause_task/approve_action).
    BUS             = GRAPH.bus

    # Base-only: workflow triggering (the deployment does not expose workflows).
    BUS.register(:trigger_workflow,
                 Harness::Commands::TriggerWorkflow.new(profiles: PROFILES,
                                                        session_store: SESSION_STORE,
                                                        task_store: TASK_STORE, executor: EXECUTOR,
                                                        workflow_registry: WORKFLOW_REGISTRY))

    # --- Transport --------------------------------------------------
    CONFIG = {
      bind: ENV.fetch("HARNESS_BIND", "http://0.0.0.0"),
      port: Integer(ENV.fetch("HARNESS_PORT", "9292"))
    }.freeze

    # --- A2A edge — inbound federation, OPT-IN -------------
    # Exposed only when HARNESS_A2A_AGENT points to an existing profile (PROFILES is
    # empty at the base). Without the env / a missing agent -> nil -> no A2A routes.
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
          description: remote.description || "Delegates the task to the remote A2A agent '#{remote.id}'.",
          event_stream: EVENT_STREAM
        )
      end
    end

    APP = Harness::Server::App.new(
      command_bus: BUS, event_stream: EVENT_STREAM,
      session_store: SESSION_STORE, task_store: TASK_STORE,
      pending_action_store: PENDING_ACTION_STORE, # read for GET /v1/tasks/:id
      a2a: A2A_APP, # nil at the base (opt-in) -> A2A routes respond 404
      config: CONFIG
    )

    # Boot recovery: discovers interrupted tasks and resumes them through the SAME
    # path as ResumeTask, BEFORE the server accepts requests.
    RECOVERY = Harness::Recovery.new(
      task_store: TASK_STORE, checkpoint_store: CHECKPOINT_STORE, command_bus: BUS
    )

    # Named steps consumed by Server::Boot. The graph above is built EAGERLY at
    # require (shortcut constants); the steps expose the SEQUENCE Boot orchestrates.
    # `load_plugins`/`build_stores` are no-ops at the base — the "recovery before the
    # listen" guarantee comes from `recovery.run` running inside Boot, before `run APP`.
    # NB: when this no-op becomes a real Harness::Plugin::Loader.new, the registries
    # hash MUST include `capabilities: CAPABILITY_REGISTRY` — the missing key is safe
    # (the loader ignores capabilities), but without it no plugin can register one.
    def self.load_plugins = nil
    def self.build_stores = nil
    def self.recovery = RECOVERY
    # RFC-0010 Fase 2: re-deliver async delegations whose child finished but whose
    # result was not delivered before a crash. Boot calls it after task recovery.
    def self.recover_delegations = EXECUTOR.recover_delegations
    def self.app = APP

    # Backend durability: SQLite survives restart, Memory does not. Boot logs this so
    # the operator doesn't come up without durability by mistake (HARNESS_DB not set).
    def self.durable? = BACKEND.is_a?(Harness::Stores::SQLite)
  end
end

# Global shortcuts: `APP` and the constants stay accessible at the top. `config.ru`
# -> `Server::Boot` consumes `WIRING`.
APP = Harness::Wiring::APP
WIRING = Harness::Wiring
