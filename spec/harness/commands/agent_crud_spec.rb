# frozen_string_literal: true

require "spec_helper"

# Phase 4 Stage B: runtime agent CRUD (the "everyone creates their own BIA").
RSpec.describe "Agent authoring commands (Phase 4 Stage B)" do
  let(:source) { Harness::StoredProfileSource.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Harness::Command.build(type, payload)

  describe Harness::Commands::CreateAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    it "creates and persists the profile; emits :agent_created; returns with normalized symbols" do
      profile = handler.call(cmd(:create_agent, {
                                    "id" => "bia", "model" => "deepseek-chat", "provider" => "deepseek",
                                    "tools_allow" => %w[menu], "policies" => %w[tool_allowlist],
                                    "limits" => { "tool_timeout" => 30 }, "memory" => true
                                  }))
      expect(profile.id).to eq("bia")
      expect(profile.provider).to eq(:deepseek)            # symbol
      expect(profile.policies).to eq([:tool_allowlist])    # symbol
      expect(profile.limits[:tool_timeout]).to eq(30)
      expect(source.fetch("bia")).not_to be_nil            # persisted
      expect(events.map(&:type)).to eq([:agent_created])
    end

    it "id and model are required" do
      expect { handler.call(cmd(:create_agent, { "model" => "m" })) }.to raise_error(Harness::ValidationError, /id/)
      expect { handler.call(cmd(:create_agent, { "id" => "x" })) }.to raise_error(Harness::ValidationError, /model/)
    end

    it "duplicate id -> ValidationError (does not overwrite)" do
      handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m" }))
      expect { handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m2" })) }
        .to raise_error(Harness::ValidationError, /already exists/)
    end
  end

  describe Harness::Commands::UpdateAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Harness::AgentProfile.build(id: "bia", model: "m1", provider: :deepseek, skills: %w[pedido])) }

    it "merges the patch (only what's sent changes); emits :agent_updated" do
      profile = handler.call(cmd(:update_agent, { "id" => "bia", "model" => "m2" }))
      expect(profile.model).to eq("m2")
      expect(profile.skills).to eq(%w[pedido])   # preserved (was not in the patch)
      expect(profile.provider).to eq(:deepseek)  # preserved
      expect(events.map(&:type)).to include(:agent_updated)
    end

    it "nonexistent agent -> NotFoundError" do
      expect { handler.call(cmd(:update_agent, { "id" => "nope", "model" => "m" })) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe Harness::Commands::SetAgentTools do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Harness::AgentProfile.build(id: "bia", model: "m", tools_allow: %w[a b])) }

    it "adjusts allow/deny; nil allow = all" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[menu], "deny" => %w[calc] }))
      expect(p.tools_allow).to eq(%w[menu])
      expect(p.tools_deny).to eq(%w[calc])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => nil }))
      expect(p2.tools_allow).to be_nil
    end

    it "non-list allow -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => "x" })) }
        .to raise_error(Harness::ValidationError)
    end

    # Phase 7/D4/F5 (Stage C): allow_groups only overwrites when the key is present.
    it "sets allow_groups when present; preserves when absent" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => %w[b2b] }))
      expect(p.tools_allow_groups).to eq(%w[b2b])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[x] })) # without allow_groups
      expect(p2.tools_allow_groups).to eq(%w[b2b]) # preserved
    end

    it "non-list allow_groups -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => "x" })) }
        .to raise_error(Harness::ValidationError, /allow_groups/)
    end
  end

  describe Harness::Commands::DeleteAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    it "removes the agent and returns the removed one; emits :agent_deleted" do
      source.put(Harness::AgentProfile.build(id: "bia", model: "m"))
      removed = handler.call(cmd(:delete_agent, { "id" => "bia" }))
      expect(removed.id).to eq("bia")
      expect(source.fetch("bia")).to be_nil
      expect(events.map(&:type)).to include(:agent_deleted)
    end

    it "nonexistent -> NotFoundError" do
      expect { handler.call(cmd(:delete_agent, { "id" => "nope" })) }.to raise_error(Harness::NotFoundError)
    end
  end
end
