# frozen_string_literal: true

require "spec_helper"

#   — the evidence contract: parse the declaration, validate a tool
# RESULT against it, extract the lean items + attachments, and the session
# ledger that records ids for the grounding validator/enforcer.
RSpec.describe Insika::Evidence::Spec do
  describe ".parse" do
    it "nil -> nil (no declaration = parity, no evidence)" do
      expect(described_class.parse(nil)).to be_nil
    end

    it "bare string kind" do
      spec = described_class.parse("products")
      expect(spec.kind).to eq("products")
      expect(spec.items_path).to eq("items")
      expect(spec.attachments_path).to eq("attachments")
    end

    it "full form with non-default paths" do
      spec = described_class.parse({ "kind" => "products", "items" => "results",
                                     "attachments" => "cards" })
      expect(spec.kind).to eq("products")
      expect(spec.items_path).to eq("results")
      expect(spec.attachments_path).to eq("cards")
    end

    it "symbol keys are normalized to strings" do
      spec = described_class.parse({ kind: "products" })
      expect(spec.kind).to eq("products")
      expect(spec.to_h).to eq("kind" => "products", "items" => "items", "attachments" => "attachments")
    end

    it "raises on a missing kind" do
      expect { described_class.parse({}) }.to raise_error(Insika::ValidationError, /kind/)
      expect { described_class.parse({ "kind" => "  " }) }.to raise_error(Insika::ValidationError, /kind/)
    end

    it "raises on a path that is not a dotted string" do
      expect { described_class.parse({ "kind" => "products", "items" => "a b" }) }
        .to raise_error(Insika::ValidationError, /items/)
      expect { described_class.parse({ "kind" => "products", "attachments" => "a..b" }) }
        .to raise_error(Insika::ValidationError, /attachments/)
    end

    it "to_h omits a nil path and round-trips" do
      spec = described_class.parse({ "kind" => "products" })
      expect(described_class.parse(spec.to_h)).to eq(spec)
    end
  end
end

RSpec.describe Insika::Evidence::Processor do
  let(:spec) { Insika::Evidence::Spec.parse({ "kind" => "products" }) }

  # The evidence_envelope shape: the raw response body under the envelope-only key.
  def envelope_body(payload)
    { "__insika_body" => JSON.generate(payload) }
  end

  describe ".raw" do
    it "parses the __insika_body envelope key into a Hash" do
      raw = described_class.raw(spec, envelope_body("items" => [{ "id" => "A", "line" => "x" }]))
      expect(raw).to eq("items" => [{ "id" => "A", "line" => "x" }])
    end

    it "a code tool result (no __insika_body) IS the raw object" do
      raw = described_class.raw(spec, { "items" => [{ "id" => "A", "line" => "x" }] })
      expect(raw).to eq("items" => [{ "id" => "A", "line" => "x" }])
    end

    it "raises on a non-JSON __insika_body" do
      expect { described_class.raw(spec, { "__insika_body" => "{not json" }) }
        .to raise_error(JSON::ParserError)
    end
  end

  describe ".build (lean reshape)" do
    it "extracts items (id + line) from the raw body" do
      lean, attachments = described_class.build(spec, {
        "items" => [{ "id" => "SKU-123", "line" => "Tênis Runner 42" }]
      })
      expect(lean).to eq("items" => [{ "id" => "SKU-123", "line" => "Tênis Runner 42" }])
      expect(attachments).to eq([])
    end

    it "digs the declared paths (non-default)" do
      custom = Insika::Evidence::Spec.parse({ "kind" => "products", "items" => "results" })
      lean, = described_class.build(custom, { "results" => [{ "id" => "A", "line" => "x" }] })
      expect(lean["items"].first["id"]).to eq("A")
    end

    it "truncates a line to LINE_MAX" do
      lean, = described_class.build(spec, { "items" => [{ "id" => "A", "line" => "x" * 500 }] })
      expect(lean["items"].first["line"].length).to eq(Insika::Evidence::LINE_MAX)
    end

    it "caps items at MAX_ITEMS" do
      items = (1..30).map { |i| { "id" => "SKU-#{i}", "line" => "produto #{i}" } }
      lean, = described_class.build(spec, { "items" => items })
      expect(lean["items"].size).to eq(Insika::Evidence::MAX_ITEMS)
    end

    it "no items -> { items: [] }, never a null" do
      lean, = described_class.build(spec, {})
      expect(lean).to eq("items" => [])
    end

    it "extracts and validates attachments" do
      _, attachments = described_class.build(spec, {
        "items" => [{ "id" => "A", "line" => "x" }],
        "attachments" => [{ "type" => "card", "url" => "https://cdn/x.png", "caption" => "Tênis" }]
      })
      expect(attachments).to eq([{ "type" => "card", "url" => "https://cdn/x.png", "caption" => "Tênis" }])
    end

    it "drops malformed attachments (no url, non-hash) and caps at MAX_ATTACHMENTS" do
      list = [{ "type" => "card" },
              "junk",
              { "type" => "card", "url" => "https://ok" },
              *Array.new(30) { |i| { "url" => "https://cdn/#{i}" } }]
      _, attachments = described_class.build(spec, { "items" => [], "attachments" => list })
      expect(attachments.size).to eq(Insika::Evidence::MAX_ATTACHMENTS)
      expect(attachments).not_to include(hash_including("url" => ""))
      expect(attachments).not_to include("junk")
    end

    it "caps each attachment url at URL_MAX" do
      url = "https://cdn.example.com/#{"a" * 1000}"
      _, attachments = described_class.build(spec, { "items" => [], "attachments" => [{ "url" => url }] })
      expect(attachments.first["url"].length).to eq(Insika::Evidence::URL_MAX)
    end
  end
