# frozen_string_literal: true

require "spec_helper"

# runtime agent CRUD (the "everyone creates their own BIA").
RSpec.describe "Agent authoring commands" do
  let(:source) { Insika::StoredProfileSource.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Insika::Command.build(type, payload)

  describe Insika::Commands::CreateAgent do
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

    it "id is required" do
      expect { handler.call(cmd(:create_agent, { "model" => "m" })) }.to raise_error(Insika::ValidationError, /id/)
    end

    it "model is OPTIONAL: a modelless agent resolves the platform default at turn start" do
      profile = handler.call(cmd(:create_agent, { "id" => "x" }))
      expect(profile.id).to eq("x")
      expect(profile.model).to be_nil
      expect(events.map(&:type)).to eq([:agent_created])
    end

    it "duplicate id -> ValidationError (does not overwrite)" do
      handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m" }))
      expect { handler.call(cmd(:create_agent, { "id" => "bia", "model" => "m2" })) }
        .to raise_error(Insika::ValidationError, /already exists/)
    end

    # definition-time cycle/depth check.
    it "persists a valid subagents allowlist" do
      source.put(Insika::AgentProfile.build(id: "child", model: "m"))
      profile = handler.call(cmd(:create_agent, { "id" => "parent", "model" => "m", "subagents" => %w[child] }))
      expect(profile.subagents).to eq(%w[child])
    end

    it "rejects a subagents allowlist that closes a cycle (nothing persisted)" do
      source.put(Insika::AgentProfile.build(id: "a", model: "m", subagents: %w[parent]))
      expect { handler.call(cmd(:create_agent, { "id" => "parent", "model" => "m", "subagents" => %w[a] })) }
        .to raise_error(Insika::SubagentCycleError)
      expect(source.fetch("parent")).to be_nil
    end

    it "briefing_fields round-trips through the authoring payload (create -> stored -> fetch)" do
      handler.call(cmd(:create_agent, {
                         "id" => "briefing-agent", "model" => "m",
                         "briefing_fields" => %w[size budget]
                       }))
      expect(source.fetch("briefing-agent").briefing_fields).to eq(%w[size budget])
    end

    it "grounding round-trips through the authoring payload (RFC-0029)" do
      handler.call(cmd(:create_agent, {
                         "id" => "grounded-agent", "model" => "m",
                         "grounding" => { "mode" => "flag",
                                          "matcher" => { "sku" => "\\d+" } }
                       }))
      profile = source.fetch("grounded-agent")
      expect(profile.grounding).to eq("mode" => "flag", "matcher" => { "sku" => "\\d+" })
    end

    it "funnel round-trips through the authoring payload (RFC-0032)" do
      handler.call(cmd(:create_agent, {
                         "id" => "funnel-agent", "model" => "m",
                         "funnel" => { "stages" => %w[greeted paid],
                                       "advance_on" => { "conversion" => "paid" },
                                       "primary" => "paid", "attribution_window" => "72h" }
                       }))
      profile = source.fetch("funnel-agent")
      expect(profile.funnel).to eq("stages" => %w[greeted paid],
                                   "advance_on" => { "conversion" => "paid" },
                                   "primary" => "paid", "attribution_window" => "72h")
    end
  end

  describe Insika::Commands::UpdateAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Insika::AgentProfile.build(id: "bia", model: "m1", provider: :deepseek, skills: %w[pedido])) }

    it "merges the patch (only what's sent changes); emits :agent_updated" do
      profile = handler.call(cmd(:update_agent, { "id" => "bia", "model" => "m2" }))
      expect(profile.model).to eq("m2")
      expect(profile.skills).to eq(%w[pedido])   # preserved (was not in the patch)
      expect(profile.provider).to eq(:deepseek)  # preserved
      expect(events.map(&:type)).to include(:agent_updated)
    end

    it "nonexistent agent -> NotFoundError" do
      expect { handler.call(cmd(:update_agent, { "id" => "nope", "model" => "m" })) }
        .to raise_error(Insika::NotFoundError)
    end

    # an update that ADDS subagents is validated too.
    it "rejects an update that introduces a self-cycle (keeps the old profile)" do
      expect { handler.call(cmd(:update_agent, { "id" => "bia", "subagents" => %w[bia] })) }
        .to raise_error(Insika::SubagentCycleError)
      expect(source.fetch("bia").subagents).to be_nil # unchanged
    end

    it "an update WITHOUT funnel preserves the stored declaration" do
      source.put(Insika::AgentProfile.build(
                   id: "bia", model: "m",
                   funnel: { "stages" => %w[greeted paid],
                             "advance_on" => { "conversion" => "paid" },
                             "primary" => "paid", "attribution_window" => "72h" }
                 ))
      handler.call(cmd(:update_agent, { "id" => "bia", "model" => "m2" }))
      expect(source.fetch("bia").funnel["primary"]).to eq("paid")
    end

    it "an update WITH funnel overwrites the stored declaration" do
      source.put(Insika::AgentProfile.build(
                   id: "bia", model: "m",
                   funnel: { "stages" => %w[greeted paid],
                             "advance_on" => { "conversion" => "paid" },
                             "primary" => "paid", "attribution_window" => "72h" }
                 ))
      handler.call(cmd(:update_agent, {
                         "id" => "bia",
                         "funnel" => { "stages" => %w[hello bye],
                                       "advance_on" => { "x" => "bye" },
                                       "primary" => "bye", "attribution_window" => "24h" }
                       }))
      expect(source.fetch("bia").funnel).to eq(
        "stages" => %w[hello bye], "advance_on" => { "x" => "bye" },
        "primary" => "bye", "attribution_window" => "24h"
      )
    end
  end

  describe Insika::Commands::SetAgentTools do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }
    before { source.put(Insika::AgentProfile.build(id: "bia", model: "m", tools_allow: %w[a b])) }

    it "adjusts allow/deny; nil allow = all" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[menu], "deny" => %w[calc] }))
      expect(p.tools_allow).to eq(%w[menu])
      expect(p.tools_deny).to eq(%w[calc])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => nil }))
      expect(p2.tools_allow).to be_nil
    end

    it "non-list allow -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => "x" })) }
        .to raise_error(Insika::ValidationError)
    end

    # allow_groups only overwrites when the key is present.
    it "sets allow_groups when present; preserves when absent" do
      p = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => %w[b2b] }))
      expect(p.tools_allow_groups).to eq(%w[b2b])
      p2 = handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow" => %w[x] })) # without allow_groups
      expect(p2.tools_allow_groups).to eq(%w[b2b]) # preserved
    end

    it "non-list allow_groups -> ValidationError" do
      expect { handler.call(cmd(:set_agent_tools, { "id" => "bia", "allow_groups" => "x" })) }
        .to raise_error(Insika::ValidationError, /allow_groups/)
    end
  end

  describe Insika::Commands::DeleteAgent do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    it "removes the agent and returns the removed one; emits :agent_deleted" do
      source.put(Insika::AgentProfile.build(id: "bia", model: "m"))
      removed = handler.call(cmd(:delete_agent, { "id" => "bia" }))
      expect(removed.id).to eq("bia")
      expect(source.fetch("bia")).to be_nil
      expect(events.map(&:type)).to include(:agent_deleted)
    end

    it "nonexistent -> NotFoundError" do
      expect { handler.call(cmd(:delete_agent, { "id" => "nope" })) }.to raise_error(Insika::NotFoundError)
    end
  end
end
