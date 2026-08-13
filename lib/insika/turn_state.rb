# frozen_string_literal: true

module Insika
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
                  #                      read by create_chat for the per-chat model pin)
                  :model_selection,    # resolved ModelSelection: model/provider/source/
                  #                      pinned/params/fallbacks. Set at stage 5; surfaced in usage.
                  :halt_reason,        # set by Middleware when short-circuiting (halt-as-FAILURE)
                  :halt_response,      # set by a Middleware for the GRACEFUL halt:
                  #                      the safe reply the turn completes with, WITHOUT touching the
                  #                      LLM. Distinct from halt_reason — a completion, not a failure.
                  :guardrail_block,    # audit metadata the guardrail sets alongside halt_response
                  #                      ({category:, source:, action:, detail:}); the Executor (single
                  #                      emitter) turns it into :guardrail_blocked.
                  :guardrail_flags,    # [{category:, source:, detail:}] appended by the OutputValidator
                  #                      (after_task); the Executor emits one :guardrail_flagged each.
                  :response_content,   # the turn's final assistant text, set at stage 6/on halt so the
                  #                      after_task validator can inspect it.
                  :output_filter,      # per-turn Safety::OutputFilter (nil = off); redacts the stream.
                  :stuck_outcome       # set by the signal_stuck system tool (WS5):
                  #                      { reason:, message: } when the agent declared it cannot
                  #                      proceed. The Executor tags the terminal event with
                  #                      outcome: "stuck" and emits :turn_stuck. nil = normal turn.

    # Internal (not part of the contract): per-CALL correlation between RubyLLM's
    # tool callbacks and the tool decorators — `current_tool_call` keys the
    # side-effect checkpoint / resume skip / trace, `current_tool_name` labels the
    # :tool_result event.
    #
    # They live in FIBER STORAGE, not in ivars, and that is the whole point:
    # `before_tool_call` → `tool.call` → `after_tool_result` all run in the SAME
    # fiber, and with `ToolConcurrency` there is one fiber PER CALL. A
    # single slot on this shared object would let one in-flight call overwrite
    # another's — a side-effect recorded under the wrong id (so a resume skips the
    # wrong tool, or re-runs a non-idempotent one) and a mislabelled event. Both
    # silent. One writer per fiber needs no lock; serial execution is unchanged,
    # since a lone fiber writes and reads its own storage.
    #
    # Read/written ONLY through here so the rule has one home.
    CALL_KEY = :insika_tool_call
    NAME_KEY = :insika_tool_name

    def current_tool_call = Fiber[CALL_KEY]
    def current_tool_name = Fiber[NAME_KEY]

    def current_tool_call=(call)
      Fiber[CALL_KEY] = call
    end

    def current_tool_name=(name)
      Fiber[NAME_KEY] = name
    end

    # Internal (R1): the chat's message count RIGHT AFTER `assemble` (seeded
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

    # Internal: the turn's resolved QueuePolicy. Read at stage 6 to decide
    # whether this run accepts steered messages, and how they are worded. Resolved once
    # per turn, in build_turn_state — an edit to the agent mid-run does not change the
    # rules the run started under.
    attr_accessor :queue_policy

    # Internal: true when this turn re-enters the pipeline via
    # resume_task/recovery. The EdgeLimiter reads it to NEVER re-count or block a
    # turn that was already admitted — a crash/pause under a saturated window must
    # not swallow a legitimate message with the rate-limit reply.
    attr_accessor :resumed

    # Internal (memory): the turn's tenant (from the Command), scope of the write path
    # (`remember` tool). Set in run_pipeline; nil = DEFAULT_TENANT in the MemoryStore.
    attr_accessor :tenant

    # Internal: turn context deposited into the data-tools to
    # resolve {{ctx.*}} (chat_id/agent_id/tenant/store_id) and emit
    # X-Chat-Id/X-Store-Id/X-Agent-Id. A Hash of symbols, set in run_pipeline.
    # Comes from the TURN, never from the model's args (R2). Distinct from `tenant` (memory).
    attr_accessor :turn_context

    # Internal (observability): the turn's token usage (input/output/
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

    # Internal: the turn's shared in-flight cap for tool calls —
    # ONE Async::Semaphore(tool_concurrency), installed by ToolAssembly#wrap_tools
    # and acquired by every ToolEnvelope, INCLUDING the ones tool_search promotes
    # mid-turn (they read it off the state, so the cap survives promotion).
    # nil = concurrency off: no gate, no overhead, serial execution unchanged.
    attr_accessor :tool_gate

    # parallel tool calls, resolved PER TURN and read by ChatBuilder
    # (whether to hand the gem `concurrency:`) and ToolAssembly (the gate's size).
    #
    # `requested_tool_concurrency` is what the operator configured;
    # `tool_concurrency` is what this turn actually gets. They differ for exactly
    # one reason —: `Executor#request_approval` blocks on `actor.await(approval)`,
    # and the mailbox is one queue per TASK. Two fibers waiting there share it,
    # `dequeue` wakes exactly one, the message is consumed, and the other fiber
    # hangs until `approval_timeout` (~1h). So a turn that can suspend for a human
    # runs its tools serially. Per-TURN and not per-profile because
    # `requires_approval` comes from the Resolution: it can be empty on a turn
    # whose profile does list approvals.
    def requested_tool_concurrency
      n = ((profile.respond_to?(:limits) && profile.limits) || {})[:tool_concurrency].to_i
      n > 1 ? n : nil
    end

    def tool_concurrency
      return nil unless Array(requires_approval).empty?

      requested_tool_concurrency
    end

    def initialize(task:, profile:, turn:, message:)
      @task = task
      @profile = profile
      @turn = turn
      @message = message
      @capability_names = {}
      # Fiber storage is INHERITED by fibers created later, so a turn spawned from
      # inside a tool call (a subagent child) would start out carrying its
      # parent's correlation. Clearing at turn start keeps a child from keying its
      # own side-effects under the parent's tool_call id.
      self.current_tool_call = nil
      self.current_tool_name = nil
    end
  end
end
