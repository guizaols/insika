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

  describe Insika::Media::Output do
    it "the default seams return [part, usage] pairs keyed by media kind" do
      seams = described_class.defaults(context: nil)
      expect(seams.keys).to eq(%i[image tts])
    end
  end
end