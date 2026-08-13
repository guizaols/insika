# frozen_string_literal: true

module Insika
  # WS9: the engine transports MEDIA, never meaning. Content parts ride the
  # message contract — `{ "type": "text", "text": … }`, `{ "type": "image",
  # "url": … }`, `{ "type": "audio", "url": … }` — and the Executor turns them
  # into a turn: audio is transcribed (text marked `source: :voice`), images
  # attach to the model ask. This class owns the PURE parts (normalization) and
  # the STT SEAM (injectable — specs stub it; the default fetches the audio and
  # transcribes via RubyLLM behind a lazy require, so the core stays gem-free
  # at load).
  module Media
    # A single content part, normalized.
    Part = Data.define(:type, :text, :url) do
      def audio? = type == "audio"
      def image? = type == "image"
      def text? = type == "text"
    end

    # -> [Part]: normalize the raw parts (string|symbol keys), skipping anything
    # that is not a well-formed text/image/audio part. Lenient on purpose — the
    # SURFACE validates the contract (a malformed part is a 422 before dispatch);
    # here a stray entry must not break the turn.
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
    # refused (SSRF) unless the deployment opts out. Size-capped (1 MB — a voice
    # note, not a warehouse).
    def self.fetch_binary(url, max_bytes: 1_000_000)
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
  end
end