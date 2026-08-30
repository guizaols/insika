# frozen_string_literal: true

module Insika
  # The batch arithmetic behind every mid-turn `user` append.
  #
  # A model step that calls tools produces ONE assistant message announcing N
  # tool calls, followed by N `role: tool` messages. Anthropic rejects a `user`
  # message that lands between two of those results outright, so the ONLY valid
  # append point inside a turn is the instant the Nth result closes the batch.
  # SteerInjector discovered this rule; LoopDetector and TurnBudget both live by
  # it, which is why the counting lives here instead of twice.
  #
  # Not a general-purpose helper: it answers one question ("did a batch just
  # close?") and remembers one fact ("was this batch halted"), because a
  # `halt_when` batch has no next model step and anything appended there would
  # sit unread forever.
  class ToolBatch
    def initialize
      @expected = nil # tool calls announced by the batch in flight (nil = none)
      @seen = 0
      @halted = false
    end

    # Feeds a RubyLLM message (duck-typed). True EXACTLY on the message that
    # closes a batch of tool calls — the append boundary. Everything else,
    # including the assistant message that opens the batch, is false.
    def closed?(message)
      role = field(message, :role).to_s
      return open(message) if role == "assistant"
      return false unless role == "tool" && @expected

      @seen += 1
      return false if @seen < @expected

      @expected = nil
      true
    end

    # From after_tool_result, with the RAW result: a Tool::Halt is only
    # recognizable there.
    def halt!(result)
      @halted = true if defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)
    end

    def halted? = @halted

    private

    # An assistant message with no tool calls is the model TALKING: the turn is
    # ending, so nothing is in flight any more.
    def open(message)
      calls = field(message, :tool_calls)
      size = calls.respond_to?(:size) ? calls.size : 0
      @expected = size.zero? ? nil : size
      @seen = 0
      @halted = false
      false
    end

    def field(message, name)
      return message.public_send(name) if message.respond_to?(name)
      return message[name] || message[name.to_s] if message.respond_to?(:[])

      nil
    end
  end
end
