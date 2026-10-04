# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ConfigStore do
  subject(:cs) { described_class.new(store: Insika::Stores::Memory.new) }

  it "put/get round-trip of a record (symbol -> string at the boundary)" do
    cs.put("agents", "bia", { id: "bia", provider: :deepseek })
    expect(cs.get("agents", "bia")).to eq("id" => "bia", "provider" => "deepseek")
  end

  it "get of a nonexistent key -> nil (never an exception)" do
    expect(cs.get("agents", "sumiu")).to be_nil
  end

  it "keys/all list the scope in lexicographic order" do
    cs.put("agents", "b", { id: "b" })
    cs.put("agents", "a", { id: "a" })
    expect(cs.keys("agents")).to eq(%w[a b])
    expect(cs.all("agents")).to eq([{ "id" => "a" }, { "id" => "b" }])
  end

  it "scopes are isolated" do
    cs.put("agents", "x", { k: 1 })
    cs.put("settings", "x", { k: 2 })
    expect(cs.get("agents", "x")).to eq("k" => 1)
    expect(cs.get("settings", "x")).to eq("k" => 2)
  end

  it "delete -> bool (existed?)" do
    cs.put("mcp", "srv", { a: 1 })
    expect(cs.delete("mcp", "srv")).to be(true)
    expect(cs.delete("mcp", "srv")).to be(false)
  end

  it "unknown scope -> UnknownScope (fail-fast)" do
    expect { cs.put("nope", "k", {}) }.to raise_error(Insika::ConfigStore::UnknownScope)
    expect { cs.get("nope", "k") }.to raise_error(Insika::ConfigStore::UnknownScope)
  end

  describe "cache (recheck > 0)" do
    let(:backend) { Insika::Stores::Memory.new }
    let(:counted) do
      Class.new(SimpleDelegator) do
        attr_reader :gets
        def initialize(obj) = (super; @gets = Hash.new(0))
        def get(scope, key) = (@gets[scope] += 1; super)
        def entries(scope, prefix = nil) = (@gets[scope] += 1; super)
      end.new(backend)
    end
    let(:cached) { described_class.new(store: counted, recheck: 60) }
    let(:writer) { described_class.new(store: backend, recheck: 60) }

    it "serves repeated reads without reading the record again" do
      writer.put("agents", "bia", { id: "bia" })
      3.times { expect(cached.get("agents", "bia")).to eq("id" => "bia") }
      expect(counted.gets["config:agents"]).to eq(1)
    end

    it "returns a fresh copy on every hit" do
      writer.put("agents", "bia", { id: "bia" })
      cached.get("agents", "bia")["id"] = "mutated"
      expect(cached.get("agents", "bia")).to eq("id" => "bia")
    end

    it "sees its own write immediately" do
      cached.put("agents", "bia", { v: 1 })
      cached.get("agents", "bia")
      cached.put("agents", "bia", { v: 2 })
      expect(cached.get("agents", "bia")).to eq("v" => 2)
    end

    it "another instance sees a write after recheck" do
      now = 0.0
      reader = described_class.new(store: backend, recheck: 1.0, clock: -> { now })
      writer.put("agents", "bia", { v: 1 })
      expect(reader.get("agents", "bia")).to eq("v" => 1)

      writer.put("agents", "bia", { v: 2 })
      expect(reader.get("agents", "bia")).to eq("v" => 1) # inside the recheck window
      now = 1.5
      expect(reader.get("agents", "bia")).to eq("v" => 2)
    end

    it "a cached miss is dropped when the token changes" do
      now = 0.0
      reader = described_class.new(store: backend, recheck: 1.0, clock: -> { now })
      expect(reader.get("agents", "late")).to be_nil
      writer.put("agents", "late", { id: "late" })
      now = 1.5
      expect(reader.get("agents", "late")).to eq("id" => "late")
    end

    it "all/keys are cached and follow deletes" do
      cached.put("agents", "a", { id: "a" })
      cached.put("agents", "b", { id: "b" })
      expect(cached.all("agents")).to eq([{ "id" => "a" }, { "id" => "b" }])
      expect(cached.keys("agents")).to eq(%w[a b])
      expect(cached.delete("agents", "a")).to be(true)
      expect(cached.all("agents")).to eq([{ "id" => "b" }])
      expect(cached.keys("agents")).to eq(%w[b])
    end

    it "the version token lives outside the authored config scopes" do
      writer.put("agents", "bia", { id: "bia" })
      expect(backend.get(described_class::VERSION_SCOPE, "token")).to be_a(String)
      expect(writer.keys("agents")).to eq(%w[bia])
    end
  end

  it "recheck: 0 (the default) reads the store every time, as before" do
    backend = Insika::Stores::Memory.new
    a = described_class.new(store: backend)
    b = described_class.new(store: backend)
    a.put("agents", "bia", { v: 1 })
    expect(b.get("agents", "bia")).to eq("v" => 1)
    a.put("agents", "bia", { v: 2 })
    expect(b.get("agents", "bia")).to eq("v" => 2)
  end
end
