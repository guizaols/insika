# frozen_string_literal: true

module Insika
  # WS9: the engine transports MEDIA, never meaning. Content parts ride the
  # message contract — `{ "type": "text", "text": … }`, `{ "type": "image",
  # "url": … }`, `{ "type": "audio", "url": … }` — and the Executor turns them
  # into a turn: audio is transcribed (text marked `source: :voice`), images
  # attach to the model ask. This class owns the PURE parts (normalization) and
  # the STT SEAM (injectable — specs stub it; the default fetches the audio and
  # transcribes via RubyLLM behind a lazy require, so the core stays gem-free
  # at load). `Media::Output` is the generated-media half (WS9, saída): the
  # turn can PRODUCE an image or an audio clip when the agent opted in
  # (`AgentProfile#outputs`) AND the channel declared it can receive it
  # (`channel.capabilities`) — nothing leaks by default.
  module Media
    # A single content part, normalized.
    Part = Data.define(:type, :text, :url) do
      def audio? = type == "audio"
      def image? = type == "image"
      def text? = type == "text"
    end

    # -> [Part]: normalize the raw parts (string|symbol keys), skipping anything
    # that is not a well-formed text/image/audio part. Lenient on purpose — the
    # SURFACE validates the contract with `well_formed?` (a malformed part is a
    # 422 before dispatch); here a stray entry must not break the turn.
    def self.parts(raw)
      Array(raw).filter_map do |p|
        next unless p.is_a?(Hash)

        type = (p[:type] || p["type"]).to_s
        url = (p[:url] || p["url"]).to_s
        text = (p[:text] || p["text"]).to_s
        case type
        when "text" then text.empty? ? nil : Part.new("text", text, nil)
        when "image", "audio" then url.empty? ? nil : Part.new(type, nil, url)
        else nil
        end
      end
    end

    # The SURFACE's contract check (server edge): true when EVERY entry is a
    # well-formed content part — a Hash whose type is text (with text), image
    # or audio (with url). The edge raises a 422 on the first offender; the
    # engine itself stays lenient (`parts` skips strays so a non-HTTP transport
    # that bypassed the edge cannot break a turn).
    def self.well_formed?(raw)
      Array(raw).all? do |p|
        next false unless p.is_a?(Hash)

        case (p[:type] || p["type"]).to_s
        when "text" then !(p[:text] || p["text"]).to_s.empty?
        when "image", "audio" then !(p[:url] || p["url"]).to_s.empty?
        # a part WITHOUT a type is admitted only as a bare text part (the
        # shape the input joiner already tolerates) — anything else is refused.
        when "" then !(p[:text] || p["text"]).to_s.empty?
        else false
        end
      end
    end

    # The OUTPUT media kinds a channel may declare it can receive
    # (`channel.capabilities`). The closed list is the "abstraction admits
    # only what leaks" rule: an unknown value is refused at the edge, never
    # silently ignored.
    OUTPUT_CAPABILITIES = %w[image_output audio_output].freeze

    # -> [String]: the capabilities a raw `channel` hash declares. Lenient on
    # the key spelling (symbol|string) at both boundaries (request parse vs
    # persisted command payload); [] = the channel declared nothing.
    def self.channel_capabilities(raw)
      channel = raw.is_a?(Hash) ? raw : {}
      Array(channel[:capabilities] || channel["capabilities"]).map(&:to_s)
    end

    # The ceilings on INBOUND media (a URL a consumer sent us). Both fetches
    # stream into the cap and refuse past it: the bytes land in THIS process,
    # so an uncapped one is a hostile URL away from growing it until it dies.
    MAX_AUDIO_BYTES = 1_000_000 # a voice note, not a warehouse
    MAX_IMAGE_BYTES = 5_000_000 # a photo, not a poster

    def self.audio_parts(parts) = parts.select(&:audio?)
    def self.image_parts(parts) = parts.select(&:image?)

    # The STT seam: ->(url) { text } (default: fetch + RubyLLM transcription).
    # Injected so a spec never touches the network; the default is built lazily
    # when the turn first carries audio.
    def self.default_transcriber(stt_model:, stt_language: nil)
      lambda do |url|
        fetch_and_transcribe(url, model: stt_model, language: stt_language)
      end
    end

    def self.fetch_and_transcribe(url, model:, language:)
      require "net/http"
      require "uri"
      require "ruby_llm" # lazy — the core loads without it (load-guard)

      bytes = fetch_binary(url)
      audio = RubyLLM::Attachment.new(bytes)
      options = { model: model, assume_model_exists: true }
      options[:language] = language if language
      RubyLLM::Transcription.transcribe(audio, **options).text
    end

    # Egress-guarded binary fetch of a media URL. Blocked like the webhook: the
    # url is consumer config/input, so a private/loopback/metadata target is
    # refused (SSRF) unless the deployment opts out. Size-capped (the caller
    # picks the ceiling; the default is the audio one).
    def self.fetch_binary(url, max_bytes: MAX_AUDIO_BYTES)
      violation = Insika::EgressGuard.violation(url)
      raise Insika::MediaError, "media egress blocked for #{url}: #{violation}" if violation

      uri = URI.parse(url)
      opts = { use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 60 }
      Net::HTTP.start(uri.host, uri.port, opts) do |http|
        buf = +"".b
        http.request(Net::HTTP::Get.new(uri)) do |resp|
          raise Insika::MediaError, "media fetch HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

          resp.read_body { |chunk| buf << chunk; break if buf.bytesize > max_bytes }
        end
        raise Insika::MediaError, "media exceeds #{max_bytes} bytes" if buf.bytesize > max_bytes
        buf
      end
    rescue URI::InvalidURIError
      raise Insika::MediaError, "invalid media URL"
    end

    # WS9 (saída): generated media. The OUTPUT shape is an additive part —
    # `{ "type": "image"|"audio", "mime_type": …, "base64": …, "model": … }`
    # — that rides the turn's `output_parts` (terminal event + /v1/responses
    # envelope), NEVER the answer text: the customer's channel consumes the
    # bytes, the model's prose stays the answer.
    #
    # The GENERATION SEAMS are injectable like the STT seam: each is a
    # `->(content, config) { [ part_hash, usage_hash ] }` (part_hash already
    # carries its "type"), specs stub them, and the defaults hit the provider
    # behind lazy requires:
    #  · image — RubyLLM.paint (the gem has vision AND painting), billed
    #    tokens merged into the turn's usage like any ask;
    #  · tts — RubyLLM still has NO speech API (as of 1.16.0), so the default
    #    is a thin POST to the OpenAI-compatible `<base>/audio/speech`
    #    endpoint (base + key from the provider config the chat uses — a
    #    deployment pointing OpenAI at a gateway keeps TTS pointing there).
    #    OpenAI's speech API reports no token usage; the part carries the
    #    model so the consumer can price it, and the turn counts the call.
    module Output
      DEFAULT_IMAGE_SIZE = "1024x1024"
      DEFAULT_TTS_MODEL = "tts-1"
      DEFAULT_TTS_VOICE = "alloy"
      DEFAULT_TTS_FORMAT = "mp3"
      # Base64 inlines into the envelope — a cap so a pathological generation
      # cannot blow up the SSE frame. A generated 1024x1024 PNG sits well under.
      MAX_EMBEDDED_BYTES = 8 * 1024 * 1024

      class << self
        # -> { image: seam, tts: seam } with the DEFAULTS bound to a context
        # (the graph's RubyLLM::Context when it owns credentials — nil = the
        # process-wide RubyLLM constant). Built lazily on first generation so
        # the core loads without ruby_llm (load-guard).
        def defaults(context:)
          {
            image: ->(prompt, config) { generate_image(prompt, config: config, context: context) },
            tts: ->(text, config) { synthesize_speech(text, config: config, context: context) }
          }
        end

        # -> [Part, usage]: paint via RubyLLM. usage is the provider's token
        # counts ({ input_tokens:, output_tokens: } — merged into the turn's
        # usage by the Executor); a provider without counts reports nothing.
        def generate_image(prompt, config:, context:)
          require "ruby_llm" # lazy — the core loads without it (load-guard)

          cfg = Insika::Coercion.deep_stringify(config || {})
          model = Insika::Coercion.presence(cfg["model"]) || image_model(context)
          api = context || RubyLLM
          image = api.paint(prompt.to_s, model: model, assume_model_exists: true,
                                          size: presence(cfg["size"]) || DEFAULT_IMAGE_SIZE)
          data = image.respond_to?(:data) ? image.data : nil
          raise Insika::MediaError, "image generation returned no embeddable data" if data.to_s.empty?

          enforce_embedded_size!(data, "generated image")
          mime = image.respond_to?(:mime_type) ? image.mime_type : nil
          model_id = image.respond_to?(:model_id) ? image.model_id : nil
          usage = image.respond_to?(:usage) ? token_usage(image.usage) : {}
          part = { "type" => "image", "mime_type" => presence(mime) || "image/png",
                   "base64" => data, "model" => presence(model_id) }
          [part.compact, usage]
        end

        # -> [Part, {}]: synthesize speech via the OpenAI-compatible
        # `<base>/audio/speech` endpoint. `context` supplies the base URL + key
        # (the same config the chat uses — see `speech_endpoint`). The bytes
        # embed base64 in the part; the usage is empty (no token counts on the
        # speech API) and the part carries the model for consumer-side pricing.
        def synthesize_speech(text, config:, context:)
          require "net/http"
          require "uri"
          require "json"
          require "base64"

          cfg = Insika::Coercion.deep_stringify(config || {})
          model = presence(cfg["model"]) || DEFAULT_TTS_MODEL
          voice = presence(cfg["voice"]) || DEFAULT_TTS_VOICE
          format = presence(cfg["format"]) || DEFAULT_TTS_FORMAT
          base, key = speech_endpoint(context)
          if key.to_s.empty?
            raise Insika::MediaError,
                  "TTS needs an OpenAI API key (provider config) — set it on the " \
                  "provider the agent uses, or inject a tts seam"
          end

          uri = URI.parse("#{base}/audio/speech")
          req = Net::HTTP::Post.new(uri)
          req["Authorization"] = "Bearer #{key}"
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(model: model, voice: voice, input: text.to_s,
                                   response_format: format)
          opts = { use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 60 }
          bytes = Net::HTTP.start(uri.host, uri.port, opts) do |http|
            resp = http.request(req)
            raise Insika::MediaError, "TTS HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

            # stream into the cap — a rogue/broken endpoint must not grow the
            # process past MAX_EMBEDDED_BYTES before the refusal.
            buf = +"".b
            resp.read_body do |chunk|
              buf << chunk
              break if buf.bytesize > MAX_EMBEDDED_BYTES
            end
            buf
          end
          enforce_embedded_size!(bytes, "synthesized speech")
          part = { "type" => "audio", "mime_type" => mime_for(format), "base64" => Base64.strict_encode64(bytes), "model" => model }
          [part.compact, {}]
        rescue URI::InvalidURIError
          raise Insika::MediaError, "invalid TTS endpoint"
        end

        private

        # The OpenAI-compatible base URL + key behind the chat's provider
        # config. A RubyLLM::Context owns the deployment's credentials; the
        # global config is the fallback (a graph without its own context).
        def speech_endpoint(context)
          config = context.respond_to?(:config) ? context.config : RubyLLM.config
          base = config.respond_to?(:openai_api_base) ? config.openai_api_base : nil
          key = config.respond_to?(:openai_api_key) ? config.openai_api_key : nil
          [presence(base) || "https://api.openai.com/v1", key]
        end

        def image_model(context)
          config = context.respond_to?(:config) ? context.config : RubyLLM.config
          config.respond_to?(:default_image_model) ? config.default_image_model : nil
        end

        def token_usage(raw)
          usage = raw.is_a?(Hash) ? raw : {}
          {
            input_tokens: usage[:input_tokens] || usage["input_tokens"] || usage["prompt_tokens"],
            output_tokens: usage[:output_tokens] || usage["output_tokens"] || usage["completion_tokens"]
          }.compact
        end

        def mime_for(format)
          { "mp3" => "audio/mpeg", "opus" => "audio/opus", "aac" => "audio/aac",
            "wav" => "audio/wav", "flac" => "audio/flac" }[format.to_s] || "audio/mpeg"
        end

        def enforce_embedded_size!(data, label)
          size = data.respond_to?(:bytesize) ? data.bytesize : data.to_s.bytesize
          return if size <= MAX_EMBEDDED_BYTES

          raise Insika::MediaError,
                "#{label} too large to embed (#{size} bytes > #{MAX_EMBEDDED_BYTES})"
        end

        def presence(value)
          Insika::Coercion.presence(value)
        end
      end
    end
  end
end