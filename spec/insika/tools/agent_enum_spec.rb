# frozen_string_literal: true

require "spec_helper"
require "insika/tools/subagent"  # the Executor loads them lazily in create_chat;
require "insika/tools/subagents" # explicit here

# Naming the parent's subagent allowlist inside the delegation tools' schema.
#
# This is not cosmetic and it is not a guess: measured against a live provider,
# the same parent prompt spawned ZERO children while `agent` was described only
# as "must be one this agent may spawn", and TWO children once the ids were in
# the description + an `enum`. A model cannot call what it cannot name.
RSpec.describe Insika::Tools::AgentEnum do
  describe ".inject" do
    let(:symbol_schema) do
      { type: "object", properties: { agent: { type: "string", description: "id" } }, required: %w[agent] }
    end

    it "sets the enum on the named property, keeping the original untouched" do
      out = described_class.inject(symbol_schema, %w[a b], path: %i[agent])

      expect(out[:properties][:agent][:enum]).to eq(%w[a b])
      expect(symbol_schema[:properties][:agent]).not_to have_key(:enum) # deep-duped
    end

    it "walks into `items` for an array property (the fan-out shape)" do
      schema = {
        type: "object",
        properties: { tasks: { type: "array",
                               items: { type: "object",
                                        properties: { agent: { type: "string" }, message: { type: "string" } } } } }
      }

      out = described_class.inject(schema, %w[security performance], path: %i[tasks agent])

      expect(out[:properties][:tasks][:items][:properties][:agent][:enum]).to eq(%w[security performance])
    end

    it "keeps the schema's own key convention (string-keyed stays string-keyed)" do
      schema = { "type" => "object", "properties" => { "agent" => { "type" => "string" } } }

      out = described_class.inject(schema, %w[a], path: %i[agent])

      expect(out["properties"]["agent"]).to eq({ "type" => "string", "enum" => %w[a] })
    end

    it "returns the schema UNTOUCHED when there is nothing to annotate" do
      expect(described_class.inject(symbol_schema, [], path: %i[agent])).to be(symbol_schema)
      expect(described_class.inject(nil, %w[a], path: %i[agent])).to be_nil
    end

    it "returns the schema UNTOUCHED when the shape is unknown (annotate or leave alone, never corrupt)" do
      odd = { type: "object", properties: { something_else: { type: "string" } } }
      expect(described_class.inject(odd, %w[a], path: %i[agent])).to be(odd)
    end
  end

  describe "the delegation tools" do
    let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }

    def state_for(subagents)
      profile = Insika::AgentProfile.build(id: "parent", model: "m", subagents: subagents)
      Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "hi")
    end

    let(:runner) { Class.new { def run_subagent(**) = {}; def run_subagents(**) = {} }.new }

    it "spawn_subagent names the allowed agents in its description and enum" do
      tool = Insika::Tools::Subagent.new(runner: runner, state: state_for(%w[security performance]))

      expect(tool.description).to include("Agents you may spawn: security, performance.")
      expect(tool.params_schema.dig("properties", "agent", "enum")).to eq(%w[security performance])
    end

    it "spawn_subagents names them on each task's agent" do
      tool = Insika::Tools::Subagents.new(runner: runner, state: state_for(%w[security performance]))

      expect(tool.description).to include("Agents you may spawn: security, performance.")
      expect(tool.params_schema.dig("properties", "tasks", "items", "properties", "agent", "enum"))
        .to eq(%w[security performance])
    end

    it "leaves the class-level description alone when there is no allowlist" do
      # The ChatBuilder never wires these without an allowlist, but the tools must
      # not invent an empty "Agents you may spawn: ." either.
      tool = Insika::Tools::Subagent.new(runner: runner, state: state_for(nil))

      expect(tool.description).to eq(Insika::Tools::Subagent.description)
      expect(tool.params_schema.dig("properties", "agent")).not_to have_key("enum")
    end
  end
end
