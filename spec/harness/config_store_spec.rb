# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::ConfigStore do
  subject(:cs) { described_class.new(store: Harness::Stores::Memory.new) }

  it "put/get round-trip de um record (symbol -> string na borda)" do
    cs.put("agents", "bia", { id: "bia", provider: :deepseek })
    expect(cs.get("agents", "bia")).to eq("id" => "bia", "provider" => "deepseek")
  end

  it "get de chave inexistente -> nil (nunca exceção)" do
    expect(cs.get("agents", "sumiu")).to be_nil
  end

  it "keys/all listam o scope em ordem lexicográfica" do
    cs.put("agents", "b", { id: "b" })
    cs.put("agents", "a", { id: "a" })
    expect(cs.keys("agents")).to eq(%w[a b])
    expect(cs.all("agents")).to eq([{ "id" => "a" }, { "id" => "b" }])
  end

  it "scopes são isolados" do
    cs.put("agents", "x", { k: 1 })
    cs.put("settings", "x", { k: 2 })
    expect(cs.get("agents", "x")).to eq("k" => 1)
    expect(cs.get("settings", "x")).to eq("k" => 2)
  end

  it "delete -> bool (existia?)" do
    cs.put("mcp", "srv", { a: 1 })
    expect(cs.delete("mcp", "srv")).to be(true)
    expect(cs.delete("mcp", "srv")).to be(false)
  end

  it "scope desconhecido -> UnknownScope (fail-fast)" do
    expect { cs.put("nope", "k", {}) }.to raise_error(Harness::ConfigStore::UnknownScope)
    expect { cs.get("nope", "k") }.to raise_error(Harness::ConfigStore::UnknownScope)
  end
end
