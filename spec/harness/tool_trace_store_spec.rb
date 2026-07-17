# frozen_string_literal: true

require "spec_helper"

# Trace de tool-calls por sessão (debug no Studio; FOLLOWUP §3.1).
RSpec.describe Harness::ToolTraceStore do
  subject(:store) { described_class.new(store: Harness::Stores::Memory.new) }

  def entry(**over)
    { "turn" => 1, "tool" => "search_products", "call_id" => "c1",
      "args" => { "query" => "trufa" }, "result" => { "sample_products" => [{ "name" => "Trufa" }] },
      "ms" => 42, "at" => "2026-07-16T00:00:00Z" }.merge(over)
  end

  it "grava e lê por sessão em ordem cronológica" do
    store.record(session_id: "s1", entry: entry(call_id: "a"))
    store.record(session_id: "s1", entry: entry(call_id: "b"))
    got = store.for_session("s1")
    expect(got.map { |t| t["call_id"] }).to eq(%w[a b])
    expect(got.first).to include("tool" => "search_products", "turn" => 1, "ms" => 42, "ok" => true)
  end

  it "sessão sem trace -> []" do
    expect(store.for_session("nada")).to eq([])
  end

  it "session_id vazio -> no-op" do
    store.record(session_id: "", entry: entry)
    expect(store.for_session("")).to eq([])
  end

  it "detecta erro (result com chave error) -> ok=false" do
    store.record(session_id: "s", entry: entry(result: { "error" => "HTTP 404" }))
    expect(store.for_session("s").first["ok"]).to be(false)
  end

  it "mascara valores de chaves sensíveis (recursivo)" do
    store.record(session_id: "s", entry: entry(
                                     args: { "Authorization" => "Bearer SEGREDO", "nested" => { "api_key" => "xyz", "q" => "ok" } }
                                   ))
    args = store.for_session("s").first["args"]
    expect(args).to include(Harness::SecretMasking::SENTINEL)
    expect(args).not_to include("SEGREDO")
    expect(args).not_to include("xyz")
    expect(args).to include("ok") # valor não-sensível preservado
  end

  it "trunca campos grandes (args/result)" do
    store.record(session_id: "s", entry: entry(result: "x" * 5000))
    expect(store.for_session("s").first["result"]).to end_with("…(truncado)")
    expect(store.for_session("s").first["result"].length).to be <= (2000 + 20)
  end

  it "capa a lista por sessão (não cresce sem fim)" do
    (described_class::MAX_PER_SESSION + 30).times { |i| store.record(session_id: "s", entry: entry(call_id: "c#{i}")) }
    expect(store.for_session("s").size).to eq(described_class::MAX_PER_SESSION)
    # mantém as MAIS RECENTES
    expect(store.for_session("s").last["call_id"]).to eq("c#{described_class::MAX_PER_SESSION + 29}")
  end

  it "clear remove o trace da sessão" do
    store.record(session_id: "s", entry: entry)
    expect(store.clear("s")).to be(true)
    expect(store.for_session("s")).to eq([])
  end
end
