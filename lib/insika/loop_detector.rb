# frozen_string_literal: true

module Insika
  # RFC-0020 — loop detection by (tool, args) hash, with a ONE-SHOT intervention.
  #
  # `max_tool_calls` bounds how MANY tool calls a turn makes, not how useful they
  # are: a model retrying the exact same call — same tool, identical arguments —
  # after an empty or error result burns the whole budget doing something that
  # was settled on the first repeat. This detector is the engine saying so, once.
  #
  # The streak is CONSECUTIVE and turn-scoped, like the max_tool_calls counter it
  # sits next to in ChatBuilder#wire_callbacks: a call revisited much later in a
  # long turn is not the pathology being caught, and semantic ("nearly the same")
  # matching is how a guard-rail starts eating legitimate retries.
  #
  # Two invariants, both borrowed from SteerInjector (RFC-0015 §5.2), because the
  # intervention is a `user` message appended mid-loop:
  #
  # · **Batch boundary only.** The append happens after the LAST tool result of a
  #   batch closes — a `user` message between two tool results is rejected by
  #   Anthropic outright. Same arithmetic: an assistant message opens a batch of
  #   N, the Nth `role: tool` message closes it.
  # · **A halted batch receives nothing.** With `halt_when` there is no next
  #   model step; a warning appended there would sit unanswered forever.
  #
  # The repeated call itself STILL RUNS — fabricating a synthetic result would
  # teach the model that tools lie (the failure RFC-0015 §6.4 refuses). The
  # warning rides after the truth; only a repeat that arrives AFTER the warning
  # was spent aborts, through the existing TimeoutError(stage: :tool_limit) path.
  class LoopDetector
    # The one intervention text, verbatim — a fixed engine sentence, so a report
    # can identify it without an origin stamp (chat messages carry none; §4.4).
    def self.intervention(name, streak)
      "You have called `#{name}` with identical arguments #{streak} times in a row and " \
      "received the same result every time. Repeating it will not produce new information. " \
      "Do not call it again with the same arguments — answer with what you already have, " \
      "or change your approach."
    end

    # chat:  the turn's chat — must answer #add_message (the boundary append).
    # limit: the streak that triggers the intervention (profile's
    #        max_tool_repeat). Values < 2 mean OFF: a "streak of 1" is every
    #        call, which is meaningless.
    # emit:  ->(type, data) — the Executor's emitter, bound to the task.
    def initialize(chat:, limit:, emit:)
      @chat = chat
      @limit = limit
      @emit = emit
      @last = nil          # fingerprint of the previous call (nil = none yet)
      @streak = 0
      @intervened = false  # the ONE warning of this turn has been delivered
      @pending = false     # detection fired; waiting for the batch boundary
      @expected = nil      # tool calls announced by the batch in flight
      @seen = 0
      @halted = false
    end

    # From ChatBuilder's before_tool_call. Raises BEFORE the call executes once
    # the warning is spent — bounded spend is the point of aborting here.
    def tool_call(name, arguments)
      fingerprint = [name.to_s, canonical(arguments)]
      if fingerprint == @last
        @streak += 1
      else
        # A different call broke the run: the loop resolved itself, so a warning
        # armed earlier is moot — it must not fire later naming the WRONG call.
        @streak = 1
        @pending = false
      end
      @last = fingerprint
      return if @streak < @limit

      if @intervened
        raise Insika::TimeoutError.new(
          "tool loop detected (#{name} repeated with identical arguments after a warning)",
          stage: :tool_limit)
      end
      @pending = true
    end

    # From ChatBuilder's after_tool_result, with the RAW result — the only place
    # a Tool::Halt is still recognizable (SteerInjector's comment applies here).
    def tool_result(result)
      @halted = true if defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)
    end

    # RubyLLM after_message. An assistant message carrying tool calls OPENS a
    # batch; the Nth tool result CLOSES it — the one boundary where appending
    # is valid.
    def message_ended(message)
      role = field(message, :role).to_s
      return open_batch(message) if role == "assistant"
      return unless role == "tool" && @expected

      @seen += 1
      intervene! if @seen >= @expected
    end

    private

    def open_batch(message)
      calls = field(message, :tool_calls)
      size = calls.respond_to?(:size) ? calls.size : 0
      # No tool call = the model talking; the turn is ending and a pending
      # warning is moot — the loop resolved itself.
      return @expected = nil if size.zero?

      @expected = size
      @seen = 0
      @halted = false
    end

    def intervene!
      @expected = nil
      return unless @pending
      @pending = false
      return if @halted # nothing will read it (halt_when): drop, never deliver

      @intervened = true
      name, = @last
      @chat.add_message(role: :user, content: self.class.intervention(name, @streak))
      # Counts and the tool name, never the arguments — order numbers are PII.
      @emit.call(:tool_loop_intervened, { name: name, streak: @streak })
    end

    # (name, args) hash: symbols vs strings and key order must not split an
    # identical call into two fingerprints. Compared with ==, never hashed.
    def canonical(value)
      case value
      when Hash then value.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first)
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def field(message, name)
      return message.public_send(name) if message.respond_to?(name)
      return message[name] || message[name.to_s] if message.respond_to?(:[])

      nil
    end
  end
end
