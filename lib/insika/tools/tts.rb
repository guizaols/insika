# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # The agent's SPEECH output (WS9, saída). The engine transports media, never
    # meaning: the words belong to the customer's channel (a voice note on
    # WhatsApp), and the contract here just produces the audio bytes and carries
    # them in the turn's `output_parts`.
    #
    # Wired ONLY when both gates pass (ChatBuilder): the agent opted in
    # (`outputs.tts`) AND the channel declared it can receive the media
    # (`channel.capabilities` includes "audio_output") — nothing leaks by
    # default. The clip is an envelope part, never part of the answer text;
    # the turn counts the call in its usage (`usage.media`) — the provider's
    # speech API reports no token counts, so the part carries the model for
    # consumer-side pricing.
    class Tts < RubyLLM::Tool
      description "Synthesize speech for the reply — a voice clip travels as an " \
                  "output part in the envelope, the channel supports it. Use when the " \
                  "customer should HEAR the answer rather than read it."
      param :text, desc: "The words to speak"
      param :voice, desc: "Optional voice override (default from the agent config)",
            required: false

      def name = "tts"

      # runner: a duck exposing #generate_media_output(:tts, text, config)
      # -> [part, usage] and #account_media_usage(part, usage) (the Executor).
      def initialize(runner:, config:, state:, **)
        @runner = runner
        @config = config
        @state = state
        super()
      end

      def execute(text:, voice: nil)
        cfg = @config.merge("voice" => voice.to_s).reject { |_, v| v.to_s.empty? }
        part, usage = @runner.generate_media_output(:tts, text.to_s, cfg)
        @state.output_parts << part
        @runner.account_media_usage(@state, part, usage)
        "speech synthesized and attached to the reply (#{part["mime_type"]})"
      end
    end
  end
end