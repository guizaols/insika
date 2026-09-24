# frozen_string_literal: true

module Insika
  # WHERE a message that arrived mid-run is allowed to enter the
  # conversation.
  #
  # A customer who corrects themselves while the agent is calling tools ("1234567",
  # three seconds after "queria saber do pedido") should have that land before the
  # model's next reasoning step, not after the whole run. RubyLLM emits message
  # callbacks during both `chat.ask` and native steps. ToolBatch finds the last
  # sibling result so steering lands before the next model step.
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
      @batch = ToolBatch.new
      @injected = 0
    end

    # How many messages this run absorbed (read by specs and by the turn's event).
    attr_reader :injected

    # RubyLLM `after_tool_result`, with the RAW result — the only place a `Tool::Halt`
    # is still recognizable. By the time it becomes a `role: tool` message its content
    # is the payload, indistinguishable from an ordinary result.
    def tool_result(result) = @batch.halt!(result)

    # RubyLLM `after_message`. An assistant message carrying tool calls OPENS a batch;
    # the Nth tool result CLOSES it, and that is the one boundary where appending is
    # valid.
    def message_ended(message)
      inject! if @batch.closed?(message)
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

    def inject!
      return if @batch.halted? # nothing will read it: leave it in the mailbox

      absorb_pending!
    end
  end
end
