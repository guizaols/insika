# frozen_string_literal: true

require "spec_helper"

#   — a pure function: confirmed answer text -> [String] balloons.
# Paragraphs are the unit (E1 is about \n\n); the sentence split only fires as a
# soft cap after SENTENCE_AFTER. No pacing, no events, no outbox.
RSpec.describe Insika::BalloonSplitter do
  describe ".split" do
    it "returns [] for blank input" do
      expect(described_class.split("")).to eq([])
      expect(described_class.split("   ")).to eq([])
      expect(described_class.split(nil)).to eq([])
    end

    it "keeps a single short paragraph as one balloon" do
      expect(described_class.split("Oi, tudo bem?")).to eq(["Oi, tudo bem?"])
    end

    it "splits two paragraphs into two balloons" do
      expect(described_class.split("Para um.\n\nPara dois."))
        .to eq(["Para um.", "Para dois."])
    end

    it "drops a blank paragraph between two real ones" do
      expect(described_class.split("A\n\n\nB")).to eq(%w[A B])
    end

    it "splits an over-long paragraph on sentences (the soft cap)" do
      long = "#{'A' * 450}. Depois #{'B' * 450}."
      expect(long.length).to be > described_class::SENTENCE_AFTER

      balloons = described_class.split(long)
      expect(balloons.size).to eq(2)
      expect(balloons.join(" ")).to eq(long)
    end

    it "does not sentence-split a decimal or a bare period — and short text stays whole" do
      expect(described_class.split("3.9s no p50. Depois o resto."))
        .to eq(["3.9s no p50. Depois o resto."])
    end

    # the sentence split is a SOFT cap. Short sentences are
    # re-packed into ~SENTENCE_AFTER blocks; atomizing a 680-char paragraph
    # into one balloon per sentence would turn ONE bubble into 40 WhatsApp
    # messages for no latency win.
    it "re-groups short sentences into ~SENTENCE_AFTER blocks instead of atomizing the paragraph" do
      long = Array.new(40) { "Tudo certo, sim." }.join(" ")
      expect(long.length).to be > described_class::SENTENCE_AFTER

      balloons = described_class.split(long)
      expect(balloons.size).to eq(2)
      expect(balloons.join(" ")).to eq(long)
    end

    it "keeps the fence atomic when the closing ``` shares a paragraph with its code" do
      text = "Aqui está:\n\n```ruby\nx = 1\n```\n\nDeu certo?"
      expect(described_class.split(text))
        .to eq(["Aqui está:", "```ruby\nx = 1\n```", "Deu certo?"])
    end

    it "a fence whose opener and closer are in the same paragraph still closes there" do
      text = "```ruby\n\nx = 1\n```\n\ndepois"
      expect(described_class.split(text)).to eq(["```ruby\n\nx = 1\n```", "depois"])
    end

    it "keeps a fenced code block atomic even when it spans paragraphs" do
      text = "```\n\ncode\n\n```\n\ndepois"
      expect(described_class.split(text)).to eq(["```\n\ncode\n\n```", "depois"])
    end

    it "a single newline is not a paragraph break" do
      expect(described_class.split("Olá!\nAinda o mesmo."))
        .to eq(["Olá!\nAinda o mesmo."])
    end

    it "strips each balloon and drops empties left by the sentence split" do
      text = "Primeiro.   \n\n   Segundo.   "
      expect(described_class.split(text)).to eq(["Primeiro.", "Segundo."])
    end
  end
end