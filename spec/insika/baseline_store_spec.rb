# frozen_string_literal: true

require "spec_helper"

# the accepted state stopped being a file because the refinement
# gate runs where there is no checkout. The one property that matters is that a
# MISSING baseline is distinguishable from an empty one: the gate treats the first
# as "cannot look" and only the second as "nothing to compare".
RSpec.describe Insika::BaselineStore do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:store) { described_class.new(config_store: config_store) }

  def snapshot(cases, at: "2026-08-01T00:00:00Z") = { "at" => at, "cases" => cases }

  it "round-trips the shape Evals::Baseline.snapshot produces" do
    results = [
      Insika::Evals::CaseResult.new(id: "a", agent: "bia", checks: [], error: nil),
      Insika::Evals::CaseResult.new(id: "b", agent: "bia", checks: [], error: "boom")
    ]
    written = store.put("bia", Insika::Evals::Baseline.snapshot(results, at: "2026-08-01T00:00:00Z"))

    expect(written["at"]).to eq("2026-08-01T00:00:00Z")
    expect(store.get("bia")["cases"].keys).to contain_exactly("a", "b")
    # It is the same document the file holds, so `compare` consumes it unchanged.
    expect(Insika::Evals::Baseline.compare(results, store.get("bia"), tolerance: 0.05)).to be_empty
  end

  it "is per agent — re-baselining one never accepts another's current state" do
    store.put("bia", snapshot({ "a" => { "pass" => true } }))
    store.put("chef", snapshot({ "z" => { "pass" => false } }))

    store.put("bia", snapshot({ "a" => { "pass" => false } }))
    expect(store.get("chef")["cases"]["z"]["pass"]).to be(false)
    expect(store.agents).to contain_exactly("bia", "chef")
  end

  # The distinction the gate's refusal depends on.
  it "tells never-recorded from recorded-and-empty" do
    expect(store.get("ghost")).to be_nil
    expect(store.size("ghost")).to be_nil

    store.put("bia", snapshot({}))
    expect(store.get("bia")).not_to be_nil
    expect(store.size("bia")).to eq(0)
  end

  it "stamps `at` when the snapshot carries none" do
    record = store.put("bia", { "cases" => {} })
    expect(record["at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it "refuses a record with no cases mapping rather than storing a shape nothing reads" do
    expect { store.put("bia", { "at" => "now" }) }
      .to raise_error(Insika::ValidationError, /needs a 'cases' mapping/)
  end

  it "deletes, which is the honest way to disable the gate for an agent" do
    store.put("bia", snapshot({ "a" => { "pass" => true } }))
    expect(store.delete("bia")).to be(true)
    expect(store.get("bia")).to be_nil
  end
end
