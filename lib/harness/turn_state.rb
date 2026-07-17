# frozen_string_literal: true

module Harness
  # MUTABLE on purpose (the only exception to the Data types):
  # the Middleware MODIFIES the execution — the links write into these fields.
  class TurnState
    attr_reader :task, :profile, :turn # turn identity (1-based)
    attr_accessor :message,            # input (Middleware may rewrite)
                  :context,            # ContextPackage from the Builder
                  :allowed_tools,      # Resolution from the Policy Engine
                  :allowed_skills,
                  :chat,               # the turn's RubyLLM::Chat instance
                  :halt_reason         # set by Middleware when short-circuiting

    # Internal (not part of the contract): correlation of the current
    # tool_call <-> tool decorators (side-effects/skip).
    attr_accessor :current_tool_call

    # Internal: impl_name(String) -> STABLE name of the capability that
    # resolved it, computed by resolve_capabilities BEFORE the policy_request and
    # consulted AFTER @policy_engine.decide, at the post-Policy junction, to
    # decide which impls enter as Capability::ResolvedTool. {} = no
    # capability_registry or empty profile.capabilities (parity).
    attr_accessor :capability_names

    # Internal (memory): the turn's tenant (from the Command), scope of the write path
    # (`remember` tool). Set in run_pipeline; nil = DEFAULT_TENANT in the MemoryStore.
    attr_accessor :tenant

    # Internal (Phase 6/D2/G4): turn context deposited into the data-tools to
    # resolve {{ctx.*}} (chat_id/agent_id/tenant/store_id) and emit
    # X-Chat-Id/X-Store-Id/X-Agent-Id. A Hash of symbols, set in run_pipeline.
    # Comes from the TURN, never from the model's args (R2). Distinct from `tenant` (memory).
    attr_accessor :turn_context

    # Internal (Phase 6, observability): the turn's token usage (input/output/
    # total/cached + model), captured from the provider's response at stage 6. Goes
    # to the terminal event (:done/:task_completed) — feeds the usage of
    # /v1/responses and the Telemetry (OTEL). nil = turn with no model response
    # (workflow) or provider without counts.
    attr_accessor :usage

    # Internal (Tool Search): ids of side-effects already completed in the
    # interrupted turn, propagated to the tools PROMOTED by tool_search (the same `skip`
    # that the eager tools' wrap_tools receives). Set in run_pipeline;
    # nil = new turn (Array(nil) => []).
    attr_accessor :skip_side_effects

    # Approval gate. `requires_approval` = names of tools that require
    # approval (Resolution); `approval_coordinator` = object (the Executor) that
    # creates the PendingAction/suspends/waits; `actor` = the turn's mailbox (used
    # by the coordinator for await(:approval)).
    attr_accessor :requires_approval, :approval_coordinator, :actor

    def initialize(task:, profile:, turn:, message:)
      @task = task
      @profile = profile
      @turn = turn
      @message = message
      @capability_names = {}
    end
  end
end
