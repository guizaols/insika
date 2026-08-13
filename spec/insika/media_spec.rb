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
end