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
                  :session,            # the turn's SessionStore::Session | nil (set at stage 2;
                  #                      read by create_chat for the per-chat model pin, §10)
                  :model_selection,    # resolved ModelSelection (v2, §10): model/provider/source/
                  #                      pinned/params/fallbacks. Set at stage 5; surfaced in usage.
                  :halt_reason,        # set by Middleware when short-circuiting (halt-as-FAILURE)
                  :halt_response,      # set by a Middleware for the GRACEFUL halt (RFC-0009 §3.1):
                  #                      the safe reply the turn completes with, WITHOUT touching the
                  #                      LLM. Distinct from halt_reason — a completion, not a failure.
                  :guardrail_block,    # audit metadata the guardrail sets alongside halt_response
                  #                      ({category:, source:, action:, detail:}); the Executor (single
                  #                      emitter) turns it into :guardrail_blocked.
                  :guardrail_flags,    # [{category:, source:, detail:}] appended by the OutputValidator
                  #                      (after_task); the Executor emits one :guardrail_flagged each.
                  :response_content,   # the turn's final assistant text, set at stage 6/on halt so the
                  #                      after_task validator can inspect it.
                  :output_filter       # per-turn Safety::OutputFilter (nil = off); redacts the stream.

    # Internal (not part of the contract): correlation of the current
    # tool_call <-> tool decorators (side-effects/skip).
    attr_accessor :current_tool_call

    # Internal (§11 R1): the chat's message count RIGHT AFTER `assemble` (seeded
    # history) and BEFORE `ask`. persist_turn slices `chat.messages.drop(baseline)`
    # to serialize the turn's real exchange — user + assistant(tool_calls) + tool
    # results + final assistant — into the transcript. nil = no chat recorded
    # (workflow/halt) → persist_turn falls back to the {user, assistant} pair.
    attr_accessor :chat_baseline

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
    # to the terminal event (:task_completed) — feeds the usage of
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
