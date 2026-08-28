# frozen_string_literal: true

module Insika
  # WHERE a message that arrived mid-run is allowed to enter the
  # conversation.
  #
  # A customer who corrects themselves while the agent is calling tools ("1234567",
  # three seconds after "queria saber do pedido") should have that land before the
  # model's next reasoning step, not after the whole run. RubyLLM runs the entire tool
  # loop inside `chat.ask`, so the only place to append is from inside its callbacks —
  # which is enough, because they are public and additive:
  #
  #   complete_once
  #     ├─ provider_completion         → assistant message announcing N tool_calls
  #     ├─ after_message(assistant)    ← N is read here
  #     └─ handle_tool_calls
  #          ├─ add_tool_result_message ×N
  #          │    └─ after_message(tool)  ← counted; the Nth is THE BOUNDARY
  #          └─ halt_result || complete   ← the next model step sees what we appended
  #
  # Counting to N is not an optimization, it is the correctness condition. A `user`
  # message inserted BETWEEN tool results is rejected outright by Anthropic (all tool
  # results of a batch must sit together) and merely tolerated by OpenAI.
  #
  # Two invariants this object exists to keep:
  #
  # · **Tail-append only.** Nothing already sent to the provider is edited, reordered
  #   or removed. That is what keeps the prompt cache valid, and a cache miss on a
  #   ~48k-token identity is a real cost, not a theoretical one.
  # · **A halted batch injects nothing.** With `halt_when` there is no next model step
  #   (`handle_tool_calls` returns the Halt), so an appended message would sit in the
  #   transcript unanswered forever. The messages stay in the mailbox and the Executor
  #   releases them as a follow-up turn.
  class SteerInjector
    # chat:   the turn's RubyLLM::Chat (already assembled).
    # actor:  the turn's TaskActor — the mailbox the steered messages arrive in.
    # policy: the turn's QueuePolicy (`frame` decides how the text is worded).
    # emit:   ->(type, data) — the Executor's emitter, already bound to the task.
    def initialize(chat:, actor:, policy:, emit:)
      @chat = chat
      @actor = actor
      @policy = policy
      @emit = emit
      @expected = nil # tool calls announced by the batch in flight (nil = not in one)
      @seen = 0
      @halted = false
      @injected = 0
    end

    # How many messages this run absorbed (read by specs and by the turn's event).
    attr_reader :injected

    # RubyLLM `after_tool_result`, with the RAW result — the only place a `Tool::Halt`
    # is still recognizable. By the time it becomes a `role: tool` message its content
    # is the payload, indistinguishable from an ordinary result.
    def tool_result(result)
      @halted = true if halt?(result)
    end

    # RubyLLM `after_message`. An assistant message carrying tool calls OPENS a batch;
    # the Nth tool result CLOSES it, and that is the one boundary where appending is
    # valid.
    def message_ended(message)
      role = field(message, :role).to_s
      return open_batch(message) if role == "assistant"
      return unless role == "tool" && @expected

      @seen += 1
      inject! if @seen >= @expected
    end

    # Tail-appends whatever is in the mailbox right now and reports how many. Called
    # at a batch boundary (#inject!) and ONCE MORE by the Executor when the run ended
    # with a message no boundary ever arrived for (a text-only turn closes no batch) —
    # the append, the running count and the `:turn_steered` event belong in one place
    # either way.
    def absorb_pending!
      texts = @actor.take_user_messages!
      return 0 if texts.empty?

      texts.each { |text| @chat.add_message(role: :user, content: @policy.frame(text)) }
      @injected += texts.size
      # Counts only, never content — the text is already in the transcript, which is the
      # surface that is allowed to carry it. `task_id`/`session_id` are the event's meta.
      @emit.call(:turn_steered, { count: texts.size, total: @injected })
      texts.size
    end

    private

    def open_batch(message)
      calls = field(message, :tool_calls)
      size = calls.respond_to?(:size) ? calls.size : 0
      # A message with no tool call is the model talking, not a batch: leave any
      # pending message where it is. The turn is about to end, and the Executor
      # absorbs it there in ONE extra round (#absorb_pending!) — a text-only turn
      # closes no batch, and answering it half-way is not an option.
      return @expected = nil if size.zero?

      @expected = size
      @seen = 0
      @halted = false
    end

    def inject!
      @expected = nil
      return if @halted # nothing will read it: leave it in the mailbox

      absorb_pending!
    end

    def halt?(result) = defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)

    def field(message, name)
      return message.public_send(name) if message.respond_to?(name)
      return message[name] || message[name.to_s] if message.respond_to?(:[])

      nil
    end
  end
end
