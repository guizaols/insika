# frozen_string_literal: true

module Insika
  # WS9: the engine transports MEDIA, never meaning. Content parts ride the
  # message contract — `{ "type": "text", "text": … }`, `{ "type": "image",
  # "url": … }`, `{ "type": "audio", "url": … }`, `{ "type": "document",
  # "url": … }` — and the Executor turns them into a turn: audio is
  # transcribed (text marked `source: :voice`), images and documents attach
  # to the model ask and the first URL of each kind is `{{ctx.image_url}}` /
  # `{{ctx.document_url}}` for data tools. This class owns the PURE parts
  # (normalization) and the STT SEAM (injectable — specs stub it; the default
  # fetches the audio and transcribes via RubyLLM behind a lazy require, so
  # the core stays gem-free at load). `Media::Output` is the generated-media
  # half (WS9, saída): the turn can PRODUCE an image or an audio clip when the
  # agent opted in (`AgentProfile#outputs`) AND the channel declared it can
  # receive it (`channel.capabilities`) — nothing leaks by default.
  module Media
    # A single content part, normalized.
    Part = Data.define(:type, :text, :url) do
      def audio? = type == "audio"
      def image? = type == "image"
      def document? = type == "document"
      def text? = type == "text"
    end

    # -> [Part]: normalize the raw parts (string|symbol keys), skipping anything
    # that is not a well-formed text/image/audio/document part. Lenient on
    # purpose — the SURFACE validates the contract with `well_formed?` (a
    # malformed part is a 422 before dispatch); here a stray entry must not
    # break the turn.
    def self.parts(raw)
      Array(raw).filter_map do |p|
        next unless p.is_a?(Hash)

        type = (p[:type] || p["type"]).to_s
        url = (p[:url] || p["url"]).to_s
        text = (p[:text] || p["text"]).to_s
        case type
        when "text" then text.empty? ? nil : Part.new("text", text, nil)
        when "image", "audio", "document" then url.empty? ? nil : Part.new(type, nil, url)
        else nil
        end
      end
    end

    # The SURFACE's contract check (server edge): true when EVERY entry is a
    # well-formed content part — a Hash whose type is text (with text), image,
    # audio or document (with url). The edge raises a 422 on the first
    # offender; the engine itself stays lenient (`parts` skips strays so a
    # non-HTTP transport that bypassed the edge cannot break a turn).
    def self.well_formed?(raw)
      Array(raw).all? do |p|
        next false unless p.is_a?(Hash)

        case (p[:type] || p["type"]).to_s
        when "text" then !(p[:text] || p["text"]).to_s.empty?
        when "image", "audio", "document" then !(p[:url] || p["url"]).to_s.empty?
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
    MAX_DOCUMENT_BYTES = 10_000_000 # a prescription, not an archive

    def self.audio_parts(parts) = parts.select(&:audio?)
    def self.image_parts(parts) = parts.select(&:image?)
    def self.document_parts(parts) = parts.select(&:document?)

    # The STT seam: ->(url) { text } (default: fetch + RubyLLM transcription).
    # Injected so a spec never touches the network; the default is built lazily
    # when the turn first carries audio. `stt_prompt` is the Whisper-family
    # vocabulary hint (product names, brand terms) — OPERATOR config
    # (agent profile / deployment env), never customer input.
    def self.default_transcriber(stt_model:, stt_language: nil, stt_prompt: nil)
      lambda do |url|
        fetch_and_transcribe(url, model: stt_model, language: stt_language, prompt: stt_prompt)
      end
    end

    # A file PATH, not bytes and not an Attachment: `RubyLLM::Transcription.
    # transcribe` hands its argument to the PROVIDER's own `transcribe`, and the
    # two shapes in this gem disagree — Gemini wraps it in `Attachment.new`
    # itself (a raw byte String there is misread as a Pathname and blows up on
    # any embedded null byte, which real audio has), while the DEFAULT
    # `Provider#transcribe` (OpenAI, Mistral) calls `File.expand_path` on it
    # directly and cannot take bytes/IO/Attachment at all. A tempfile is the
    # one shape both accept. `assume_model_exists` is deliberately NOT passed:
    # RubyLLM raises ArgumentError when it's true without an explicit
    # `provider` (see ModelSelection#assume_model_exists?), and `stt_model` here
    # is a bare ref like `utility_model` elsewhere — the registry resolves it.
    def self.fetch_and_transcribe(url, model:, language:, prompt: nil)
      require "net/http"
      require "uri"
      require "ruby_llm" # lazy — the core loads without it (load-guard)
      require "tempfile"

      bytes = fetch_binary(url)
      options = { model: model }
      options[:language] = language if language
      options[:prompt] = prompt if prompt
      Tempfile.create(["insika-media-", File.extname(filename_for(url).to_s)]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        RubyLLM::Transcription.transcribe(file.path, **options).text
      end
    end

    # An inbound URL -> a RubyLLM::Attachment over bytes WE fetched (egress-
    # guarded, size-capped — the `media_attachment` recipe). Shared by the
    # Executor (inbound image/document parts) and `Output.generate_image`
    # (edit sources / mask): an io-like source (StringIO) is the branch of
    # Attachment that takes bytes already held, so the provider gets base64
    # rather than the URL — handing the raw URL to RubyLLM instead would leave
    # the (uncapped) fetch to the gem.
    def self.url_attachment(url, max_bytes: MAX_IMAGE_BYTES)
      require "ruby_llm"
      require "stringio"

      bytes = fetch_binary(url, max_bytes: max_bytes)
      RubyLLM::Attachment.new(StringIO.new(bytes), filename: filename_for(url))
    end

    # The URL's basename, for the attachment's mime sniff (".png" -> image/png;
    # a URL with no filename falls back to the content sniff RubyLLM does).
    def self.filename_for(url)
      require "uri"
      name = File.basename(URI.parse(url).path.to_s)
      name.empty? ? nil : name
    rescue URI::InvalidURIError
      nil
    end

    # Egress-guarded binary fetch of a media URL. Blocked like the webhook: the
    # url is consumer config/input, so a private/loopback/metadata target is
    # refused (SSRF) unless the deployment opts out. Size-capped (the caller
    # picks the ceiling; the default is the audio one).
    def self.fetch_binary(url, max_bytes: MAX_AUDIO_BYTES)
      violation = Insika::EgressGuard.violation(url, **egress_opt_out)
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

    # The opt-out the comment above promises, read from the SAME env the
    # data-tool guard reads (INSIKA_EGRESS_ALLOW_HTTP / _ALLOW_PRIVATE): without
    # this, a local run serving media over http:// ALWAYS failed, however the
    # deployment was configured. INSIKA_EGRESS_HOSTS is deliberately NOT applied:
    # that allowlist pins the handful of hosts a tool may call, while media URLs
    # come from the channel's CDN — honouring it here would break every real
    # deployment that narrows its tools.
    def self.egress_opt_out
      { allow_http: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_HTTP"]),
        allow_private: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_PRIVATE"]) }
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
      # Edit sources on one `paint(with:)` call — a fitting room needs a
      # handful of angles, not a gallery.
      MAX_SOURCE_IMAGES = 4

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

        # -> [Part, usage]: paint via RubyLLM — text-to-image when the config
        # carries no sources (byte-identical to before this call), image
        # EDITING when it does: `source_urls`/`source_attachments` ride
        # `paint(with:)`, `mask_url` rides `paint(mask:)`. usage is the
        # provider's token counts ({ input_tokens:, output_tokens: } — merged
        # into the turn's usage by the Executor); a provider without counts
        # reports nothing.
        def generate_image(prompt, config:, context:)
          require "ruby_llm" # lazy — the core loads without it (load-guard)

          cfg = Insika::Coercion.deep_stringify(config || {})
          model = Insika::Coercion.presence(cfg["model"]) || image_model(context)
          # `assume_model_exists` is deliberately NOT passed: RubyLLM raises
          # ArgumentError when it's true without an explicit `provider` (see
          # ModelSelection#assume_model_exists?), and `model` here is a bare
          # ref like `utility_model` elsewhere — the registry resolves it.
          api = context || RubyLLM
          image = api.paint(prompt.to_s, model: model,
                                          size: presence(cfg["size"]) || DEFAULT_IMAGE_SIZE,
                                          with: source_attachments(cfg), mask: mask_attachment(cfg))
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

        # -> [Attachment] | nil: the edit sources for `paint(with:)`. Pre-built
        # attachments win (the tool's DEFAULT source — the turn's own inbound
        # images, already fetched bytes, no URL round-trip); otherwise explicit
        # `source_urls` are fetched through the SAME capped, egress-guarded
        # path images always used. nil (never []) when there are none — a
        # provider without OpenAI's `editing?` leniency raises on a non-nil
        # `with:`, and a text-to-image turn must stay byte-identical.
        def source_attachments(cfg)
          built = cfg["source_attachments"]
          return built if built.is_a?(Array) && built.any?

          urls = Array(cfg["source_urls"]).map(&:to_s).reject(&:empty?).first(MAX_SOURCE_IMAGES)
          urls.empty? ? nil : urls.map { |u| Insika::Media.url_attachment(u, max_bytes: Insika::Media::MAX_IMAGE_BYTES) }
        end

        # -> Attachment | nil: the optional edit mask for `paint(mask:)`.
        def mask_attachment(cfg)
          url = presence(cfg["mask_url"])
          return nil unless url

          Insika::Media.url_attachment(url, max_bytes: Insika::Media::MAX_IMAGE_BYTES)
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