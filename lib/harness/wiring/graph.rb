# frozen_string_literal: true

module Harness
  module Wiring
    # SHARED composition core for both roots (§12 G4 / §11.2 B4): the minimal wiring
    # (config/wiring.rb) and the concrete deployment (config/deployment.rb) were two
    # near-identical composition roots. The duplication — backend→stores, event
    # stream, registries + policy builtins, capability registry, hooks, the Executor,
    # and the core Command Bus — lives here now; each root only layers on what
    # legitimately differs (profiles, plain-vs-overlay tool registry, catalogs,
    # guardrails config, context providers, and the root-specific bus commands).
    #
    # Two phases, no magic (a block would hit dynamic-constant assignment in the
    # roots, which promote everything to public constants):
    #   1. `spine(backend:)` — the parameter-free infra spine.
    #   2. `build(spine:, ...)` — assembles the Executor + Command Bus on top, given
    #      the root's divergent collaborators. This is where the 6 CORE commands
    #      (incl. pause_task/approve_action) are registered — which is what removes
    #      the config.ru / serve_real.rb patch that used to bolt them on afterwards.
    module Graph
      module_function

      # Backend by config: HARNESS_DB set → durable SQLite (survives restart, the
      # prerequisite for Recovery); missing → ephemeral Memory (dev/demo). The same
      # rule lived verbatim in both roots.
      def backend_from_env(env = ENV)
        db = env["HARNESS_DB"]
        db && !db.empty? ? Harness::Stores::SQLite.new(path: db) : Harness::Stores::Memory.new
      end

      # Phase 1 — the infra spine that is IDENTICAL across roots. `extra_policy_
      # builtins` covers the one real divergence (the minimal wiring also registers
      # :workflow_allowlist; the deployment does not expose workflows).
      def spine(backend:, extra_policy_builtins: {})
        session_store        = Harness::SessionStore.new(store: backend)
        task_store           = Harness::TaskStore.new(store: backend)
        checkpoint_store     = Harness::CheckpointStore.new(store: backend)
        pending_action_store = Harness::PendingActionStore.new(store: backend)
        memory_store         = Harness::MemoryStore.new(store: backend)

        code_tool_registry = Harness::ToolRegistry.new
        workflow_registry  = Harness::WorkflowRegistry.new

        policy_registry = Harness::PolicyRegistry.new
        policy_registry.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
        policy_registry.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
        policy_registry.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)
        extra_policy_builtins.each { |name, klass| policy_registry.register(name, klass) }

        Spine.new(
          backend: backend, event_stream: Harness::EventStream.new,
          session_store: session_store, task_store: task_store,
          checkpoint_store: checkpoint_store, pending_action_store: pending_action_store,
          memory_store: memory_store, code_tool_registry: code_tool_registry,
          workflow_registry: workflow_registry, policy_registry: policy_registry,
          capability_registry: Harness::CapabilityRegistry.new, hooks: Harness::Hooks.new
        )
      end

      # Phase 2 — assemble the graph on top of a spine.
      #
      # tool_registry:     effective registry the Executor uses (plain REGISTRY at the
      #                    base; OverlayToolRegistry in the deployment).
      # guardrails:        a Safety::Factory — its input_guardrail becomes the single
      #                    middleware and its output_validator the after-task hook, so
      #                    both wirings compose RFC-0009 identically.
      # executor_extra:    optional Executor kwargs a root adds (deployment passes
      #                    settings_store + tool_trace_store; the base passes none).
      def build(spine:, profiles:, tool_registry:, tool_catalog:, skill_catalog:,
                prompt_catalog:, guardrails:, context_providers:, executor_extra: {})
        spine.hooks.register(:task, after: guardrails.output_validator)
        middleware = Harness::MiddlewareStack.new([guardrails.input_guardrail])

        context_builder = Harness::ContextBuilder.new(
          providers: context_providers, event_stream: spine.event_stream, hooks: spine.hooks
        )
        policy_engine = Harness::Policy::Engine.new(
          policy_registry: spine.policy_registry, event_stream: spine.event_stream
        )

        executor = Harness::Executor.new(
          context_builder: context_builder, policy_engine: policy_engine,
          middleware: middleware, hooks: spine.hooks,
          tool_registry: tool_registry, skill_catalog: skill_catalog, profiles: profiles,
          session_store: spine.session_store, task_store: spine.task_store,
          checkpoint_store: spine.checkpoint_store, event_stream: spine.event_stream,
          workflow_registry: spine.workflow_registry, pending_action_store: spine.pending_action_store,
          capability_registry: spine.capability_registry, tool_catalog: tool_catalog,
          memory_store: spine.memory_store,
          content_filter_factory: guardrails.content_filter_factory, # RFC-0009: stream redaction
          **executor_extra
        )

        bus = build_core_bus(spine: spine, profiles: profiles, executor: executor)

        Graph::Result.new(
          backend: spine.backend, event_stream: spine.event_stream,
          session_store: spine.session_store, task_store: spine.task_store,
          checkpoint_store: spine.checkpoint_store, pending_action_store: spine.pending_action_store,
          memory_store: spine.memory_store, code_tool_registry: spine.code_tool_registry,
          tool_registry: tool_registry, workflow_registry: spine.workflow_registry,
          policy_registry: spine.policy_registry, capability_registry: spine.capability_registry,
          tool_catalog: tool_catalog, skill_catalog: skill_catalog, prompt_catalog: prompt_catalog,
          hooks: spine.hooks, guardrails: guardrails, middleware: middleware,
          context_providers: context_providers, context_builder: context_builder,
          policy_engine: policy_engine, profiles: profiles, executor: executor, bus: bus
        )
      end

      # The CORE command surface every root needs — turn essentials + the operator
      # controls (pause/approve) the Studio dispatches. Registering pause_task/
      # approve_action HERE is the crux of B4: it retires the config.ru:28-34 patch.
      def build_core_bus(spine:, profiles:, executor:)
        bus = Harness::CommandBus.new
        bus.register(:create_session,
                     Harness::Commands::CreateSession.new(session_store: spine.session_store, event_stream: spine.event_stream))
        bus.register(:cancel_task,
                     Harness::Commands::CancelTask.new(task_store: spine.task_store, executor: executor))
        bus.register(:pause_task,
                     Harness::Commands::PauseTask.new(task_store: spine.task_store, executor: executor))
        bus.register(:approve_action,
                     Harness::Commands::ApproveAction.new(pending_action_store: spine.pending_action_store,
                                                          executor: executor, event_stream: spine.event_stream))
        bus.register(:send_message,
                     Harness::Commands::SendMessage.new(profiles: profiles, session_store: spine.session_store,
                                                        task_store: spine.task_store, executor: executor))
        bus.register(:resume_task,
                     Harness::Commands::ResumeTask.new(profiles: profiles, task_store: spine.task_store,
                                                       checkpoint_store: spine.checkpoint_store, executor: executor))
        bus
      end

      # Infra spine (phase 1 output). Value object — the roots read these to promote
      # them to their historic public constants (SESSION_STORE, REGISTRY, ...).
      Spine = Struct.new(
        :backend, :event_stream, :session_store, :task_store, :checkpoint_store,
        :pending_action_store, :memory_store, :code_tool_registry, :workflow_registry,
        :policy_registry, :capability_registry, :hooks, keyword_init: true
      )

      # Full graph (phase 2 output). `code_tool_registry` is the plain code registry
      # (REGISTRY); `tool_registry` is the effective one the Executor uses (the
      # deployment's overlay, or the same code registry at the base).
      Result = Struct.new(
        :backend, :event_stream,
        :session_store, :task_store, :checkpoint_store, :pending_action_store, :memory_store,
        :code_tool_registry, :tool_registry, :workflow_registry, :policy_registry, :capability_registry,
        :tool_catalog, :skill_catalog, :prompt_catalog,
        :hooks, :guardrails, :middleware,
        :context_providers, :context_builder, :policy_engine,
        :profiles, :executor, :bus,
        keyword_init: true
      ) do
        def durable? = backend.is_a?(Harness::Stores::SQLite)
      end
    end
  end
end
