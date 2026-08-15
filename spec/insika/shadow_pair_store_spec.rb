# frozen_string_literal: true

require "spec_helper"

# A backend that deletes a record the first time a transaction opens — the
# LGPD/retention race expire must survive.
class VanishingBackend < Insika::Stores::Memory
  attr_accessor :vanish

  def transaction(&blk)
    if @vanish
      delete(*@vanish)
      @vanish = nil
    end
    super
  end
end

# C2 — the pair record, written by two independent halves that must converge
# on one key without an index and without ordering assumptions.
RSpec.describe Insika::ShadowPairStore do
  let(:backend) { Insika::Stores::Memory.new }
  let(:store) { described_class.new(store: backend) }

  let(:key) { described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "wamid.HBg1") }

  def record_ours(**over)
    defaults = { id: key, channel: "relay", agent: "agent-store-ocean-drop",
                 session_id: "relay:5511999998888", task_id: "t-1", event_id: "wamid.HBg1",
                 inbound: "queria saber do pedido", reply: "já confiro pra você",
                 criterion_sha: "sha256:abc" }
    store.record_ours(**defaults.merge(over))
  end

  def record_incumbent(**over)
    defaults = { id: key, channel: "relay", event_id: "wamid.HBg1",
                 external_id: "5511999998888", reply: "me passa o número?" }
    store.record_incumbent(**defaults.merge(over))
  end

  describe "key_for" do
    it "is a 32-char digest of the triple, deterministic and order-free" do
      a = described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "wamid.HBg1")
      b = described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "wamid.HBg1")
      expect(a).to eq(b)
      expect(a.length).to eq(32)
      expect(a).to match(/\A[0-9a-f]+\z/)
    end

    it "differs on any field of the triple, and keeps the external_id out of the key space" do
      base = described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "e")
      expect(described_class.key_for(channel: "web", external_id: "5511999998888", event_id: "e")).not_to eq(base)
      expect(described_class.key_for(channel: "relay", external_id: "5511999998889", event_id: "e")).not_to eq(base)
      expect(described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "e2")).not_to eq(base)
      expect(base).not_to include("5511999998888")
    end
  end

  describe "the two halves converge" do
    it "lands on ONE complete record when ours arrives first" do
      record_ours
      pair = record_incumbent
      expect(pair.status).to eq(:complete)
      expect(pair.insika_reply).to eq("já confiro pra você")
      expect(pair.incumbent_reply).to eq("me passa o número?")
      expect(pair.agent).to eq("agent-store-ocean-drop")
      expect(store.counts[:complete]).to eq(1)
    end

    it "lands on ONE complete record when the incumbent arrives first" do
      record_incumbent
      expect(store.find(key).status).to eq(:open)
      pair = record_ours
      expect(pair.status).to eq(:complete)
      expect(pair.incumbent_reply).to eq("me passa o número?")
      expect(pair.insika_reply).to eq("já confiro pra você")
      expect(store.counts[:open]).to eq(0)
    end

    it "never nils the other half's fields" do
      record_incumbent
      record_ours
      record_incumbent(reply: "me passa o número?")
      pair = store.find(key)
      expect(pair.insika_reply).to eq("já confiro pra você")
      expect(pair.agent).to eq("agent-store-ocean-drop")
      expect(pair.criterion_sha).to eq("sha256:abc")
    end

    it "is first-write-wins: a mirror retry never rewrites the reply the customer received" do
      record_incumbent
      pair = record_incumbent(reply: "REWRITTEN BY A RETRY")
      expect(pair.incumbent_reply).to eq("me passa o número?")
      expect(store.find(key).incumbent_reply).to eq("me passa o número?")
    end
  end

  describe "a silent turn" do
    it "records an empty reply as :silent, and unjudged never returns it" do
      record_ours(reply: "")
      record_incumbent
      pair = store.find(key)
      expect(pair.status).to eq(:silent)
      expect(pair.complete?).to be(true)
      expect(store.unjudged).to be_empty
      expect(store.counts[:silent]).to eq(1)
    end
  end

  describe "unjudged" do
    it "returns complete pairs oldest-first, honouring limit and agent" do
      first = described_class.key_for(channel: "relay", external_id: "a", event_id: "e1")
      second = described_class.key_for(channel: "relay", external_id: "b", event_id: "e2")
      record_incumbent(id: first, at: Time.now.utc - 120) # the oldest pair
      record_ours(id: first)
      record_incumbent(id: second, at: Time.now.utc - 60)
      record_ours(id: second, agent: "other")
      record_ours
      record_incumbent

      expect(store.unjudged.map(&:id)).to eq([first, second, key])
      expect(store.unjudged(limit: 1).length).to eq(1)
      expect(store.unjudged(agent: "other").map(&:agent)).to eq(%w[other])
    end
  end

  describe "record_verdict" do
    it "stores the panel's verdict and moves the pair to :judged, never backwards" do
      record_ours
      record_incumbent
      pair = store.record_verdict(key, verdict: { "outcome" => "better", "vs" => "agent" })
      expect(pair.status).to eq(:judged)
      expect(pair.outcome).to eq("better")
      expect(pair.judged?).to be(true)
      expect(store.counts[:complete]).to eq(0)
      expect(store.counts[:judged]).to eq(1)
    end

    it "raises NotFoundError on a missing id" do
      expect { store.record_verdict("nope", verdict: {}) }
        .to raise_error(Insika::NotFoundError)
    end

    it "deep-stringifies the blob (store keys hold JSON)" do
      record_ours
      record_incumbent
      pair = store.record_verdict(key, verdict: { outcome: :better, judges: %i[a b] })
      expect(pair.verdict).to eq({ "outcome" => "better", "judges" => %w[a b] })
    end
  end

  describe "expire" do
    it "moves only :open pairs past the cutoff to :incomplete" do
      stale = record_incumbent(id: described_class.key_for(channel: "relay", external_id: "x", event_id: "e9"),
                               at: Time.now.utc - 86_400)
      record_ours
      record_incumbent

      expect(store.expire(older_than: Time.now.utc - 3600)).to eq(1)
      expect(store.find(stale.id).status).to eq(:incomplete)
      expect(store.find(key).status).to eq(:complete)
    end

    it "is a best-effort counter that never raises on an absent record" do
      expect(store.expire(older_than: Time.now.utc)).to eq(0)
    end

    # The write is update-style, not an upsert: a pair purged (LGPD) or deleted
    # between the scan and the write stays deleted — an upsert would resurrect
    # it as a ghost :incomplete carrying none of its fields.
    it "never resurrects a pair that vanished between the scan and the write" do
      stale_id = described_class.key_for(channel: "relay", external_id: "z", event_id: "e10")
      backend = VanishingBackend.new
      own = described_class.new(store: backend)
      own.record_incumbent(id: stale_id, channel: "relay", event_id: "e10", external_id: "z",
                           reply: "r", at: Time.now.utc - 86_400)
      backend.vanish = [described_class::SCOPE, "pair:#{stale_id}"]

      expect(own.expire(older_than: Time.now.utc - 3600)).to eq(0)
      expect(own.find(stale_id)).to be_nil
    end
  end

  describe "the mirror's reported time" do
    it "normalizes a String offset to UTC so lexicographic comparisons order correctly" do
      tokyo = described_class.key_for(channel: "relay", external_id: "tokyo", event_id: "e1")
      sao = described_class.key_for(channel: "relay", external_id: "sao", event_id: "e2")
      store.record_incumbent(id: tokyo, channel: "relay", event_id: "e1", external_id: "tokyo",
                             reply: "r", at: "2026-08-15T10:00:00+09:00")
      store.record_incumbent(id: sao, channel: "relay", event_id: "e2", external_id: "sao",
                             reply: "r", at: "2026-08-15T04:00:00-03:00")
      record_ours(id: tokyo)
      record_ours(id: sao)

      expect(store.find(tokyo).created_at).to eq("2026-08-15T01:00:00Z")
      expect(store.find(sao).created_at).to eq("2026-08-15T07:00:00Z")
      expect(store.unjudged.map(&:id)).to eq([tokyo, sao])
      expect(store.since(Time.utc(2026, 8, 15, 2))).to eq([store.find(sao)])
    end
  end

  describe "size" do
    it "counts the keys without materializing a single record" do
      expect(store.size).to eq(0)
      record_ours
      record_incumbent
      expect(store.size).to eq(1)
    end
  end

  describe "retention and LGPD" do
    # A pair that began `created_at` ago. The incumbent half lands FIRST with
    # the mirror's own `at`, so the record's created_at is the old timestamp.
    def plant(status:, session_id:, created_at:)
      id = SecureRandom.hex(16)
      store.record_incumbent(id: id, channel: "relay", event_id: id,
                             external_id: "5511999998888", reply: "me passa o número?",
                             at: created_at)
      store.record_ours(id: id, channel: "relay", agent: "a", session_id: session_id,
                        task_id: "t", event_id: id, inbound: "oi", reply: "ola",
                        criterion_sha: "sha256:x")
      store.record_verdict(id, verdict: { "outcome" => "better", "vs" => "agent" }) if status == :judged
      if status == :incomplete
        other = SecureRandom.hex(16)
        store.record_incumbent(id: other, channel: "relay", event_id: other,
                               external_id: "5511999998888", reply: "r", at: created_at)
        store.expire(older_than: Time.now.utc - 60)
        return other
      end
      id
    end

    it "delete_older_than spares open/complete (someone's unjudged evidence) and removes judged/incomplete" do
      old_judged = plant(status: :judged, session_id: "s1", created_at: Time.now.utc - 10 * 86_400)
      old_incomplete = plant(status: :incomplete, session_id: "s2", created_at: Time.now.utc - 10 * 86_400)
      keep = record_ours
      record_incumbent

      expect(store.delete_older_than(Time.now.utc - 7 * 86_400)).to eq(2)
      expect(store.find(old_judged)).to be_nil
      expect(store.find(old_incomplete)).to be_nil
      expect(store.find(keep.id)).not_to be_nil
      expect(store.find(key).status).to eq(:complete) # unjudged evidence spared
    end

    it "purge_sessions removes by session_id, including the customer text" do
      record_ours
      record_incumbent
      keep_id = described_class.key_for(channel: "relay", external_id: "keep", event_id: "e")
      record_ours(id: keep_id, session_id: "relay:keep")
      record_incumbent(id: keep_id)

      expect(store.purge_sessions(["relay:5511999998888"])).to eq(1)
      expect(store.find(key)).to be_nil
      expect(store.find(keep_id)).not_to be_nil
      expect(store.purge_sessions([])).to eq(0)
    end
  end

  describe "each / since / counts" do
    it "enumerates pairs lazily over a key snapshot and filters by created_at" do
      record_ours
      record_incumbent
      expect(store.each.to_a.length).to eq(1)
      expect(store.since(Time.now.utc - 60).length).to eq(1)
      expect(store.since(Time.now.utc + 60)).to be_empty
      expect(store.counts).to eq(open: 0, complete: 1, silent: 0, judged: 0, incomplete: 0)
    end
  end

  describe "smoke against Stores::SQLite" do
    it "passes the same lifecycle on the durable backend" do
      sqlite_store = described_class.new(store: Insika::Stores::SQLite.new(path: ":memory:"))
      id = described_class.key_for(channel: "relay", external_id: "5511999998888", event_id: "wamid.HBg1")
      sqlite_store.record_incumbent(id: id, channel: "relay", event_id: "wamid.HBg1",
                                    external_id: "5511999998888", reply: "r")
      sqlite_store.record_ours(id: id, channel: "relay", agent: "a",
                               session_id: "relay:5511999998888", task_id: "t",
                               event_id: "wamid.HBg1", inbound: "oi", reply: "ola",
                               criterion_sha: "sha256:x")
      expect(sqlite_store.find(id).status).to eq(:complete)
      expect(sqlite_store.unjudged.length).to eq(1)
    end
  end
end
