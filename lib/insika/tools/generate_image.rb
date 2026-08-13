# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # The agent's IMAGE output (WS9, saída). The engine transports media, never
    # meaning: what the image IS for (a virtual try-on, a product mockup) is the
    # skill's business — the contract here just produces the bytes and carries
    # them in the turn's `output_parts`.
    #
    # Wired ONLY when both gates pass (ChatBuilder): the agent opted in
    # (`outputs.image`) AND the channel declared it can receive the media
    # (`channel.capabilities` includes "image_output") — nothing leaks by
    # default. The image is an envelope part, never part of the answer text;
    # the provider's tokens are merged into the turn's usage like any ask.
    class GenerateImage < RubyLLM::Tool
      description "Generate an image and attach it to the reply as an output part. " \
                  "Use when the customer asked for a picture or an image would help."
      param :prompt, desc: "What to draw, in detail"
      param :size, desc: "Optional canvas size, e.g. 1024x1024 (default from the agent config)",
            required: false

      def name = "generate_image"

      # runner: a duck exposing #generate_media_output(:image, prompt, config)
      # -> [part, usage] and #account_media_usage(part, usage) (the Executor).
      def initialize(runner:, config:, state:, **)
        @runner = runner
        @config = config
        @state = state
        super()
      end

      def execute(prompt:, size: nil)
        cfg = @config.merge("size" => size.to_s).reject { |_, v| v.to_s.empty? }
        part, usage = @runner.generate_media_output(:image, prompt.to_s, cfg)
        @state.output_parts << part
        @runner.account_media_usage(@state, part, usage)
        "image generated and attached to the reply (#{part["mime_type"]})"
      end
    end
  end
end