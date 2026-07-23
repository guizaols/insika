# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::SubagentGraph do
  describe ".validate! over a {id => [children]} map" do
    it "accepts an acyclic graph within the depth cap" do
      map = { "a" => %w[b c], "b" => ["d"], "c" => [], "d" => [] }
      expect(described_class.validate!(map)).to eq(map)
    end

    it "accepts agents with no subagents (all leaves, depth 0)" do
      expect { described_class.validate!({ "a" => [], "b" => [] }) }.not_to raise_error
    end

    it "raises SubagentCycleError on a direct cycle, exposing the path" do
      expect { described_class.validate!({ "a" => ["b"], "b" => ["a"] }) }
        .to raise_error(Insika::SubagentCycleError) { |e| expect(e.cycle).to eq(%w[a b a]) }
    end

    it "raises SubagentCycleError on a self-loop" do
      expect { described_class.validate!({ "a" => ["a"] }) }
        .to raise_error(Insika::SubagentCycleError)
    end

    it "raises SubagentDepthExceeded when the longest chain passes the cap" do
      chain = (0..6).each_with_object({}) { |i, h| h[i.to_s] = [(i + 1).to_s] }
      expect { described_class.validate!(chain, cap: 5) }
        .to raise_error(Insika::SubagentDepthExceeded) { |e| expect(e.depth).to eq(6) }
    end

    it "accepts a chain exactly at the cap" do
      chain = (0...5).each_with_object({}) { |i, h| h[i.to_s] = [(i + 1).to_s] }
      expect { described_class.validate!(chain, cap: 5) }.not_to raise_error
    end

    it "treats an unknown child ref as a leaf (does NOT error — dynamic authoring order)" do
      expect { described_class.validate!({ "a" => ["ghost"] }) }.not_to raise_error
    end

    it "the errors are ValidationErrors (a bad graph fails the authoring Command cleanly)" do
      expect(Insika::SubagentCycleError.ancestors).to include(Insika::ValidationError)
      expect(Insika::SubagentDepthExceeded.ancestors).to include(Insika::ValidationError)
    end
  end

  describe ".validate! over an array of AgentProfiles" do
    it "reads #id and #subagents and validates the whole set" do
      parent = Insika::AgentProfile.build(id: "parent", subagents: ["child"])
      child = Insika::AgentProfile.build(id: "child")
      expect { described_class.validate!([parent, child]) }.not_to raise_error
    end

    it "catches a cycle across two profiles" do
      a = Insika::AgentProfile.build(id: "a", subagents: ["b"])
      b = Insika::AgentProfile.build(id: "b", subagents: ["a"])
      expect { described_class.validate!([a, b]) }.to raise_error(Insika::SubagentCycleError)
    end
  end

  describe ".depth_cap" do
    it "defaults to DEFAULT_DEPTH_CAP" do
      expect(described_class.depth_cap).to eq(described_class::DEFAULT_DEPTH_CAP)
    end

    it "honors HARNESS_SUBAGENT_DEPTH_CAP" do
      original = ENV["HARNESS_SUBAGENT_DEPTH_CAP"]
      ENV["HARNESS_SUBAGENT_DEPTH_CAP"] = "9"
      expect(described_class.depth_cap).to eq(9)
    ensure
      ENV["HARNESS_SUBAGENT_DEPTH_CAP"] = original
    end
  end
end
