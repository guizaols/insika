# frozen_string_literal: true

module Insika
  # The turn's tool-call counter — one object, three jobs: count, warn, abort.
  #
  # `max_tool_calls` was enforced but never announced: the model learned of the
  # ceiling only when the turn DIED with `stage: :tool_limit`. A real run in
  # `round1.db` (task d0421891) burned all 50 calls summing a 40-number list one
  # `calc` at a time and delivered nothing — the model had no way to know it was
  # spending a budget at all.
  #
  # So the budget speaks before it kills: at 10 / 5 / 2 calls remaining the
  # engine appends a short notice and the model gets to converge on an answer.
  #
  # · **User turn, never system.** The system prefix stays byte-stable, so the
  #   Anthropic cache breakpoint (`chat_builder.rb`'s `apply_instructions`) keeps
  #   hitting. A notice in the prompt would bill a cache WRITE every turn.
  # · **Batch boundary only** (ToolBatch), and **a halted batch receives
  #   nothing** — the two rules SteerInjector established for mid-turn appends.
  # · **Off when there is no limit.** `max: nil` = count nothing, warn nothing,
  #   abort never.
  #
  # KNOWN REACH (measured against DeepSeek, 2026-08-30): a model that announces
  # ONE batch bigger than the whole budget — 30 independent tool calls in a single
  # assistant message — never reaches a boundary before the abort, so it gets no
  # notice. Nothing can be appended mid-batch, so that shape is out of reach by
  # construction; it is also the shape where the model already knows what it asked
  # for. What this catches is the SEQUENTIAL burn, which is the one `round1.db`
  # actually shows: 46 `calc` calls, one per step.
  class TurnBudget
    # The three notices, verbatim and escalating — one constant, so a transcript
    # reader can recognize an engine sentence without an origin stamp (chat
    # messages carry none). Keyed by calls REMAINING after the call being made.
    NOTICES = {
      10 => "Tool budget: 10 of your %<max>d tool calls for this turn are left. " \
            "Start converging — prefer one call that answers the question over several that circle it.",
      5 => "Tool budget: 5 tool calls left in this turn. " \
           "Drop anything optional and gather only what the answer actually needs.",
      2 => "Tool budget: 2 tool calls left in this turn. " \
           "Consolidate what you already have and answer now — do not start new work."
    }.freeze

    def self.notice(remaining, max) = format(NOTICES.fetch(remaining), max: max)

    # chat: the turn's chat — must answer #add_message (the boundary append).
    # max:  the profile's max_tool_calls. nil = no budget: no notice, no abort.
    # emit: ->(type, data) — the Executor's emitter, bound to the task.
    def initialize(chat:, max:, emit:)
      @chat = chat
      @max = max
      @emit = emit
      @calls = 0
      @batch = ToolBatch.new
      @pending = nil # a threshold was crossed; waiting for the batch boundary
      @warned = []   # thresholds already spent (each fires at most once a turn)
    end

    # From ChatBuilder's before_tool_call, FIRST thing: counts the call about to
    # run and raises when it is past the ceiling. The raise is the pre-existing
    # guard-rail, moved here so the count has exactly one owner.
    def tool_call
      return if @max.nil?

      @calls += 1
      if @calls > @max
        raise Insika::TimeoutError.new("tool call limit exceeded (#{@max})", stage: :tool_limit)
      end

      remaining = @max - @calls
      @pending = remaining if NOTICES.key?(remaining) && !@warned.include?(remaining)
    end

    # From ChatBuilder's after_tool_result, with the RAW result.
    def tool_result(result) = @batch.halt!(result)

    # RubyLLM after_message: delivers the armed notice the moment the batch of
    # tool results closes.
    def message_ended(message)
      return unless @batch.closed?(message)
      return if @pending.nil?

      remaining = @pending
      @pending = nil
      return if @batch.halted? # nothing will read it (halt_when): drop, never deliver

      @warned << remaining
      @chat.add_message(role: :user, content: self.class.notice(remaining, @max))
      @emit.call(:tool_budget_warned, { remaining: remaining, max: @max })
    end
  end
end
