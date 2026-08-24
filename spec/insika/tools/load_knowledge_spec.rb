# frozen_string_literal: true

require "spec_helper"
require "insika/tools/load_knowledge" # loaded lazily in production; explicit in the test

RSpec.describe Insika::Tools::LoadKnowledge do
  let(:store) { Insika::KnowledgeStore.new(store: Insika::Stores::Memory.new) }

  def seed(name, body: "the full concept body")
    store.write("acme", name,
                Insika::Knowledge::Concept.render(
                  name: name, description: "d", type: "fact", body: body,
                  provenance: "observed", confidence: 0.6, sources: ["sess_1"], occurrences: 1,
                  created_at: "2026-08-24T00:00:00Z", updated_at: "2026-08-24T00:00:00Z"
                ))
  end

  it "returns the concept's stored markdown when present" do
    seed("cep-13-campinas")
    tool = described_class.new(store, "acme")

    expect(tool.execute(name: "cep-13-campinas")).to include("the full concept body")
  end

  it "reports a name that does not exist, without raising" do
    tool = described_class.new(store, "acme")

    expect(tool.execute(name: "ghost")).to eq({ error: "concept 'ghost' not found" })
  end

  it "the name override, so wire_callbacks/:knowledge_retrieved can key on it" do
    expect(described_class.new(store, "acme").name).to eq("load_knowledge")
  end

  describe "scoping" do
    it "one agent's concepts are invisible to another" do
      seed("cep-13-campinas")
      tool = described_class.new(store, "zeta")

      expect(tool.execute(name: "cep-13-campinas")).to eq({ error: "concept 'cep-13-campinas' not found" })
    end

    it "an explicit tenant reads that tenant's cell" do
      store.write("acme", "loja-a-only",
                  Insika::Knowledge::Concept.render(
                    name: "loja-a-only", description: "d", type: "fact", body: "loja A only",
                    provenance: "observed", confidence: 0.6, sources: [], occurrences: 1,
                    created_at: "2026-08-24T00:00:00Z", updated_at: "2026-08-24T00:00:00Z"
                  ), tenant: "loja-a")
      tool = described_class.new(store, "acme", tenant: "loja-a")

      expect(tool.execute(name: "loja-a-only")).to include("loja A only")
    end
  end

  # This tool is NOT enveloped, and the envelope is what writes the tool trace —
  # so a retrieval was the one call missing from the Studio's trace.
  describe "trace (it is not enveloped, so it records itself)" do
    let(:recorder) { [] }
    let(:trace_recorder) do
      Class.new do
        def initialize(sink) = @sink = sink
        def record(session_id:, entry:) = @sink << { session_id: session_id, entry: entry }
      end.new(recorder)
    end
    let(:state) do
      task = Struct.new(:id, :session_id).new("t1", "s1")
      Struct.new(:task, :turn).new(task, 3)
    end

    it "records the call keyed by session, in the envelope's shape" do
      seed("cep-13-campinas")
      tool = described_class.new(store, "acme", trace_recorder: trace_recorder, state: state)

      tool.execute(name: "cep-13-campinas")

      expect(recorder.length).to eq(1)
      expect(recorder.first[:session_id]).to eq("s1")
      entry = recorder.first[:entry]
      expect(entry["tool"]).to eq("load_knowledge")
      expect(entry["turn"]).to eq(3)
      expect(entry["args"]).to eq({ "name" => "cep-13-campinas" })
      expect(entry["ms"]).to be_a(Integer)
    end

    it "records a not-found result too" do
      tool = described_class.new(store, "acme", trace_recorder: trace_recorder, state: state)

      tool.execute(name: "ghost")

      expect(recorder.first[:entry]["result"]).to eq({ error: "concept 'ghost' not found" })
    end

    it "no recorder -> no trace, and the result still returns (parity)" do
      seed("cep-13-campinas")
      tool = described_class.new(store, "acme")

      expect(tool.execute(name: "cep-13-campinas")).to include("the full concept body")
      expect(recorder).to be_empty
    end

    it "a session-less state does not trace and never breaks the call" do
      seed("cep-13-campinas")
      task = Struct.new(:id, :session_id).new("t1", nil)
      stateless = Struct.new(:task, :turn).new(task, 1)
      tool = described_class.new(store, "acme", trace_recorder: trace_recorder, state: stateless)

      expect(tool.execute(name: "cep-13-campinas")).to include("the full concept body")
      expect(recorder).to be_empty
    end

    it "a recorder that raises never breaks the turn" do
      seed("cep-13-campinas")
      exploding = Class.new { def record(session_id:, entry:) = raise("trace down") }.new
      tool = described_class.new(store, "acme", trace_recorder: exploding, state: state)

      expect(tool.execute(name: "cep-13-campinas")).to include("the full concept body")
    end
  end
end
