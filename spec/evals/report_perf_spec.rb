# frozen_string_literal: true

require "spec_helper"
require "json"

# What a case COST, beside whether it passed. The cross-harness table lives on this
# block, and its whole job is to distinguish "nobody measured" from "it was free".
RSpec.describe Insika::Evals::Report do
  def result(id, pass: true)
    checks = [Insika::Evals::Check.new(name: "c", pass: pass, detail: "")]
    Insika::Evals::CaseResult.new(id: id, agent: "loja", checks: checks, error: nil, rubric: nil, judge: nil)
  end

  let(:results) { [result("a"), result("b", pass: false)] }
  let(:perf) do
    { "a" => { "ms" => 1200, "turn_ms" => [500, 700], "turns" => 2, "tokens" => 800 },
      "b" => { "ms" => 3400, "turn_ms" => [3400], "turns" => 1 } }
  end

  it "carries each case's cost and summarises the run" do
    h = described_class.to_h(results, at: "2026-09-08T00:00:00Z", perf: perf)
    expect(h["cases"].map { |c| c.dig("perf", "ms") }).to eq([1200, 3400])
    expect(h["perf"]).to include("cases_measured" => 2, "case_ms_p50" => 2300, "case_ms_p95" => 3290,
                                 "turn_ms_p50" => 700, "tokens_total" => 800, "tokens_measured" => 1)
  end

  it "prints the time beside the case and a summary line" do
    md = described_class.to_markdown(results, at: "2026-09-08T00:00:00Z", perf: perf)
    expect(md).to include("`a` (loja) · 1.2s", "**time** (2 case(s))")
  end

  # A harness that reports no usage must not read as free, and a run nobody timed must
  # not read as instant.
  it "leaves out what was never measured" do
    h = described_class.to_h(results, at: "2026-09-08T00:00:00Z", perf: { "b" => { "ms" => 10 } })
    expect(h["perf"]).not_to have_key("tokens_total")
    expect(described_class.to_h(results, at: "2026-09-08T00:00:00Z")).not_to have_key("perf")
  end

  it "an untimed report is unchanged — the old callers keep their shape" do
    h = described_class.to_h(results, at: "2026-09-08T00:00:00Z")
    expect(h["cases"].first).not_to have_key("perf")
  end
end
