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
    around do |ex|
      Fiber[described_class::TURN_KEY] = true
      ex.run
    ensure
      Fiber[described_class::TURN_KEY] = nil
    end

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

    # A read in flight when the cache is dropped must not repopulate it with the
    # value it read before the drop (it would outlive every later revalidation).
    it "a read that yields across a cache drop does not cache its stale value" do
      slow = Class.new(SimpleDelegator) do
        def get(scope, key)
          value = super
          Async::Task.current?&.sleep(0.01) if scope == "config:agents"
          value
        end
      end.new(backend)
      now = 0.0
      reader = described_class.new(store: slow, recheck: 1.0, clock: -> { now })
      writer.put("agents", "bia", { v: 1 })

      Sync do
        a = Async { reader.get("agents", "bia") } # reads v1, then yields
        writer.put("agents", "bia", { v: 2 })
        now = 2.0
        reader.get("settings", "x") # revalidates: new token, cache dropped
        a.wait
      end

      now = 100.0
      expect(reader.get("agents", "bia")).to eq("v" => 2)
    end

    it "the version token lives outside the authored config scopes" do
      writer.put("agents", "bia", { id: "bia" })
      expect(backend.get(described_class::VERSION_SCOPE, "token")).to be_a(String)
      expect(writer.keys("agents")).to eq(%w[bia])
    end
  end

  # Studio and pack imports read a record, change it and write it back. Outside a
  # turn the cache is off, so that read never misses another worker's write.
  it "outside a turn the cache is off: a read-modify-write sees another worker's write" do
    backend = Insika::Stores::Memory.new
    worker_a = described_class.new(store: backend, recheck: 60)
    worker_b = described_class.new(store: backend, recheck: 60)
    worker_a.put("agent_files", "bia", { "files" => { "AGENTS.md" => 1 } })
    worker_b.get("agent_files", "bia")
    worker_a.put("agent_files", "bia", { "files" => { "AGENTS.md" => 2 } })

    expect(worker_b.get("agent_files", "bia")).to eq("files" => { "AGENTS.md" => 2 })
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
