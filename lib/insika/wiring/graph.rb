# frozen_string_literal: true

module Insika
  module Wiring
    # SHARED composition core for both roots: the minimal wiring
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

      # an integer tick knob from the env, nil when unset (the caller's
      # default wins). Dual-read honors the deprecated HARNESS_* alias.
      def tick_env(name, env = ENV)
        value = Insika::EnvSchema.read(name, env)
        value&.to_i
      end

      # the infra spine that is IDENTICAL across roots. `extra_policy_
      # builtins` covers the one real divergence (the minimal wiring also registers
      # :workflow_allowlist; the deployment does not expose workflows).
      def spine(backend:, extra_policy_builtins: {})
        session_store        = Insika::SessionStore.new(store: backend)
        task_store           = Insika::TaskStore.new(store: backend)
        checkpoint_store     = Insika::CheckpointStore.new(store: backend)
        pending_action_store = Insika::PendingActionStore.new(store: backend)
        delegation_store     = Insika::DelegationStore.new(store: backend)
        memory_store         = Insika::MemoryStore.new(store: backend)
        # the append-only, content-free audit of OPERATOR memory
        # mutations. Built unconditionally (empty and free when nothing writes)
        # so a deployment that turns it on later finds its audit already durable.
        memory_audit_store  = Insika::MemoryAuditStore.new(store: backend)
        token_store          = Insika::TokenStore.new(store: backend)
        budget_ledger        = Insika::BudgetLedger.new(store: backend)
        circuit_state        = Insika::CircuitState.new(store: backend)
        # the two durable halves of a Shape B channel — the
        # replies still owed to a platform, and the retry window that stops a
        # redelivered webhook from becoming a second turn. Built unconditionally
        # (they are empty and free when no channel is registered) so a deployment
        # that turns a channel on later finds its state already durable.
        outbox_store         = Insika::OutboxStore.new(store: backend)
        # the shadow pair store — one durable record per mirrored
        # exchange, written by our half and the incumbent's. Built unconditionally
        # (empty and free when shadow is off) so turning it on later finds the
        # state already durable, beside the outbox on the same runtime backend.
        shadow_pair_store    = Insika::ShadowPairStore.new(store: backend)
        inbound_log          = Insika::InboundLog.new(store: backend)
        # WS7: business outcomes per conversation, recorded by the operator or
        # the integration (POST /v1/outcomes). Built unconditionally (empty and
        # free when nothing records) so the Studio's scorecard always has a store.
        outcome_store        = Insika::OutcomeStore.new(store: backend)
        # the funnel's durable aggregates — per-day stage counts,
        # fold cursors and baseline snapshots. Built unconditionally (empty and
        # free when no pack declares a funnel) so the fold, the doctor and the
        # Studio always have a store to read/write.
        funnel_store        = Insika::FunnelStore.new(store: backend)
        # the contact-state cells and the follow-up schedule
        # records. Built unconditionally (empty and free when no pack declares
        # followup) so the engine, the tools and the Studio always have stores.
        contact_store       = Insika::ContactStore.new(store: backend)
        followup_store      = Insika::FollowupStore.new(store: backend)
        # the distilled proposals + the latched dedup ledger +
        # the per-session markers. Built unconditionally (empty and free when
        # no pack declares distill) so the wiki, the engine and the LGPD
        # purges always have a store.
        proposal_store      = Insika::ProposalStore.new(store: backend)
        # refinement RUNS (reports over real traffic). Runtime data,
        # same backend as sessions/tasks — the collector and the command that write it
        # are the root's business (deployment-only, like the memory commands).
        refinement_store     = Insika::RefinementStore.new(store: backend)
        # the harvest's durable half — mining runs, the per-
        # candidate lifecycle, the append-only promotion log, the snapshots
        # and the per-session markers. Built unconditionally (empty and free
        # when no pack declares harvest) so the engine, the Studio and the
        # LGPD purges always have a store.
        harvest_store        = Insika::HarvestStore.new(store: backend)

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
          memory_store: memory_store, memory_audit_store: memory_audit_store,
          refinement_store: refinement_store,
          harvest_store: harvest_store,
          token_store: token_store, budget_ledger: budget_ledger, circuit_state: circuit_state,
          outbox_store: outbox_store, shadow_pair_store: shadow_pair_store,
          inbound_log: inbound_log,
          outcome_store: outcome_store,
          funnel_store: funnel_store,
          contact_store: contact_store,
          followup_store: followup_store,
          proposal_store: proposal_store,
          code_tool_registry: code_tool_registry,
          workflow_registry: workflow_registry, policy_registry: policy_registry,
          capability_registry: Insika::CapabilityRegistry.new, hooks: Insika::Hooks.new,
          channel_registry: Insika::ChannelRegistry.new
        )
      end

      # assemble the graph on top of a spine.
      #
      # tool_registry:     effective registry the Executor uses (plain REGISTRY at the
      #                    base; OverlayToolRegistry in the deployment).
      # guardrails:        a Safety::Factory — its input_guardrail becomes the single
      #                    middleware and its output_validator the after-task hook, so
      #                    both wirings compose identically.
      # executor_extra:    optional Executor kwargs a root adds (deployment passes
      #                    settings_store + tool_trace_store; the base passes none).
      # edge_limiter:      optional EdgeLimiter. It goes BEFORE
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

        # Always built: the registry starts empty, so `record` finds no
        # channel and returns nil on every turn — the cost of wiring it is one nil
        # check per completed turn, and the alternative is a second wiring path that
        # only production exercises.
        channel_delivery = Insika::ChannelDelivery.new(
          channels: spine.channel_registry, outbox: spine.outbox_store,
          session_store: spine.session_store, event_stream: spine.event_stream,
          shadow_pairs: spine.shadow_pair_store
        )

