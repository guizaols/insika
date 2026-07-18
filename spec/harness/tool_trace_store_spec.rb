# frozen_string_literal: true

require "spec_helper"

# Per-session tool-call trace (debug in Studio; FOLLOWUP §3.1).
RSpec.describe Harness::ToolTraceStore do
  subject(:store) { described_class.new(store: Harness::Stores::Memory.new) }

  def entry(**over)
    { "turn" => 1, "tool" => "search_products", "call_id" => "c1",
      "args" => { "query" => "trufa" }, "result" => { "sample_products" => [{ "name" => "Trufa" }] },
      "ms" => 42, "at" => "2026-07-16T00:00:00Z" }.merge(over)
  end

  it "records and reads per session in chronological order" do
    store.record(session_id: "s1", entry: entry(call_id: "a"))
    store.record(session_id: "s1", entry: entry(call_id: "b"))
    got = store.for_session("s1")
    expect(got.map { |t| t["call_id"] }).to eq(%w[a b])
    expect(got.first).to include("tool" => "search_products", "turn" => 1, "ms" => 42, "ok" => true)
  end

  it "session without a trace -> []" do
    expect(store.for_session("nada")).to eq([])
  end

  it "empty session_id -> no-op" do
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
    expect(args).to include("ok") # non-sensitive value preserved
  end

  it "trunca campos grandes (args/result)" do
    store.record(session_id: "s", entry: entry(result: "x" * 5000))
    expect(store.for_session("s").first["result"]).to end_with("…(truncado)")
    expect(store.for_session("s").first["result"].length).to be <= (2000 + 20)
  end

  it "caps the per-session list (does not grow unbounded)" do
    (described_class::MAX_PER_SESSION + 30).times { |i| store.record(session_id: "s", entry: entry(call_id: "c#{i}")) }
    expect(store.for_session("s").size).to eq(described_class::MAX_PER_SESSION)
    # mantém as MAIS RECENTES
    expect(store.for_session("s").last["call_id"]).to eq("c#{described_class::MAX_PER_SESSION + 29}")
  end

  it "clear removes the session's trace" do
    store.record(session_id: "s", entry: entry)
    expect(store.clear("s")).to be(true)
    expect(store.for_session("s")).to eq([])
  end
end
