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
    #
    # RFC-0042: also EDITS — `source_image_urls` (or, absent that, the turn's
    # own inbound photo) rides `paint(with:)`; `mask_url` rides `paint(mask:)`.
    # What the edit MEANS (a try-on, a mockup) is the skill's business; this
    # tool only transports the bytes.
    class GenerateImage < RubyLLM::Tool
      description "Generate an image, or EDIT one, and attach it to the reply as an " \
                  "output part. Use when the customer asked for a picture, or asked to " \
                  "transform/edit a photo (a virtual try-on, a mockup on their wall, a " \
                  "touch-up). Omitting source_image_urls generates a new image from the " \
                  "prompt alone — UNLESS this turn carries an inbound photo, in which case " \
                  "that photo is edited by default (pass source_image_urls explicitly to " \
                  "generate from scratch instead)."
      # explicit JSON-schema form (the `param` DSL only reaches strings/scalars,
      # and source_image_urls needs a typed array — the bare-array gotcha, #128).
      params(
        type: "object",
        properties: {
          prompt: { type: "string", description: "What to draw, or what edit to make, in detail" },
          size: { type: "string",
                  description: "Optional canvas size, e.g. 1024x1024 (default from the agent config)" },
          source_image_urls: {
            type: "array",
            description: "Image URLs to edit instead of generating from scratch — e.g. " \
                         "the photo the customer just sent in this conversation " \
                         "({{ctx.image_url}}), or any other URL from this chat. Omit to use " \
                         "the turn's inbound photo by default (if any), or to generate a " \
                         "fresh image when there is none.",
            items: { type: "string" }
          },
          mask_url: { type: "string",
                      description: "Optional mask image URL marking which area of the " \
                                   "source(s) to edit (transparent = editable)" }
        },
        required: %w[prompt]
      )

      def name = "generate_image"

      # runner: a duck exposing #generate_media_output(:image, prompt, config)
      # -> [part, usage] and #account_media_usage(part, usage) (the Executor).
      def initialize(runner:, config:, state:, **)
        @runner = runner
        @config = config
        @state = state
        super()
      end

      def execute(prompt:, size: nil, source_image_urls: nil, mask_url: nil)
        cfg = @config.merge("size" => size.to_s, "mask_url" => mask_url.to_s)
                      .reject { |_, v| v.to_s.empty? }
        cfg = cfg.merge(source_config(source_image_urls))
        part, usage = @runner.generate_media_output(:image, prompt.to_s, cfg)
        @state.output_parts << part
        @runner.account_media_usage(@state, part, usage)
        "image generated and attached to the reply (#{part["mime_type"]})"
      end

      private

      # Explicit URLs win over the default; a turn with inbound images (no
      # explicit URLs) hands `Output.generate_image` the ALREADY-FETCHED
      # attachments (bypassing the URL fetch — they are bytes we hold).
      def source_config(source_image_urls)
        urls = Array(source_image_urls).map(&:to_s).reject(&:empty?)
        return { "source_urls" => urls } if urls.any?
        return {} unless Array(@state.image_attachments).any?

        { "source_attachments" => @state.image_attachments }
      end
    end
  end
end