# WS3 provider reliability (retries/backoff/fallback/breaker) is ALWAYS wired —
      # the profile's `reliability` data gates it, so the bare wiring is unchanged.
      reliability = Insika::Reliability.new(circuit_store: spine.circuit_state,
                                            event_stream: spine.event_stream)
      executor = Insika::Executor.new(
        context_builder: context_builder, policy_engine: policy_engine,
        middleware: middleware, hooks: spine.hooks,
        tool_registry: tool_registry, skill_catalog: skill_catalog, profiles: profiles,
        session_store: spine.session_store, task_store: spine.task_store,
        checkpoint_store: spine.checkpoint_store, event_stream: spine.event_stream,
        workflow_registry: spine.workflow_registry, pending_action_store: spine.pending_action_store,
        capability_registry: spine.capability_registry, tool_catalog: tool_catalog,
        memory_store: spine.memory_store,
        content_filter_factory: guardrails.content_filter_factory, # stream redaction
        delegation_store: spine.delegation_store, # async delegation durability
        channel_delivery: channel_delivery, # out-of-band reply delivery
        reliability: reliability, # WS3: retries/fallback/breaker (data-gated)
        grounding_enforcer: guardrails.grounding_enforcer, # :enforce cut
        # the follow-up stores — the ChatBuilder wires the
        # schedule/cancel_followup tools on them (parity when no pack declares).
        contact_store: spine.contact_store,
        followup_store: spine.followup_store,
        # the model-visible trace rides executor_extra like the
        # context trace — a module graph that omits it still builds (nil =
        # parity). The base graph wires it over the same backend the context
        # trace uses.
        model_visible_trace_store: Insika::ModelVisibleTraceStore.new(store: spine.backend),
        **executor_extra
      )

        # the ONE path that writes proposals, shared by the
        # automatic DistillEngine loop and the bus command behind the Studio's
        # "Run distillation now" button (one code path for both).
        run_distillation = Insika::Commands::RunDistillation.new(
          profiles: profiles, proposal_store: spine.proposal_store,
          session_store: spine.session_store, memory_store: spine.memory_store,
          settings_store: executor_extra[:settings_store],
          event_stream: spine.event_stream
        )

        bus = build_core_bus(spine: spine, profiles: profiles, executor: executor,
                             executor_extra: executor_extra, skill_catalog: skill_catalog,
                             run_distillation: run_distillation)

        # the periodic tick (outbox drain + stale recovery sweep). Built
        # here, after the bus, because its recovery half dispatches resume_task
        # through it; handed to the Executor, which starts it as a child of the
        # turn supervisor in serving mode. `INSIKA_TICK_INTERVAL=0` disables.
        # WS8 retention rides the tick: always built, the settings knob
        # (`retention_days`) gates it — the base graph (no settings_store)
        # reads as OFF.
        executor.tick = Insika::Tick.new(
          store: spine.backend, channel_delivery: channel_delivery,
          recovery: Insika::Recovery.new(
            task_store: spine.task_store, checkpoint_store: spine.checkpoint_store, command_bus: bus
          ),
          retention: Insika::Retention.new(
            store: spine.backend, session_store: spine.session_store,
            task_store: spine.task_store, checkpoint_store: spine.checkpoint_store,
            memory_store: spine.memory_store, outcome_store: spine.outcome_store,
            tool_trace_store: executor_extra[:tool_trace_store],
            context_trace_store: executor_extra[:context_trace_store],
            # the model-visible traces die with their checkpoints.
            model_visible_trace_store: Insika::ModelVisibleTraceStore.new(store: spine.backend),
            outbox_store: spine.outbox_store,
            shadow_pair_store: spine.shadow_pair_store,
            settings_store: executor_extra[:settings_store],
            budget_ledger: spine.budget_ledger, # WS2 counter GC (retention-independent)
            funnel_store: spine.funnel_store, # fold dies with its source
            followup_store: spine.followup_store, # records age out too
            contact_store: spine.contact_store, # cells age out too
            proposal_store: spine.proposal_store, # proposals age out too
            harvest_store: spine.harvest_store # candidates/log/snapshots too
          ),
          interval: tick_env("INSIKA_TICK_INTERVAL") || Insika::Tick::DEFAULT_INTERVAL,
          stale_after: tick_env("INSIKA_TICK_STALE_AFTER") || Insika::Tick::DEFAULT_STALE_AFTER
        )
        # the tick-driven outcome fold — wired here, after the
        # Tick, because it reads the outcome/funnel stores of the spine and the
        # profiles; the per-pair declaration gates it (nil funnel everywhere =
        # an inert fold). Always built: a pack that declares a funnel later
        # finds its fold already on the tick.
        executor.tick.funnel = Insika::FunnelFold.new(
          outcome_store: spine.outcome_store, funnel_store: spine.funnel_store,
          profiles: profiles, store: spine.backend
        )
        # the tick-driven follow-up firer — the tick's third
        # duty, wired here after the Tick, gated by its own claim window.
        # Always built: a pack that declares followup later finds its firer
        # already on the tick (inert when no profile declares followup).
        executor.tick.followup = Insika::FollowupEngine.new(
          store: spine.backend, followup_store: spine.followup_store,
          contact_store: spine.contact_store, task_store: spine.task_store,
          profiles: profiles, executor: executor, event_stream: spine.event_stream
        )
        # the distillation engine — the tick-duty that finds idle
        # customer sessions and distills them on its own worker fiber (a
        # supervisor child, started in serving mode next to the tick).
        # Always built: a pack that declares `distill:` later finds its engine
        # already wired — and INERT until one does (the engine gates its start
        # and its passes on a declaring profile).
        executor.distill_engine = Insika::DistillEngine.new(
          store: spine.backend, proposal_store: spine.proposal_store,
          session_store: spine.session_store,
          runner: run_distillation,
          profiles: profiles,
          window: Insika::DistillEngine::DEFAULT_WINDOW
        )
        # the harvest engine — the tick-duty that finds idle,
        # unmined sessions whose agent declares `harvest.enabled` and mines
        # them on its own worker fiber (a supervisor child, started in serving
        # mode next to the tick). Always built: INERT until a profile declares
        # harvest (the engine gates its start and its passes on data). The
        # runner is the same RunHarvest the bus serves, so the manual CLI and
        # the automated loop share one code path.
        run_harvest = Insika::Commands::RunHarvest.new(
          profiles: profiles, harvest_store: spine.harvest_store,
          session_store: spine.session_store, task_store: spine.task_store,
          skill_store: skill_catalog.store, # the harvest's dedup reads the authored skills
          tool_trace_store: executor_extra[:tool_trace_store],
          settings_store: executor_extra[:settings_store],
          negative_list: nil, miner_factory: nil,
          event_stream: spine.event_stream
        )
        executor.harvest_engine = Insika::HarvestEngine.new(
          store: spine.backend, harvest_store: spine.harvest_store,
          session_store: spine.session_store, runner: run_harvest,
          profiles: profiles, window: Insika::HarvestEngine::DEFAULT_WINDOW
        )
        # WS6 operator alerts: answers budget_warning / breaker_open /
        # delivery_failed per agent (`alerts.webhook`) via the outbox+claim
        # pipeline. Always wired — the per-agent data gates it (parity).
        executor.alert_dispatcher = Insika::AlertDispatcher.new(
          event_stream: spine.event_stream, outbox: spine.outbox_store,
          channels: spine.channel_registry, profiles: profiles,
          task_store: spine.task_store, http: Insika::HttpClient.new
        )

        Graph::Result.new(
          backend: spine.backend, event_stream: spine.event_stream,
          session_store: spine.session_store, task_store: spine.task_store,
          checkpoint_store: spine.checkpoint_store, pending_action_store: spine.pending_action_store,
          delegation_store: spine.delegation_store,
          memory_store: spine.memory_store, memory_audit_store: spine.memory_audit_store,
          refinement_store: spine.refinement_store,
          harvest_store: spine.harvest_store,
          outbox_store: spine.outbox_store, shadow_pair_store: spine.shadow_pair_store,
          inbound_log: spine.inbound_log,
          outcome_store: spine.outcome_store,
          funnel_store: spine.funnel_store,
          contact_store: spine.contact_store,
          followup_store: spine.followup_store,
          proposal_store: spine.proposal_store,
          token_store: spine.token_store, budget_ledger: spine.budget_ledger,
          circuit_state: spine.circuit_state,
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
      # approve_action HERE is the crux of: it retires the config.ru:28-34 patch.
      def build_core_bus(spine:, profiles:, executor:, executor_extra: {}, skill_catalog: nil,
                         run_distillation: nil)
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
                                                        inbound_log: spine.inbound_log,
                                                        contact_store: spine.contact_store,
                                                        followup_store: spine.followup_store,
                                                        store: spine.backend))
        bus.register(:resume_task,
                     Insika::Commands::ResumeTask.new(profiles: profiles, task_store: spine.task_store,
                                                       checkpoint_store: spine.checkpoint_store, executor: executor))
        # WS1 multi-tenant credentials: per-tenant + operator tokens, stored as
        # hashes. Operator-only BY CONSTRUCTION — the edge refuses a tenant
        # principal on POST /v1/commands, and the handlers re-check meta.
        bus.register(:issue_tenant_token,
                     Insika::Commands::IssueTenantToken.new(token_store: spine.token_store,
                                                            event_stream: spine.event_stream))
        bus.register(:revoke_token,
                     Insika::Commands::RevokeToken.new(token_store: spine.token_store,
                                                       event_stream: spine.event_stream))
        bus.register(:rotate_tenant_token,
                     Insika::Commands::RotateTenantToken.new(token_store: spine.token_store,
                                                             event_stream: spine.event_stream))
        # WS7: a business outcome per conversation (operator or integration).
        bus.register(:record_outcome,
                     Insika::Commands::RecordOutcome.new(outcome_store: spine.outcome_store,
                                                         event_stream: spine.event_stream))
        # the incumbent's half of a shadow pair, one command behind
        # both mirror shapes (the mirror call itself + the follow-up route).
        bus.register(:record_shadow_reply,
                     Insika::Commands::RecordShadowReply.new(shadow_pairs: spine.shadow_pair_store,
                                                             event_stream: spine.event_stream))
        # WS8 (LGPD): purge one customer's memory + the whole footprint of their
        # sessions (traces, tasks, checkpoints, outbox). The trace stores are
        # deployment components (nil at the base — skipped). the
        # audit collaborator records a content-free purge line.
        bus.register(:forget_customer,
                     Insika::Commands::ForgetCustomer.new(
                       memory_store: spine.memory_store, session_store: spine.session_store,
                       tool_trace_store: executor_extra[:tool_trace_store],
                       context_trace_store: executor_extra[:context_trace_store],
                       # the model-visible traces die with the
                       # checkpoints (the same SessionPurge list).
                       model_visible_trace_store: Insika::ModelVisibleTraceStore.new(store: spine.backend),
                       task_store: spine.task_store, checkpoint_store: spine.checkpoint_store,
                       outbox_store: spine.outbox_store,
                       shadow_pairs: spine.shadow_pair_store,
                       audit_store: spine.memory_audit_store,
                       followup_store: spine.followup_store,
                       contact_store: spine.contact_store,
                       proposal_store: spine.proposal_store,
                       event_stream: spine.event_stream
                     ))
        # the LGPD access right — export one customer's memory
        # cell as content (the Studio download); the event stays counts-only.
        bus.register(:export_customer_memory,
                     Insika::Commands::ExportCustomerMemory.new(
                       memory_store: spine.memory_store, event_stream: spine.event_stream
                     ))
        # WS8 (LGPD): purge ONE TENANT's data — sessions and their footprint,
        # memory cells and outcomes. Operator-only by construction (ingress).
        bus.register(:delete_tenant_data,
                     Insika::Commands::DeleteTenantData.new(
                       memory_store: spine.memory_store, session_store: spine.session_store,
                       tool_trace_store: executor_extra[:tool_trace_store],
                       context_trace_store: executor_extra[:context_trace_store],
                       # the model-visible traces die with the tenant.
                       model_visible_trace_store: Insika::ModelVisibleTraceStore.new(store: spine.backend),
                       outcome_store: spine.outcome_store,
                       funnel_store: spine.funnel_store, # the fold dies with the tenant
                       followup_store: spine.followup_store,
                       contact_store: spine.contact_store,
                       proposal_store: spine.proposal_store,
                       harvest_store: spine.harvest_store,
                       task_store: spine.task_store, checkpoint_store: spine.checkpoint_store,
                       outbox_store: spine.outbox_store,
                       shadow_pairs: spine.shadow_pair_store,
                       token_store: spine.token_store, # revoked BEFORE the sweep
                       event_stream: spine.event_stream
                     ))
        # the operator's baseline freeze — the number
        # read. Synchronous control command, dispatched from the Studio.
        bus.register(:freeze_funnel_baseline,
                     Insika::Commands::FreezeFunnelBaseline.new(
                       funnel_store: spine.funnel_store, profiles: profiles,
                       event_stream: spine.event_stream
                     ))
        # the follow-up mutations — the Studio's Cancel button
        # and the channel opt-out event (a tenant principal never reaches the
        # generic command ingress; these ride the same operator-grade path).
        bus.register(:cancel_followup,
                     Insika::Commands::CancelFollowup.new(followup_store: spine.followup_store,
                                                          event_stream: spine.event_stream))
        bus.register(:revoke_contact,
                     Insika::Commands::RevokeContact.new(contact_store: spine.contact_store,
                                                         followup_store: spine.followup_store,
                                                         store: spine.backend,
                                                         event_stream: spine.event_stream))
        # the human's answer on a distilled proposal — the ONLY
        # mutation behind the Facts (wiki) page. Synchronous control command.
        bus.register(:resolve_proposal,
                     Insika::Commands::ResolveProposal.new(
                       proposal_store: spine.proposal_store,
                       memory_store: spine.memory_store,
                       event_stream: spine.event_stream
                     ))
        #  /C10: the gated harvest — the mining pass, the double
        # gate, the human's promote/rollback/dismiss. The BASE graph wires the
        # nil factories (no eval surface, no criterion, no funnel): every flow
        # refuses with a named reason or skips (parity). The deployment root
        # re-registers with the real gate/criterion/negative list.
        bus.register(:run_harvest,
                     Insika::Commands::RunHarvest.new(
                       profiles: profiles, harvest_store: spine.harvest_store,
                       session_store: spine.session_store, task_store: spine.task_store,
                       skill_store: skill_catalog.store,
                       tool_trace_store: executor_extra[:tool_trace_store],
                       settings_store: executor_extra[:settings_store],
                       negative_list: nil, miner_factory: nil,
                       event_stream: spine.event_stream
                     ))
        bus.register(:gate_harvest,
                     Insika::Commands::GateHarvest.new(
                       harvest_store: spine.harvest_store, gate: nil,
                       conversion_gate: nil, criterion: nil,
                       event_stream: spine.event_stream
                     ))
        bus.register(:promote_harvest,
                     Insika::Commands::PromoteHarvest.new(
                       harvest_store: spine.harvest_store,
                       skill_store: skill_catalog.store,
                       skill_catalog: skill_catalog,
                       profile_source: profiles, criterion: nil, conversion_gate: nil,
                       event_stream: spine.event_stream
                     ))
        bus.register(:rollback_harvest,
                     Insika::Commands::RollbackHarvest.new(
                       harvest_store: spine.harvest_store,
                       skill_store: skill_catalog.store,
                       skill_catalog: skill_catalog,
                       profile_source: profiles, event_stream: spine.event_stream
                     ))
        bus.register(:reject_harvest,
                     Insika::Commands::RejectHarvest.new(
                       harvest_store: spine.harvest_store, event_stream: spine.event_stream
                     ))
        # the ONE path that writes proposals, served to the
        # Studio's "Run distillation now" button. The same instance the
        # DistillEngine's loop uses, so the manual and the automatic share one
        # code path; the engine keeps the automatic pass when the root does
        # not pass a runner here (nil = the command is not on the bus).
        bus.register(:run_distillation, run_distillation) if run_distillation
        bus
      end

      # Infra spine (phase 1 output). Value object — the roots read these to promote
      # them to their historic public constants (SESSION_STORE, REGISTRY, ...).
      Spine = Struct.new(
        :backend, :event_stream, :session_store, :task_store, :checkpoint_store,
        :pending_action_store, :delegation_store, :memory_store, :memory_audit_store,
        :refinement_store,
        :harvest_store,
        :token_store, :budget_ledger, :circuit_state, :outbox_store, :shadow_pair_store,
        :inbound_log, :outcome_store, :funnel_store,
        :contact_store, :followup_store, :proposal_store,
        :code_tool_registry, :workflow_registry, :policy_registry, :capability_registry, :hooks,
        :channel_registry, keyword_init: true
      )

      # Full graph (phase 2 output). `code_tool_registry` is the plain code registry
      # (REGISTRY); `tool_registry` is the effective one the Executor uses (the
      # deployment's overlay, or the same code registry at the base).
      Result = Struct.new(
        :backend, :event_stream,
        :session_store, :task_store, :checkpoint_store, :pending_action_store, :delegation_store,
        :memory_store, :memory_audit_store, :refinement_store, :outbox_store, :shadow_pair_store,
        :inbound_log, :token_store,
        :budget_ledger, :circuit_state, :outcome_store, :funnel_store,
        :contact_store, :followup_store, :proposal_store,
        :harvest_store,
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
