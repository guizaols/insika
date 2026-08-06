# frozen_string_literal: true

module Insika
  # WHAT REACHES THE CUSTOMER — the turn's publishing rule.
  #
  # A turn is not one assistant message. Between the user's message and the answer
  # the model may narrate the loop ("deixa eu buscar isso pra você"), apologise for
  # a tool that failed, or — when it has no tool to call — reason in prose. All of
  # it arrives as ordinary `content` chunks, indistinguishable at the token level
  # from the answer, so streaming every chunk straight to `:content` published all
  # of it. Running a real store's prompt proved what that costs: 132 deltas of an
  # English monologue ("Let me check the tools I actually have… Actually, let me
  # reconsider.") went out as `response.output_text.delta` — the bytes a WhatsApp
  # customer would have read.
  #
  # The rule, enforced here: **`:content` carries the ANSWER — the text of the
  # assistant message that ENDS the turn.** Everything else rides `:intermediate`,
  # which the Studio and the trace render (that is the operator's window into what
  # the model narrated) and which `/v1/responses` deliberately does not translate,
  # exactly like `:thinking`.
  #
  # Which message is the last one is only knowable when it ends — a message that
  # carries tool calls is never the answer — so text is buffered per message and
  # published at the boundary (RubyLLM's `after_message`). Two consequences, both
  # deliberate:
  #
  # · The customer-visible stream is per MESSAGE, not per token. `ttft_ms` still
  #   measures the provider's first token, so item 34's baselines stay comparable;
  #   what moved is when the customer can read it. For the WhatsApp edge this
  #   changes nothing — the dispatcher accumulated the deltas into one message
  #   anyway — and the Studio keeps its live typing off `:intermediate`.
  # · A turn that dies mid-message publishes nothing. Half a sentence was never an
  #   answer; the fragment is still on the stream as `:intermediate` for whoever is
  #   debugging it.
  #
  # `halt_when` (PR #130) is the one case where narration IS the turn: the tool
  # already answered the customer, and the model's lead-in ("vou te inscrever
  # agora") is all the turn is worth. That text is retained and published by the
  # Executor's halt branch — see #halt_text.
  class TurnOutput
    # The text of the message that ended the turn, or nil if no boundary said so.
    # It is a CANDIDATE, not the published answer: the `:agent` after-hook runs
    # after the message ends and may replace the whole response, so the Executor
    # decides and publishes once, at the end of the stage.
    attr_reader :candidate

    # filter: Safety::OutputFilter | nil (RFC-0009 §3.2 — nil = stream untouched).
    # emit:   ->(type, data) — the Executor's emitter, already bound to the task.
    # public_intermediate: the agent opted this channel in (`edge_stream`), so the
    #   narration is TAGGED and `/v1/responses` gives it its own frame. Default false:
    #   an internal event stays internal unless someone said otherwise.
    def initialize(filter:, emit:, public_intermediate: false)
      @filter = filter
      @emit = emit
      @public_intermediate = public_intermediate
      @pending = +""           # text of the message currently streaming
      @last_intermediate = +"" # text of the last message that turned out NOT to be the answer
      @candidate = nil
    end

    # One provider chunk. Publishes the redacted slice as `:intermediate` — live,
    # chunk by chunk, because the operator surfaces want to watch it happen — and
    # holds it until the message boundary decides what it was.
    def push(text)
      slice = @filter ? @filter.push(text) : text.to_s
      return if slice.empty?

      @pending << slice
      emit_intermediate(slice)
    end

    # A message ended (RubyLLM `after_message`). Only an assistant message decides
    # anything — a `role: tool` result is the gem's bookkeeping. A message carrying
    # tool calls is intermediate by definition: the model asked for something, so
    # it was not done talking.
    def message_ended(message)
      return unless assistant?(message)

      flush
      text = @pending
      @pending = +""
      tool_calls?(message) ? @last_intermediate = text : @candidate = text
    end

    # Releases the redactor's retained tail (the sliding buffer holds back a value
    # that might still be growing into a match) into the current message.
    def flush
      return unless @filter

      tail = @filter.flush.to_s
      return if tail.empty?

      @pending << tail
      emit_intermediate(tail)
    end

    # Emits the answer and returns it. Empty text emits no event — an empty turn is
    # what the consumer suppresses.
    def publish(text)
      answer = text.to_s
      @emit.call(:content, { delta: answer }) unless answer.empty?
      answer
    end

    # The narration of the message that halted the turn. Normally the message
    # boundary already moved it aside (`@last_intermediate`); a transport that does
    # not report boundaries leaves it in `@pending`, and the lead-in is worth the
    # same either way.
    def halt_text = @last_intermediate.empty? ? @pending : @last_intermediate

    private

    # `public: true` is the whole difference between an event the edge drops and one
    # it translates. The flag travels on the EVENT because `frame_for` is a pure
    # static mapper with no agent in scope — the profile is read once, here.
    def emit_intermediate(text)
      data = { delta: text }
      data[:public] = true if @public_intermediate
      @emit.call(:intermediate, data)
    end

    def assistant?(message) = field(message, :role).to_s == "assistant"

    # RubyLLM::Message answers `tool_call?`; a double may only carry the field.
    def tool_calls?(message)
      return !!message.tool_call? if message.respond_to?(:tool_call?)

      calls = field(message, :tool_calls)
      calls.respond_to?(:empty?) ? !calls.empty? : !calls.nil?
    end

    def field(message, name)
      return message.public_send(name) if message.respond_to?(name)
      return message[name] || message[name.to_s] if message.respond_to?(:[])

      nil
    end
  end
end
