# frozen_string_literal: true

require "spec_helper"

#   — the cache-prefix hash chain. Inputs are the SYSTEM-placement
# fragments in canonical render order and the tool schema serialization; outputs
# are PII-free SHA-256 digests. Never sees message text — only hashes leave.
RSpec.describe Insika::PrefixFingerprint do
  # Layer as the Builder would stamp it: prompt/skills/toolsearch are identity,
  # everything else (memory, knowledge, …) volatile.
  IDENTITY = %w[prompt skills toolsearch].freeze

  def frag(source, content, placement: :system)
    layer = IDENTITY.include?(source.to_s) ? :identity : :volatile
    Insika::ContextFragment.build(content: content, placement: placement, source: source, layer: layer)
  end

  def compute(sources = {}, tool_serial: "tool x")
    fragments = sources.map { |source, content| frag(source, content) }
    described_class.compute(fragments, tool_serial: tool_serial)
  end

  it "two identical builds produce identical maps, including prefix" do
    a = compute({ "prompt" => "você é a Bia", "memory" => "cliente: ana" }, tool_serial: "busca t")
    b = compute({ "prompt" => "você é a Bia", "memory" => "cliente: ana" }, tool_serial: "busca t")
    expect(a).to eq(b)
    expect(a["prefix"]).to eq(b["prefix"])
    # chain (identity + tool_schemas + prefix) first, volatile categories after it
    expect(a.keys).to eq(%w[prompt tool_schemas prefix memory])
  end

  it "a diverged volatile category changes its own digest only — the prefix sits above it" do
    before_map = compute({ "prompt" => "você é a Bia", "memory" => "cliente: ana" }, tool_serial: "t")
    after_map = compute({ "prompt" => "você é a Bia", "memory" => "cliente: maria" }, tool_serial: "t")

    expect(after_map["memory"]).not_to eq(before_map["memory"])
    expect(after_map["prefix"]).to eq(before_map["prefix"])
    expect(after_map["prompt"]).to eq(before_map["prompt"])
    expect(after_map["tool_schemas"]).to eq(before_map["tool_schemas"])
  end

  it "a diverged identity category or tool serial changes the prefix" do
    base = compute({ "prompt" => "A", "memory" => "B" }, tool_serial: "t")
    expect(compute({ "prompt" => "A2", "memory" => "B" }, tool_serial: "t")["prefix"]).not_to eq(base["prefix"])
    expect(compute({ "prompt" => "A", "memory" => "B" }, tool_serial: "t2")["prefix"]).not_to eq(base["prefix"])
  end

  describe "invalidation_reason" do
    # The maps under test come from REAL compute() calls, like the Executor
    # produces — a hand-built previous map with a stale cumulative "prefix"
    # would be impossible in real data (a vanished block changes it).

    it "nil previous (first turn) -> nil" do
      expect(described_class.invalidation_reason(compute, nil)).to be_nil
    end

    it "identical maps -> nil" do
      cur = compute
      expect(described_class.invalidation_reason(cur, cur.dup)).to be_nil
    end

    it "a volatile change (memory) is NOT an invalidation — the breakpoint sits above it" do
      cur = compute({ "prompt" => "A", "memory" => "B" }, tool_serial: "t")
      prev = compute({ "prompt" => "A", "memory" => "B2" }, tool_serial: "t")
      expect(described_class.invalidation_reason(cur, prev)).to be_nil
    end

    it "a volatile category appearing or vanishing is not an invalidation either" do
      with_mem = compute({ "prompt" => "A", "memory" => "B" }, tool_serial: "t")
      without = compute({ "prompt" => "A" }, tool_serial: "t")
      expect(described_class.invalidation_reason(with_mem, without)).to be_nil
      expect(described_class.invalidation_reason(without, with_mem)).to be_nil
    end

    it "the first diverged identity category (in current chain order) wins" do
      cur = compute({ "prompt" => "A", "skills" => "S", "memory" => "B" }, tool_serial: "t")
      prev = compute({ "prompt" => "A2", "skills" => "S2", "memory" => "B2" }, tool_serial: "t")
      expect(described_class.invalidation_reason(cur, prev)).to eq("prompt")
    end

    it "an identity category that APPEARS (absent from previous) names itself" do
      cur = compute({ "prompt" => "A", "skills" => "S" }, tool_serial: "t")
      prev = compute({ "prompt" => "A" }, tool_serial: "t")
      expect(described_class.invalidation_reason(cur, prev)).to eq("skills")
    end

    # The review probe: a vanished block changes the cumulative "prefix" too —
    # scanning it would return "prefix" and shadow the real category.
    it "an identity category that VANISHES names itself — never the cumulative prefix" do
      prev = compute({ "prompt" => "A", "skills" => "S" }, tool_serial: "t")
      cur = compute({ "prompt" => "A" }, tool_serial: "t")
      expect(described_class.invalidation_reason(cur, prev)).to eq("skills")
    end

    it "a tool-schema change names tool_schemas" do
      cur = compute({ "prompt" => "A" }, tool_serial: "t1")
      prev = compute({ "prompt" => "A" }, tool_serial: "t2")
      expect(described_class.invalidation_reason(cur, prev)).to eq("tool_schemas")
    end
  end

  it "tool_serial nil -> no tool_schemas key" do
    expect(compute({}, tool_serial: nil).keys).to eq([])
  end

  it "empty fragments and nil tool_serial -> an empty map (no prefix at all)" do
    expect(described_class.compute([], tool_serial: nil)).to eq({})
  end

  it "only system-placement fragments enter the chain (the Executor selects; history never hashes)" do
    sys = frag("prompt", "você é a Bia")
    hist = frag("hist", "oi", placement: :history)
    with_history = described_class.compute([sys, hist].select { |f| f.placement == :system }, tool_serial: "t")
    expect(with_history).to eq(compute({ "prompt" => "você é a Bia" }, tool_serial: "t"))
  end

  it "category is the demodulized, downcased provider id" do
    expect(described_class.category("Insika::Context::Providers::ToolSearch")).to eq("toolsearch")
  end
end
