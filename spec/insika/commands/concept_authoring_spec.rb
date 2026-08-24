# frozen_string_literal: true

require "spec_helper"

# authoring commands for learned concepts — the Studio's write/delete/restore
# path, same shape as skill authoring.
RSpec.describe "Concept authoring commands" do
  let(:knowledge_store) { Insika::KnowledgeStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Insika::Command.build(type, payload)

  def concept_md(name, type: "fact", body: "body")
    Insika::Knowledge::Concept.render(
      name: name, description: "d", type: type, body: body, provenance: "observed", confidence: 0.6,
      sources: [], occurrences: 1, created_at: "2026-08-24T00:00:00Z", updated_at: "2026-08-24T00:00:00Z"
    )
  end

  describe Insika::Commands::WriteConcept do
    subject(:handler) { described_class.new(knowledge_store: knowledge_store, event_stream: stream) }

    it "writes the concept and emits :knowledge_learned" do
      res = handler.call(cmd(:write_concept, { "agent" => "acme", "name" => "cep-13",
                                              "content" => concept_md("cep-13", body: "faz entrega") }))
      expect(res[:name]).to eq("cep-13")
      expect(res[:agent]).to eq("acme")
      expect(knowledge_store.get("acme", "cep-13")).to include("faz entrega")
      expect(events.map(&:type)).to eq([:knowledge_learned])
      expect(events.first.data).to eq(name: "cep-13", type: "fact", agent: "acme")
    end

    it "name and agent are required; frontmatter without a name raises" do
      expect { handler.call(cmd(:write_concept, { "agent" => "acme", "content" => concept_md("cep-13") })) }
        .to raise_error(Insika::ValidationError, /name/)
      expect { handler.call(cmd(:write_concept, { "name" => "cep-13", "content" => concept_md("cep-13") })) }
        .to raise_error(Insika::ValidationError, /agent/)
      expect { handler.call(cmd(:write_concept, { "agent" => "acme", "name" => "x", "content" => "no frontmatter" })) }
        .to raise_error(Insika::ValidationError, /frontmatter/)
    end

    it "an explicit tenant writes into that tenant's cell" do
      handler.call(cmd(:write_concept, { "agent" => "acme", "name" => "cep-13", "tenant" => "loja-a",
                                        "content" => concept_md("cep-13", body: "loja A") }))
      expect(knowledge_store.get("acme", "cep-13")).to be_nil
      expect(knowledge_store.get("acme", "cep-13", tenant: "loja-a")).to include("loja A")
    end

    it "an operator can promote provenance from observed to policy by hand" do
      handler.call(cmd(:write_concept, { "agent" => "acme", "name" => "cep-13", "content" => concept_md("cep-13") }))
      promoted = concept_md("cep-13").sub('provenance: "observed"', 'provenance: "policy"')
      handler.call(cmd(:write_concept, { "agent" => "acme", "name" => "cep-13", "content" => promoted }))
      expect(knowledge_store.get("acme", "cep-13")).to include('provenance: "policy"')
    end
  end

  describe Insika::Commands::DeleteConcept do
    subject(:handler) { described_class.new(knowledge_store: knowledge_store, event_stream: stream) }

    before { knowledge_store.write("acme", "cep-13", concept_md("cep-13")) }

    it "deletes the concept and emits :knowledge_deleted" do
      res = handler.call(cmd(:delete_concept, { "agent" => "acme", "name" => "cep-13" }))
      expect(res).to eq(name: "cep-13", agent: "acme", tenant: nil, deleted: true)
      expect(knowledge_store.get("acme", "cep-13")).to be_nil
      expect(events.map(&:type)).to eq([:knowledge_deleted])
    end

    it "raises NotFoundError for a name that does not exist" do
      expect { handler.call(cmd(:delete_concept, { "agent" => "acme", "name" => "missing" })) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe Insika::Commands::RestoreConcept do
    subject(:handler) { described_class.new(knowledge_store: knowledge_store, event_stream: stream) }

    before do
      knowledge_store.write("acme", "cep-13", concept_md("cep-13", body: "v1"))
      knowledge_store.write("acme", "cep-13", concept_md("cep-13", body: "v2"))
    end

    it "restores an old version as the current content" do
      handler.call(cmd(:restore_concept, { "agent" => "acme", "name" => "cep-13", "version" => 0 }))
      expect(knowledge_store.get("acme", "cep-13")).to include("v1")
      expect(events.map(&:type)).to eq([:knowledge_learned])
    end

    it "version is required" do
      expect { handler.call(cmd(:restore_concept, { "agent" => "acme", "name" => "cep-13" })) }
        .to raise_error(Insika::ValidationError, /version/)
    end
  end
end
