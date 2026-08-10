# frozen_string_literal: true

module Insika
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

      # Backend by config: INSIKA_DB set → durable SQLite (survives restart, the
      # prerequisite for Recovery); missing → ephemeral Memory (dev/demo). The same
      # rule lived verbatim in both roots. Dual-read honors the legacy HARNESS_DB alias.
      def backend_from_env(env = ENV)
        db = Insika::EnvSchema.read("INSIKA_DB", env)
        db && !db.empty? ? Insika::Stores::SQLite.new(path: db) : Insika::Stores::Memory.new
      end

      # RFC-0019: an integer tick knob from the env, nil when unset (the caller's
      # default wins). Dual-read honors the deprecated HARNESS_* alias.
      def tick_env(name, env = ENV)
        value = Insika::EnvSchema.read(name, env)
        value&.to_i
      end

      # Phase 1 — the infra spine that is IDENTICAL across roots. `extra_policy_
      # builtins` covers the one real divergence (the minimal wiring also registers
      # :workflow_allowlist; the deployment does not expose workflows).
      def spine(backend:, extra_policy_builtins: {})
        session_store        = Insika::SessionStore.new(store: backend)
        task_store           = Insika::TaskStore.new(store: backend)
        checkpoint_store     = Insika::CheckpointStore.new(store: backend)
        pending_action_store = Insika::PendingActionStore.new(store: backend)
        delegation_store     = Insika::DelegationStore.new(store: backend)
        memory_store         = Insika::MemoryStore.new(store: backend)
        # RFC-0011 §6.4/§6.5: the two durable halves of a Shape B channel — the
        # replies still owed to a platform, and the retry window that stops a
        # redelivered webhook from becoming a second turn. Built unconditionally
        # (they are empty and free when no channel is registered) so a deployment
        # that turns a channel on later finds its state already durable.
        outbox_store         = Insika::OutboxStore.new(store: backend)
        inbound_log          = Insika::InboundLog.new(store: backend)
        # RFC-0013 phase A: refinement RUNS (reports over real traffic). Runtime data,
        # same backend as sessions/tasks — the collector and the command that write it
        # are the root's business (deployment-only, like the memory commands).
        refinement_store     = Insika::RefinementStore.new(store: backend)

        code_tool_registry = Insika::ToolRegistry.new
        workflow_registry  = Insika::WorkflowRegistry.new

        policy_registry = Insika::PolicyRegistry.new
        policy_registry.register(:tool_allowlist, Insika::Policy::Builtin::ToolAllowlist)
        policy_registry.register(:skill_allowlist, Insika::Policy::Builtin::SkillAllowlist)
        policy_registry.register(:approval_required, Insika::Policy::Builtin::ApprovalRequired)
        extra_policy_builtins.each { |name, klass| policy_registry.register(name, klass) }

        Spine.new(
          backend: backend, event_stream: Insika::EventStream.new,
          session_store: session_store, task_store: task_store,
          checkpoint_store: checkpoint_store, pending_action_store: pending_action_store,
          delegation_store: delegation_store,
          memory_store: memory_store, refinement_store: refinement_store,
          outbox_store: outbox_store, inbound_log: inbound_log,
          code_tool_registry: code_tool_registry,
          workflow_registry: workflow_registry, policy_registry: policy_registry,
          capability_registry: Insika::CapabilityRegistry.new, hooks: Insika::Hooks.new,
          channel_registry: Insika::ChannelRegistry.new
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
      # edge_limiter:      optional EdgeLimiter (item 33 / §12 G7). It goes BEFORE
      #                    the InputGuardrail so a flood can't spend the LLM
      #                    moderator; nil = no edge (parity).
      def build(spine:, profiles:, tool_registry:, tool_catalog:, skill_catalog:,
                prompt_catalog:, guardrails:, context_providers:, edge_limiter: nil,
                executor_extra: {})
        spine.hooks.register(:task, after: guardrails.output_validator)
        middleware = Insika::MiddlewareStack.new([edge_limiter, guardrails.input_guardrail].compact)

        context_builder = Insika::ContextBuilder.new(
          providers: context_providers, event_stream: spine.event_stream, hooks: spine.hooks
        )
        policy_engine = Insika::Policy::Engine.new(
          policy_registry: spine.policy_registry, event_stream: spine.event_stream
        )

        # RFC-0011 §6.5. Always built: the registry starts empty, so `record` finds no
        # channel and returns nil on every turn — the cost of wiring it is one nil
        # check per completed turn, and the alternative is a second wiring path that
        # only production exercises.
        channel_delivery = Insika::ChannelDelivery.new(
          channels: spine.channel_registry, outbox: spine.outbox_store,
          session_store: spine.session_store, event_stream: spine.event_stream
        )

        executor = Insika::Executor.new(
          context_builder: context_builder, policy_engine: policy_engine,
          middleware: middleware, hooks: spine.hooks,
          tool_registry: tool_registry, skill_catalog: skill_catalog, profiles: profiles,
          session_store: spine.session_store, task_store: spine.task_store,
          checkpoint_store: spine.checkpoint_store, event_stream: spine.event_stream,
          workflow_registry: spine.workflow_registry, pending_action_store: spine.pending_action_store,
          capability_registry: spine.capability_registry, tool_catalog: tool_catalog,
          memory_store: spine.memory_store,
          content_filter_factory: guardrails.content_filter_factory, # RFC-0009: stream redaction
          delegation_store: spine.delegation_store, # RFC-0010 Fase 2: async delegation durability
          channel_delivery: channel_delivery, # RFC-0011 §6.5: out-of-band reply delivery
          **executor_extra
        )

        bus = build_core_bus(spine: spine, profiles: profiles, executor: executor)

        # RFC-0019: the periodic tick (outbox drain + stale recovery sweep). Built
        # here, after the bus, because its recovery half dispatches resume_task
        # through it; handed to the Executor, which starts it as a child of the
        # turn supervisor in serving mode. `INSIKA_TICK_INTERVAL=0` disables.
        executor.tick = Insika::Tick.new(
          store: spine.backend, channel_delivery: channel_delivery,
          recovery: Insika::Recovery.new(
            task_store: spine.task_store, checkpoint_store: spine.checkpoint_store, command_bus: bus
          ),
          interval: tick_env("INSIKA_TICK_INTERVAL") || Insika::Tick::DEFAULT_INTERVAL,
          stale_after: tick_env("INSIKA_TICK_STALE_AFTER") || Insika::Tick::DEFAULT_STALE_AFTER
        )

        Graph::Result.new(
          backend: spine.backend, event_stream: spine.event_stream,
          session_store: spine.session_store, task_store: spine.task_store,
          checkpoint_store: spine.checkpoint_store, pending_action_store: spine.pending_action_store,
          delegation_store: spine.delegation_store,
          memory_store: spine.memory_store, refinement_store: spine.refinement_store,
          outbox_store: spine.outbox_store, inbound_log: spine.inbound_log,
          channel_registry: spine.channel_registry, channel_delivery: channel_delivery,
          code_tool_registry: spine.code_tool_registry,
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
        bus = Insika::CommandBus.new
        bus.register(:create_session,
                     Insika::Commands::CreateSession.new(session_store: spine.session_store, event_stream: spine.event_stream))
        bus.register(:cancel_task,
                     Insika::Commands::CancelTask.new(task_store: spine.task_store, executor: executor))
        bus.register(:pause_task,
                     Insika::Commands::PauseTask.new(task_store: spine.task_store, executor: executor))
        bus.register(:approve_action,
                     Insika::Commands::ApproveAction.new(pending_action_store: spine.pending_action_store,
                                                          executor: executor, event_stream: spine.event_stream))
        bus.register(:send_message,
                     Insika::Commands::SendMessage.new(profiles: profiles, session_store: spine.session_store,
                                                        task_store: spine.task_store, executor: executor,
                                                        inbound_log: spine.inbound_log))
        bus.register(:resume_task,
                     Insika::Commands::ResumeTask.new(profiles: profiles, task_store: spine.task_store,
                                                       checkpoint_store: spine.checkpoint_store, executor: executor))
        bus
      end

      # Infra spine (phase 1 output). Value object — the roots read these to promote
      # them to their historic public constants (SESSION_STORE, REGISTRY, ...).
      Spine = Struct.new(
        :backend, :event_stream, :session_store, :task_store, :checkpoint_store,
        :pending_action_store, :delegation_store, :memory_store, :refinement_store,
        :outbox_store, :inbound_log, :code_tool_registry,
        :workflow_registry, :policy_registry, :capability_registry, :hooks,
        :channel_registry, keyword_init: true
      )

      # Full graph (phase 2 output). `code_tool_registry` is the plain code registry
      # (REGISTRY); `tool_registry` is the effective one the Executor uses (the
      # deployment's overlay, or the same code registry at the base).
      Result = Struct.new(
        :backend, :event_stream,
        :session_store, :task_store, :checkpoint_store, :pending_action_store, :delegation_store,
        :memory_store, :refinement_store, :outbox_store, :inbound_log,
        :channel_registry, :channel_delivery,
        :code_tool_registry, :tool_registry, :workflow_registry, :policy_registry, :capability_registry,
        :tool_catalog, :skill_catalog, :prompt_catalog,
        :hooks, :guardrails, :middleware,
        :context_providers, :context_builder, :policy_engine,
        :profiles, :executor, :bus,
        keyword_init: true
      ) do
        def durable? = backend.is_a?(Insika::Stores::SQLite)
      end
    end
  end
end
