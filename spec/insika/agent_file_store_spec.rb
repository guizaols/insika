# frozen_string_literal: true

require "spec_helper"

# Phase 4 Stage C: per-agent workspace (prompt content in the durable Store).
RSpec.describe Insika::AgentFileStore do
  subject(:store) { described_class.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

  it "write/read round-trip per agent and per file" do
    store.write("bia", "IDENTITY.md", "Sou a Bia.")
    store.write("chef", "IDENTITY.md", "Sou o Chef.")

    expect(store.read("bia", "IDENTITY.md")).to eq("Sou a Bia.")
    expect(store.read("chef", "IDENTITY.md")).to eq("Sou o Chef.")   # isolated per agent
    expect(store.read("bia", "SOUL.md")).to be_nil                    # nonexistent file
    expect(store.read("nope", "IDENTITY.md")).to be_nil               # nonexistent agent
  end

  it "list -> agent's names sorted" do
    store.write("bia", "SOUL.md", "s")
    store.write("bia", "IDENTITY.md", "i")
    expect(store.list("bia")).to eq(%w[IDENTITY.md SOUL.md])
    expect(store.list("empty")).to eq([])
  end

  it "overwriting versions the previous content in history (most recent first)" do
    store.write("bia", "IDENTITY.md", "v1")
    store.write("bia", "IDENTITY.md", "v2")
    store.write("bia", "IDENTITY.md", "v3")

    expect(store.read("bia", "IDENTITY.md")).to eq("v3")
    expect(store.versions("bia", "IDENTITY.md").map { |h| h["content"] }).to eq(%w[v2 v1])
  end

  it "create_only refuses to overwrite an existing file" do
    store.write("bia", "IDENTITY.md", "v1")
    expect { store.write("bia", "IDENTITY.md", "v2", create_only: true) }
      .to raise_error(Insika::ValidationError, /already exists/)
    expect(store.read("bia", "IDENTITY.md")).to eq("v1")
  end

  it "delete -> bool (did it exist?) and disappears from list" do
    store.write("bia", "IDENTITY.md", "v1")
    expect(store.delete("bia", "IDENTITY.md")).to be(true)
    expect(store.delete("bia", "IDENTITY.md")).to be(false)
    expect(store.read("bia", "IDENTITY.md")).to be_nil
  end

  describe "#restore" do
    before do
      store.write("bia", "IDENTITY.md", "v1")
      store.write("bia", "IDENTITY.md", "v2")
    end

    it "restores an old version as the current content (new write)" do
      store.restore("bia", "IDENTITY.md", 0) # v1 (most recent old one)
      expect(store.read("bia", "IDENTITY.md")).to eq("v1")
      # v2 (what was current) goes to the top of history
      expect(store.versions("bia", "IDENTITY.md").map { |h| h["content"] }).to eq(%w[v2 v1])
    end

    it "invalid index -> ValidationError; nonexistent file -> NotFoundError" do
      expect { store.restore("bia", "IDENTITY.md", 9) }.to raise_error(Insika::ValidationError)
      expect { store.restore("bia", "SUMIU.md", 0) }.to raise_error(Insika::NotFoundError)
    end
  end

  it "history respects the HISTORY_MAX ceiling" do
    (0..(described_class::HISTORY_MAX + 3)).each { |i| store.write("bia", "f.md", "v#{i}") }
    expect(store.versions("bia", "f.md").length).to eq(described_class::HISTORY_MAX)
  end
end
