# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::Config do
  def profile(guardrails)
    Insika::AgentProfile.build(id: "x", guardrails: guardrails)
  end

  it "an agent with no guardrails config gets the conservative default (det on, moderator off)" do
    c = described_class.from_profile(profile(nil))
    expect(c.input).to be(true)
    expect(c.output).to be(true)
    expect(c.moderator?).to be(false)
    expect(c.strictness).to eq(:medium)
  end

  it "tolerates the JSON round-trip (string keys + string values)" do
    c = described_class.from_hash("input" => false, "output" => "true",
                                  "moderator" => "deepseek/deepseek-chat", "strictness" => "high")
    expect(c.input).to be(false)
    expect(c.output).to be(true)
    expect(c.moderator).to eq("deepseek/deepseek-chat")
    expect(c.strictness).to eq(:high)
  end

  it "reads native booleans and symbol keys" do
    c = described_class.from_hash(input: true, output: false)
    expect(c.input).to be(true)
    expect(c.output).to be(false)
  end

  it "coerces falsey strings to off, blank moderator to nil" do
    c = described_class.from_hash("input" => "0", "output" => "off", "moderator" => "  ")
    expect(c.input).to be(false)
    expect(c.output).to be(false)
    expect(c.moderator?).to be(false)
  end

  it "maps strictness to input categories (low = injection-only)" do
    expect(described_class.from_hash("strictness" => "low").input_categories).to eq(%i[injection])
    expect(described_class.from_hash("strictness" => "medium").input_categories).to eq(%i[injection sexual abuse])
    expect(described_class.from_hash("bogus" => 1).input_categories).to eq(%i[injection sexual abuse]) # default
  end

  it "an unknown strictness falls back to medium" do
    expect(described_class.from_hash("strictness" => "paranoid").strictness).to eq(:medium)
  end

  describe "corpora (RFC-0036 C2 — the removable language-tagged corpus)" do
    it "defaults to nil corpora — the full shipped corpus (parity)" do
      c = described_class.from_hash({})
      expect(c.corpora).to be_nil
      expect(c.corpus).to be_a(Insika::Safety::Corpus::Compiled)
      expect(c.corpus.languages).to eq(%w[pt-BR en])
      expect(c.corpus_languages).to eq(%w[pt-BR en])
    end

    it "round-trips corpora with string keys (JSON)" do
      c = described_class.from_hash("corpora" => { "languages" => ["en"], "extra" => { "abuse" => ["/\\bdupa\\b/i"] } })
      expect(c.corpus.languages).to eq(["en"])
      expect(c.corpus.input["abuse"]).to include(/\bdupa\b/i)
      expect(c.corpus.input["abuse"].first).to be_an(Regexp)
      expect(c.corpus_languages).to eq(["en"])
    end

    it "a languages-only corpora (nil languages) means all shipped languages" do
      c = described_class.from_hash("corpora" => { "extra" => { "abuse" => ["/\\bdupa\\b/i"] } })
      expect(c.corpus_languages).to eq(%w[pt-BR en])
      expect(c.corpus.input["abuse"]).to include(/\bdupa\b/i)
    end

    it "builds the compiled corpus ONCE per config" do
      c = described_class.from_hash("corpora" => { "languages" => ["en"] })
      expect(c.corpus).to equal(c.corpus)
    end

    it "an unknown language fails with the value named (boot/doctor, not mid-turn)" do
      expect { described_class.from_hash("corpora" => { "languages" => ["es"] }) }
        .to raise_error(Insika::ValidationError, /es/)
    end

    it "an unknown extra family fails with the name" do
      expect { described_class.from_hash("corpora" => { "extra" => { "nope" => ["/x/"] } }) }
        .to raise_error(Insika::ValidationError, /nope/)
    end

    it "a malformed pattern source fails with the pattern named" do
      expect { described_class.from_hash("corpora" => { "extra" => { "abuse" => ["(unclosed"] } }) }
        .to raise_error(Insika::ValidationError, /\(unclosed/)
    end
  end

  describe "responses (config-over-convention overrides)" do
    it "defaults to an empty override map" do
      expect(described_class.from_hash({}).responses).to eq({})
    end

    it "normalizes to string keys and drops blank values (JSON round-trip safe)" do
      c = described_class.from_hash("responses" => { injection: "X", "sexual" => "  ", "default" => "Y" })
      expect(c.responses).to eq("injection" => "X", "default" => "Y")
    end

    it "ignores a non-hash responses value" do
      expect(described_class.from_hash("responses" => "nope").responses).to eq({})
    end
  end
end
