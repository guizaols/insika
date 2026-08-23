# frozen_string_literal: true

require "spec_helper"

# WS9: the engine transports media — content parts normalize into typed
# text/image/audio parts; the STT seam is what a test stubs (the default fetch
# + RubyLLM transcription is lazy and network-bound, never unit-tested).
RSpec.describe Insika::Media do
  describe ".parts" do
    it "normalizes text/image/audio/document parts from string and symbol keys" do
      parts = described_class.parts([
        { "type" => "text", "text" => "oi" },
        { "type" => "image", "url" => "https://cdn.example.com/foto.png" },
        { "type" => "audio", "url" => "https://cdn.example.com/voz.ogg", "extra" => "ignored" },
        { "type" => "document", "url" => "https://cdn.example.com/receita.pdf" }
      ])

      expect(parts.map(&:type)).to eq(%w[text image audio document])
      expect(parts[0].text).to eq("oi")
      expect(parts[1].url).to eq("https://cdn.example.com/foto.png")
      expect(parts[2].audio?).to be(true)
      expect(parts[1].image?).to be(true)
      expect(parts[3].document?).to be(true)
    end

    it "skips malformed entries (a stray part must not break the turn)" do
      parts = described_class.parts([
        { "type" => "text" },            # no text
        { "type" => "image" },           # no url
        { "type" => "document" },        # no url
        { "type" => "video", "url" => "x" }, # unknown type
        "not a hash",
        nil
      ])
      expect(parts).to be_empty
    end

    it "nil/empty -> an empty list (a text-only message has no parts)" do
      expect(described_class.parts(nil)).to be_empty
      expect(described_class.parts([])).to be_empty
    end

    it "audio_parts / image_parts / document_parts partition" do
      parts = described_class.parts([
        { "type" => "audio", "url" => "a" }, { "type" => "image", "url" => "i" },
        { "type" => "document", "url" => "d" }
      ])
      expect(described_class.audio_parts(parts).map(&:url)).to eq(["a"])
      expect(described_class.image_parts(parts).map(&:url)).to eq(["i"])
      expect(described_class.document_parts(parts).map(&:url)).to eq(["d"])
    end
  end

  describe ".well_formed?" do
    it "accepts every well-formed text/image/audio/document part (string or symbol keys)" do
      expect(described_class.well_formed?([
        { "type" => "text", "text" => "oi" },
        { text: "linha1" }, # untyped = a bare text part (the joiner's shape)
        { type: "image", url: "https://cdn.example.com/f.png" },
        { type: "audio", url: "https://cdn.example.com/v.ogg" },
        { type: "document", url: "https://cdn.example.com/r.pdf" }
      ])).to be(true)
    end

    it "rejects any malformed entry — the edge's 422 contract" do
      expect(described_class.well_formed?([{ "type" => "text" }])).to be(false)   # no text
      expect(described_class.well_formed?([{ "type" => "image" }])).to be(false)  # no url
      expect(described_class.well_formed?([{ "type" => "document" }])).to be(false) # no url
      expect(described_class.well_formed?([{ "type" => "video", "url" => "x" }])).to be(false)
      expect(described_class.well_formed?(["not a hash"])).to be(false)
      expect(described_class.well_formed?([nil])).to be(false)
    end

    it "nil/empty parts -> true (no contract to break)" do
      expect(described_class.well_formed?(nil)).to be(true)
      expect(described_class.well_formed?([])).to be(true)
    end
  end

  describe ".channel_capabilities" do
    it "reads the declared output media kinds from string OR symbol keys" do
      expect(described_class.channel_capabilities({ "capabilities" => %w[image_output] }))
        .to eq(%w[image_output])
      expect(described_class.channel_capabilities({ capabilities: %w[image_output audio_output] }))
        .to eq(%w[image_output audio_output])
    end

    it "a channel without capabilities (or absent) declares nothing" do
      expect(described_class.channel_capabilities({})).to be_empty
      expect(described_class.channel_capabilities(nil)).to be_empty
    end

    it "the closed capability list is the edges' allowlist" do
      expect(described_class::OUTPUT_CAPABILITIES).to eq(%w[image_output audio_output])
    end
  end

  # The comment on fetch_binary promised an opt-out ("unless the deployment
  # opts out") that the call did not pass: http:// media ALWAYS failed, however
  # the deployment was configured.
  describe "egress opt-out (INSIKA_EGRESS_ALLOW_HTTP / _ALLOW_PRIVATE)" do
    around do |example|
      original = ENV.values_at("INSIKA_EGRESS_ALLOW_HTTP", "INSIKA_EGRESS_ALLOW_PRIVATE")
      example.run
      ENV["INSIKA_EGRESS_ALLOW_HTTP"] = original[0]
      ENV["INSIKA_EGRESS_ALLOW_PRIVATE"] = original[1]
    end

    it "https-only and private-blocked by default (strict guard)" do
      ENV.delete("INSIKA_EGRESS_ALLOW_HTTP")
      ENV.delete("INSIKA_EGRESS_ALLOW_PRIVATE")
      expect(described_class.egress_opt_out).to eq(allow_http: false, allow_private: false)
      expect { described_class.fetch_binary("http://media.test/a.ogg") }
        .to raise_error(Insika::MediaError, /http not allowed/)
    end

    it "the env opt-out reaches the guard (a local run over http:// gets through it)" do
      ENV["INSIKA_EGRESS_ALLOW_HTTP"] = "1"
      ENV["INSIKA_EGRESS_ALLOW_PRIVATE"] = "1"
      expect(described_class.egress_opt_out).to eq(allow_http: true, allow_private: true)
      # the guard sees the opt-out and passes; the socket (stubbed — no network
      # in a spec) is what fails from here, never the policy
      expect(Insika::EgressGuard).to receive(:violation)
        .with("http://127.0.0.1:3000/a.ogg", allow_http: true, allow_private: true).and_return(nil)
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      expect { described_class.fetch_binary("http://127.0.0.1:3000/a.ogg") }
        .to raise_error(Errno::ECONNREFUSED)
    end
  end

  describe ".url_attachment" do
    it "fetches through the CAPPED, egress-guarded fetch and wraps bytes we hold (no URL left for the gem)" do
      require "ruby_llm"
      png = "\x89PNG\r\n\x1a\n".b + ("x" * 64)
      expect(described_class).to receive(:fetch_binary)
        .with("https://cdn.example.com/foto.png", max_bytes: 123).and_return(png)

      attachment = described_class.url_attachment("https://cdn.example.com/foto.png", max_bytes: 123)

      expect(attachment.url?).to be(false)
      expect(attachment.content).to eq(png)
      expect(attachment.mime_type).to eq("image/png")
    end

    it "defaults to MAX_IMAGE_BYTES when the caller names no cap" do
      allow(described_class).to receive(:fetch_binary).and_return("x")
      described_class.url_attachment("https://cdn.example.com/foto.png")
      expect(described_class).to have_received(:fetch_binary)
        .with("https://cdn.example.com/foto.png", max_bytes: described_class::MAX_IMAGE_BYTES)
    end
  end

  describe "STT vocabulary prompt" do
    it "default_transcriber forwards stt_prompt to fetch_and_transcribe" do
      calls = []
      allow(described_class).to receive(:fetch_and_transcribe) { |url, **kwargs| calls << [url, kwargs]; "ok" }

      transcriber = described_class.default_transcriber(stt_model: "whisper-1", stt_prompt: "Ocean Drop, tênis")
      transcriber.call("https://cdn.example.com/voz.ogg")

      expect(calls).to eq([["https://cdn.example.com/voz.ogg",
                            { model: "whisper-1", language: nil, prompt: "Ocean Drop, tênis" }]])
    end

    it "fetch_and_transcribe passes prompt: to the provider only when present, via a tempfile PATH" do
      require "ruby_llm"
      allow(described_class).to receive(:fetch_binary).and_return("bytes")
      transcription = double("transcription", text: "oi")
      sent_path = nil
      allow(RubyLLM::Transcription).to receive(:transcribe) do |path, **kwargs|
        sent_path = path
        expect(kwargs).to eq(model: "whisper-1", prompt: "Ocean Drop")
        expect(File.binread(path)).to eq("bytes")
        transcription
      end

      result = described_class.fetch_and_transcribe("https://cdn.example.com/voz.ogg", model: "whisper-1",
                                                     language: nil, prompt: "Ocean Drop")
      expect(result).to eq("oi")
      # the tempfile is cleaned up by the time the block returns — a real path
      # RubyLLM could re-read past the call would leak a file per transcription.
      expect(File.exist?(sent_path)).to be(false)
    end
  end

  describe Insika::Media::Output do
    it "the default seams return [part, usage] pairs keyed by media kind" do
      seams = described_class.defaults(context: nil)
      expect(seams.keys).to eq(%i[image tts])
    end

    describe ".generate_image (text-to-image + editing)" do
      def fake_image
        img = Object.new
        def img.data = "QUJD"
        def img.mime_type = "image/png"
        def img.model_id = "gpt-image-1"
        def img.usage = { input_tokens: 5, output_tokens: 3 }
        img
      end

      # A tiny paint double capturing the kwargs — the provider boundary
      # itself is untested here (RubyLLM's own specs cover the HTTP call).
      def fake_context(image)
        calls = []
        ctx = Object.new
        ctx.define_singleton_method(:paint) { |prompt, **kwargs| calls << kwargs.merge(prompt: prompt); image }
        ctx.define_singleton_method(:calls) { calls }
        ctx.define_singleton_method(:config) { Struct.new(:default_image_model).new(nil) }
        ctx
      end

      it "no sources: paint(with: nil, mask: nil) — byte-identical to the pre-editing call" do
        context = fake_context(fake_image)
        part, usage = described_class.generate_image("a red sofa", config: {}, context: context)

        expect(context.calls.last).to include(with: nil, mask: nil, size: "1024x1024")
        expect(part).to include("type" => "image", "base64" => "QUJD")
        expect(usage).to eq(input_tokens: 5, output_tokens: 3)
      end

      it "source_urls fetch through Media.url_attachment (capped at MAX_SOURCE_IMAGES) and ride paint(with:)" do
        context = fake_context(fake_image)
        attachments = Array.new(5) { Object.new }
        urls = Array.new(5) { |i| "https://cdn.example.com/foto#{i}.png" }
        urls.each_with_index do |url, i|
          allow(Insika::Media).to receive(:url_attachment)
            .with(url, max_bytes: Insika::Media::MAX_IMAGE_BYTES).and_return(attachments[i])
        end

        described_class.generate_image("edit it", config: { "source_urls" => urls }, context: context)

        expect(context.calls.last[:with]).to eq(attachments.first(described_class::MAX_SOURCE_IMAGES))
        expect(context.calls.last[:mask]).to be_nil
      end

      it "mask_url rides paint(mask:)" do
        context = fake_context(fake_image)
        mask = Object.new
        allow(Insika::Media).to receive(:url_attachment)
          .with("https://cdn.example.com/mask.png", max_bytes: Insika::Media::MAX_IMAGE_BYTES).and_return(mask)

        described_class.generate_image("edit", config: { "mask_url" => "https://cdn.example.com/mask.png" },
                                        context: context)

        expect(context.calls.last[:mask]).to eq(mask)
        expect(context.calls.last[:with]).to be_nil
      end

      it "pre-built source_attachments (the tool's default-source path) skip the URL fetch entirely" do
        context = fake_context(fake_image)
        attachment = Object.new
        expect(Insika::Media).not_to receive(:url_attachment)

        described_class.generate_image("edit the photo", config: { "source_attachments" => [attachment] },
                                        context: context)

        expect(context.calls.last[:with]).to eq([attachment])
      end
    end
  end
end