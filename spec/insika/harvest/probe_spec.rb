# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Harvest::Probe do
  def msg(role, content) = { "role" => role, "content" => content }

  def verdict(outcome, reason: "r")
    Insika::Evals::Pairwise::Verdict.new(outcome: outcome, reason: reason, vs: "agent",
                                         judges: [outcome], order_dependent: false)
  end

  describe ".cases" do
    let(:session) do
      [msg("user", "oi"), msg("assistant", "olá"), msg("user", "tem pix?"),
       msg("assistant", "não sei"), msg("user", "e boleto?"), msg("assistant", "sim")]
    end

    it "keeps the customer turns up to the last evidence turn" do
      expect(described_class.cases([session], evidence_turns: [3])).to eq([["oi", "tem pix?"]])
    end

    it "uses the whole session when there is no usable evidence turn" do
      expect(described_class.cases([session], evidence_turns: [])).to eq([["oi", "tem pix?", "e boleto?"]])
      expect(described_class.cases([session], evidence_turns: [99])).to eq([["oi", "tem pix?", "e boleto?"]])
    end

    it "caps turns per case and the number of cases" do
      cases = described_class.cases([session] * 5, evidence_turns: [], max_cases: 2, max_turns: 1)
      expect(cases).to eq([["oi"], ["oi"]])
    end

    it "drops sessions with no customer text" do
      expect(described_class.cases([[msg("assistant", "olá")], []], evidence_turns: [])).to eq([])
    end
  end

  describe ".verdict" do
    it "passes with at least one better and no worse" do
      v = described_class.verdict([verdict("better"), verdict("comparable")])
      expect(v).to include("passed" => true, "reason" => nil, "better" => 1, "comparable" => 1, "worse" => 0, "cases" => 2)
    end

    it "fails on any worse, naming the judge's reason" do
      v = described_class.verdict([verdict("better"), verdict("worse", reason: "inventou preço")])
      expect(v["passed"]).to be(false)
      expect(v["reason"]).to match(/probe_worse.*inventou preço/)
    end

    it "fails when nothing got better — split, unknown and nil count as not better" do
      v = described_class.verdict([verdict("comparable"), verdict("split"), verdict("unknown"), nil])
      expect(v["passed"]).to be(false)
      expect(v["reason"]).to match(/probe_no_gain/)
      expect(v["comparable"]).to eq(4)
    end
  end
end
