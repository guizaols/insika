# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../evals/lib/evals/assertions"
require_relative "../../evals/lib/evals/judge"
require_relative "../../evals/lib/evals/baseline"

# Fase C gating (RFC-0008 §3.4). Regression = a passing case that now fails, or a
# judge score that dropped past the tolerance. Known failures never block.
RSpec.describe Evals::Baseline do
  def case_result(id, pass:, score: nil)
    judge = score && Evals::Judge::Verdict.new(score: score, pass: score >= 0.7, reason: "")
    Evals::CaseResult.new(id: id, agent: "bia", error: nil, rubric: (score && "r"), judge: judge,
                          checks: [Evals::Check.new(name: "x", pass: pass, detail: "")])
  end

  def snapshot(results) = described_class.snapshot(results, at: "t0")

  it "snapshots pass + judge score per case" do
    snap = snapshot([case_result("c1", pass: true, score: 0.9), case_result("c2", pass: false)])
    expect(snap["cases"]).to eq(
      "c1" => { "pass" => true, "score" => 0.9 },
      "c2" => { "pass" => false, "score" => nil }
    )
  end

  it "flags a pass→fail regression" do
    base = snapshot([case_result("c1", pass: true)])
    regs = described_class.compare([case_result("c1", pass: false)], base, tolerance: 0.05)
    expect(regs.map(&:kind)).to eq(["pass→fail"])
  end

  it "flags a judge score drop beyond the tolerance" do
    base = snapshot([case_result("c1", pass: true, score: 0.9)])
    regs = described_class.compare([case_result("c1", pass: true, score: 0.8)], base, tolerance: 0.05)
    expect(regs.map(&:kind)).to eq(["score-drop"])
    expect(regs.first.detail).to include("0.9 -> 0.8")
  end

  it "does NOT flag a score drop within tolerance" do
    base = snapshot([case_result("c1", pass: true, score: 0.9)])
    regs = described_class.compare([case_result("c1", pass: true, score: 0.87)], base, tolerance: 0.05)
    expect(regs).to be_empty
  end

  it "does NOT flag an improvement or a stably-failing case" do
    base = snapshot([case_result("up", pass: true, score: 0.7), case_result("bad", pass: false)])
    regs = described_class.compare(
      [case_result("up", pass: true, score: 0.95), case_result("bad", pass: false)], base, tolerance: 0.05
    )
    expect(regs).to be_empty
  end

  it "does NOT flag a new case absent from the baseline (only shows in the report)" do
    base = snapshot([case_result("c1", pass: true)])
    regs = described_class.compare([case_result("c2", pass: false)], base, tolerance: 0.05)
    expect(regs).to be_empty
  end

  it "round-trips through disk" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baseline.json")
      described_class.write(path, [case_result("c1", pass: true, score: 0.8)], at: "t0")
      loaded = described_class.load(path)
      expect(loaded["cases"]["c1"]).to eq("pass" => true, "score" => 0.8)
    end
  end
end
