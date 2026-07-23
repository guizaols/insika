# frozen_string_literal: true

require "spec_helper"

# Phase 6/D4/F6 (task 7) — the importer emits the authoring Commands from
# a Pack. Proves: create vs update (upsert), 1 write_agent_file per file, 1
# write_skill per skill, 1 write_data_tool per tool, and AUTHORITATIVE allowlists
# derived from the pack (per-store isolation + NF2).
RSpec.describe Insika::PackImporter do
  # bus double: records (type, payload) of each dispatch.
  class BusSpy
    Dispatched = Struct.new(:type, :payload)
    attr_reader :calls

    def initialize = (@calls = [])
    def dispatch(command) = (@calls << Dispatched.new(command.type, command.payload); {})
    def of(type) = @calls.select { |c| c.type == type }
  end

  # ProfileSource double: only fetch matters (existence for create vs update).
  def profiles(existing = {})
    src = Object.new
    src.define_singleton_method(:fetch) { |id| existing[id] }
    src.define_singleton_method(:[]) { |id| existing[id] }
    src
  end

  let(:bus) { BusSpy.new }

  def pack(**over)
    Insika::Pack.from_h({
      config: { id: "loja-7", model: "deepseek-chat", metadata: { store_id: "7" } },
      files: { "IDENTITY.md" => "quem sou", "SOUL.md" => "voz" },
      skills: { "escalation" => "---\nname: escalation\n---\n", "promo" => "---\nname: promo\n---\n" },
      tools: [{ "name" => "cart", "description" => "d", "request" => { "url" => "https://api.test" } },
              { "name" => "search", "description" => "d", "request" => { "url" => "https://api.test" } }]
    }.merge(over))
  end

  describe "#import (new agent)" do
    subject(:result) { described_class.new(bus: bus, profiles: profiles).import(pack) }

    it "creates the agent (create_agent) with the pack's manifest" do
      result
      create = bus.of(:create_agent)
      expect(create.size).to eq(1)
      expect(create.first.payload).to include(id: "loja-7", model: "deepseek-chat", metadata: { store_id: "7" })
    end

    it "derives AUTHORITATIVE allowlists from the pack (isolation + NF2)" do
      result
      attrs = bus.of(:create_agent).first.payload
      expect(attrs[:prompt_files]).to contain_exactly("IDENTITY.md", "SOUL.md")
      expect(attrs[:skills]).to contain_exactly("escalation", "promo")
      expect(attrs[:tools_allow]).to contain_exactly("cart", "search")
    end

    it "1 write_agent_file per file, with agent_id and content" do
      result
      files = bus.of(:write_agent_file)
      expect(files.map { |c| c.payload[:file] }).to contain_exactly("IDENTITY.md", "SOUL.md")
      expect(files).to all(have_attributes(payload: include(agent_id: "loja-7")))
      expect(files.find { |c| c.payload[:file] == "IDENTITY.md" }.payload[:content]).to eq("quem sou")
    end

    it "1 write_skill per skill + 1 write_data_tool per tool" do
      result
      expect(bus.of(:write_skill).map { |c| c.payload[:name] }).to contain_exactly("escalation", "promo")
      expect(bus.of(:write_data_tool).map { |c| c.payload["name"] }).to contain_exactly("cart", "search")
    end

    it "order: create_agent BEFORE the write_agent_file (the file requires the agent)" do
      result
      types = bus.calls.map(&:type)
      expect(types.index(:create_agent)).to be < types.index(:write_agent_file)
    end

    it "-> summary of what was provisioned" do
      expect(result).to eq(
        agent_id: "loja-7", created: true,
        files: %w[IDENTITY.md SOUL.md], skills: %w[escalation promo], tools: %w[cart search]
      )
    end
  end

  describe "#import (existing agent = update/upsert)" do
    it "uses update_agent (not create) when the agent already exists" do
      importer = described_class.new(bus: bus, profiles: profiles("loja-7" => Object.new))
      out = importer.import(pack)
      expect(bus.of(:create_agent)).to be_empty
      expect(bus.of(:update_agent).size).to eq(1)
      expect(out[:created]).to be(false)
    end
  end

  describe "allowlist with tools_allow in the config" do
    it "merges config tools with the pack's tools (NF2)" do
      p = pack(config: { id: "loja-7", model: "m", tools_allow: %w[send_finalize] })
      described_class.new(bus: bus, profiles: profiles).import(p)
      expect(bus.of(:create_agent).first.payload[:tools_allow]).to contain_exactly("send_finalize", "cart", "search")
    end
  end

  describe "schema pruning by flag (Phase 7, Step E / D5 — allowlist by group)" do
    def attrs_for(config)
      p = pack(config: config)
      described_class.new(bus: bus, profiles: profiles).import(p)
      bus.of(:create_agent).first.payload
    end

    it "enabled_groups: [...] becomes tools_allow_groups (ON groups declared as DATA)" do
      attrs = attrs_for(id: "loja-7", model: "m", enabled_groups: %w[default b2b])
      expect(attrs[:tools_allow_groups]).to contain_exactly("default", "b2b")
    end

    it "flags: { group => bool } enables only the truthy ones (the false ones PRUNE the group)" do
      attrs = attrs_for(id: "loja-7", model: "m", flags: { "b2b" => true, "beauty" => false, "mcp:tavily" => true })
      expect(attrs[:tools_allow_groups]).to contain_exactly("b2b", "mcp:tavily")
    end

    it "accepts 'true' string (flag coming from the wire JSON)" do
      attrs = attrs_for(id: "loja-7", model: "m", flags: { "b2b" => "true", "x" => "false" })
      expect(attrs[:tools_allow_groups]).to contain_exactly("b2b")
    end

    it "merges enabled_groups with the truthy flags" do
      attrs = attrs_for(id: "loja-7", model: "m", enabled_groups: %w[default], flags: { "b2b" => true })
      expect(attrs[:tools_allow_groups]).to contain_exactly("default", "b2b")
    end

    it "without enabled_groups nor flags -> tools_allow_groups absent (no pruning; old behavior)" do
      attrs = attrs_for(id: "loja-7", model: "m")
      expect(attrs).not_to have_key(:tools_allow_groups)
    end

    it "enabled_groups: [] (or all flags false) -> no group (total pruning of the groups)" do
      attrs = attrs_for(id: "loja-7", model: "m", enabled_groups: [])
      expect(attrs[:tools_allow_groups]).to eq([])
    end
  end

  describe "validation" do
    it "pack without config.id -> ValidationError (dispatches nothing)" do
      p = Insika::Pack.from_h(config: { model: "m" })
      expect { described_class.new(bus: bus, profiles: profiles).import(p) }
        .to raise_error(Insika::ValidationError, /config\.id/)
      expect(bus.calls).to be_empty
    end
  end

  describe "#delete" do
    it "dispatches delete_agent" do
      out = described_class.new(bus: bus, profiles: profiles).delete("loja-7")
      expect(bus.of(:delete_agent).first.payload).to eq(id: "loja-7")
      expect(out).to eq(agent_id: "loja-7", deleted: true)
    end
  end
end