end

RSpec.describe "Insika::Evidence.valid_attachments" do
  # the module function keeps malformed entries out of the outbox payload.
  it "rejects entries without a url and non-hash entries" do
    list = [{ "type" => "card" }, "junk", { "url" => "https://ok" }]
    expect(Insika::Evidence.valid_attachments(list))
      .to eq([{ "type" => "", "url" => "https://ok", "caption" => nil }])
  end
end

RSpec.describe Insika::EvidenceLedger do
  let(:backend) { Insika::Stores::Memory.new }
  let(:store) { Insika::SessionStore.new(store: backend) }

  before { store.create(id: "s1") }

  def ledger(session_id: "s1", store: nil)
    store ||= self.store
    Insika::EvidenceLedger.new(store: store, session_id: session_id)
  end

  it "records ids (stringified, empties dropped); the ids reader dedupes" do
    l = ledger
    l.record(%w[SKU-1 SKU-1 123])
    l.record("")
    expect(l.ids).to eq(%w[SKU-1 123])
  end

  it "ungrounded_count increments and returns the claim" do
    l = ledger
    expect(l.ungrounded_count("SKU-999")).to eq("SKU-999")
    expect(l.ungrounded_count("SKU-999")).to eq("SKU-999")
    expect(l.ungrounded).to eq(2)
  end

  it "flush! appends to the session record and clears the in-memory buffer" do
    l = ledger
    l.record(%w[SKU-1])
    l.ungrounded_count("SKU-999")
    l.flush!

    session = store.find("s1")
    expect(session.evidence["ids"]).to eq(["SKU-1"])
    expect(session.evidence["ungrounded"]).to eq(1)
    expect(l.ids).to eq(["SKU-1"]) # still visible (from the session)
    expect(l.ungrounded).to eq(0)
  end

  it "a resumed ledger (new instance on the same session) sees the persisted ids" do
    ledger.record(%w[SKU-1 SKU-2]).flush!

    resumed = ledger
    resumed.record(%w[SKU-3])
    expect(resumed.ids).to eq(%w[SKU-1 SKU-2 SKU-3])
  end

  it "no session -> in-memory only, flush! is a no-op" do
    l = Insika::EvidenceLedger.new(store: store, session_id: nil)
    l.record(%w[SKU-1])
    expect { l.flush! }.not_to raise_error
    expect(l.ids).to eq(["SKU-1"])
  end

  it "a store failure on flush! is swallowed (evidence must never fail a committed turn)" do
    broken = Object.new
    def broken.find(*) = raise(Insika::StoreError, "boom")
    def broken.append_evidence(*) = raise(Insika::StoreError, "boom")
    l = Insika::EvidenceLedger.new(store: broken, session_id: "s1")
    l.record(%w[SKU-1])
    expect { l.flush! }.not_to raise_error
  end

  it "a session purged mid-turn (forget_customer/session_purge -> NotFoundError) is swallowed too" do
    gone = Object.new
    def gone.append_evidence(*) = raise(Insika::NotFoundError, "session not found: s1")
    l = Insika::EvidenceLedger.new(store: gone, session_id: "s1")
    l.record(%w[SKU-1])
    expect { l.flush! }.not_to raise_error
  end

  it "caps the effective set at MAX_IDS, oldest evicted" do
    l = ledger
    many = (1..(Insika::EvidenceLedger::MAX_IDS + 10)).map { |i| "SKU-#{i}" }
    l.record(many)
    expect(l.ids.size).to eq(Insika::EvidenceLedger::MAX_IDS)
    expect(l.ids.first).to eq("SKU-11")
  end

  describe "E1 — the lean envelope's token delta (engine half)" do
    let(:fat_spec) { Insika::Evidence::Spec.parse({ "kind" => "products" }) }

    it "a realistic catalog body collapses to a fraction of its tokens" do
      raw = {
        "items" => (1..10).map do |i|
          { "id" => "TNSR#{i.to_s.rjust(4, '0')}",
            "line" => "Tênis Runner #{i}",
            "sku_internal" => "x#{i}", "stock" => i, "price_cents" => 29_990,
            "facet" => { "brand" => "Acme", "category" => "corrida", "colors" => %w[preto branco] },
            "image_urls" => Array.new(3) { |j| "https://cdn.acme/img/tnsr#{i}-#{j}.png" },
            "description" => "sola em borracha, cabedal em mesh respirável, tamanhos 36 a 44" }
        end
      }
      lean, = Insika::Evidence::Processor.build(fat_spec, raw)

      fat_tokens = Insika::TokenEstimator.estimate(JSON.generate(raw))
      lean_tokens = Insika::TokenEstimator.estimate(JSON.generate(lean))
      expect(lean_tokens).to be < fat_tokens
      expect(lean_tokens).to be < fat_tokens / 2
    end
  end
end
