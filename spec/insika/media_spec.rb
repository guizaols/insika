# frozen_string_literal: true

require "spec_helper"

# WS9: the engine transports media — content parts normalize into typed
# text/image/audio parts; the STT seam is what a test stubs (the default fetch
# + RubyLLM transcription is lazy and network-bound, never unit-tested).
RSpec.describe Insika::Media do
  describe ".parts" do
    it "normalizes text/image/audio parts from string and symbol keys" do
      parts = described_class.parts([
        { "type" => "text", "text" => "oi" },
        { "type" => "image", "url" => "https://cdn.example.com/foto.png" },
        { "type" => "audio", "url" => "https://cdn.example.com/voz.ogg", "extra" => "ignored" }
      ])

      expect(parts.map(&:type)).to eq(%w[text image audio])
      expect(parts[0].text).to eq("oi")
      expect(parts[1].url).to eq("https://cdn.example.com/foto.png")
      expect(parts[2].audio?).to be(true)
      expect(parts[1].image?).to be(true)
    end

    it "skips malformed entries (a stray part must not break the turn)" do
      parts = described_class.parts([
        { "type" => "text" },            # no text
        { "type" => "image" },           # no url
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

    it "audio_parts / image_parts partition" do
      parts = described_class.parts([
        { "type" => "audio", "url" => "a" }, { "type" => "image", "url" => "i" }
      ])
      expect(described_class.audio_parts(parts).map(&:url)).to eq(["a"])
      expect(described_class.image_parts(parts).map(&:url)).to eq(["i"])
    end
  end

  describe ".well_formed?" do
    it "accepts every well-formed text/image/audio part (string or symbol keys)" do
      expect(described_class.well_formed?([
        { "type" => "text", "text" => "oi" },
        { text: "linha1" }, # untyped = a bare text part (the joiner's shape)
        { type: "image", url: "https://cdn.example.com/f.png" },
        { type: "audio", url: "https://cdn.example.com/v.ogg" }
      ])).to be(true)
    end

    it "rejects any malformed entry — the edge's 422 contract" do
      expect(described_class.well_formed?([{ "type" => "text" }])).to be(false)   # no text
      expect(described_class.well_formed?([{ "type" => "image" }])).to be(false)  # no url
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

  describe Insika::Media::Output do
    it "the default seams return [part, usage] pairs keyed by media kind" do
      seams = described_class.defaults(context: nil)
      expect(seams.keys).to eq(%i[image tts])
    end
  end
end