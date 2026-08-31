# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::SessionStore do
  # Runs against Memory; parity with SQLite is guaranteed by the
  # contract suite. A smoke test with SQLite ":memory:" closes the loop.
  subject(:sessions) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }

  describe "#create" do
    it "returns Session with defaults (uuid, empty arrays/hash, ISO8601 timestamps)" do
      session = sessions.create

      expect(session).to be_a(described_class::Session)
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(session.messages).to eq([])
      expect(session.vars).to eq({})
      expect(session.memory_refs).to eq([])
      expect(session.created_at).to eq(session.updated_at)
      expect { Time.iso8601(session.created_at) }.not_to raise_error
    end

    it "accepts explicit id and vars, normalizing symbols" do
      session = sessions.create(id: "s-1", vars: { plan: :pro, nested: { a: 1 } })

      expect(session.id).to eq("s-1")
      expect(session.vars).to eq({ "plan" => "pro", "nested" => { "a" => 1 } })
    end

    it "raises ArgumentError on duplicate id (does not overwrite)" do
      sessions.create(id: "x")

      expect { sessions.create(id: "x") }.to raise_error(ArgumentError)
    end
  end

  describe "#find" do
    it "returns nil for nonexistent id" do
      expect(sessions.find("nope")).to be_nil
    end

    it "round-trips create->find with string keys" do
      created = sessions.create(id: "s-2", vars: { a: 1 })
      found = sessions.find("s-2")

      expect(found.id).to eq("s-2")
      expect(found.vars).to eq({ "a" => 1 })
      expect(found.created_at).to eq(created.created_at)
    end
  end

  describe "#append_messages" do
    before { sessions.create(id: "s") }

    it "concatenates preserving order and advances updated_at" do
      before_at = sessions.find("s").updated_at
      sessions.append_messages("s", { "role" => "user", "content" => "oi" })
      session = sessions.append_messages("s", { "role" => "assistant", "content" => "olá" })

      expect(session.messages.map { |m| m["content"] }).to eq(%w[oi olá])
      expect(session.messages.size).to eq(2)
      expect(session.updated_at >= before_at).to be(true)
    end

    it "normalizes message with symbol keys to string keys" do
      session = sessions.append_messages("s", { role: :user, content: "oi" })

      expect(session.messages.first).to include("role" => "user", "content" => "oi")
    end

    it "stamps 'at' ISO8601 when absent and preserves when present" do
      sessions.append_messages("s", { role: :user, content: "sem at" })
      sessions.append_messages("s", { role: :user, content: "com at", at: "2020-01-01T00:00:00Z" })
      messages = sessions.find("s").messages

      expect { Time.iso8601(messages[0]["at"]) }.not_to raise_error
      expect(messages[1]["at"]).to eq("2020-01-01T00:00:00Z")
    end

    it "accepts an Array of messages at once" do
      session = sessions.append_messages("s", [
                                            { role: :user, content: "a" },
                                            { role: :assistant, content: "b" }
                                          ])

      expect(session.messages.size).to eq(2)
    end

    it "raises NotFoundError on nonexistent session" do
      expect { sessions.append_messages("nope", { role: :user }) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe "#update_vars" do
    before { sessions.create(id: "s", vars: { "a" => 1 }) }

    it "does a shallow merge and advances updated_at" do
      session = sessions.update_vars("s", { b: 2 })

      expect(session.vars).to eq({ "a" => 1, "b" => 2 })
    end

    it "entirely replaces the value of an existing key (shallow merge)" do
      sessions.update_vars("s", { "nested" => { "x" => 1 } })
      session = sessions.update_vars("s", { nested: { y: 2 } })

      expect(session.vars["nested"]).to eq({ "y" => 2 })
    end

    it "raises NotFoundError on nonexistent session" do
      expect { sessions.update_vars("nope", { a: 1 }) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe "briefing (— session working state)" do
    before { sessions.create(id: "s") }

    it "create initializes briefing to empty fields + nil next_step" do
      session = sessions.create(id: "s2")
      expect(session.briefing).to eq({ "fields" => {}, "next_step" => nil })
    end

    describe "#update_briefing" do
      it "upserts one field and returns the Session with the fresh briefing" do
        session = sessions.update_briefing("s", field: "size", value: "M")
        expect(session.briefing["fields"]).to eq("size" => "M")
        expect(sessions.find("s").briefing["fields"]).to eq("size" => "M")
      end

      it "overwrites an existing field" do
        sessions.update_briefing("s", field: "size", value: "M")
        session = sessions.update_briefing("s", field: "size", value: "L")
        expect(session.briefing["fields"]).to eq("size" => "L")
      end

      it "a blank value REMOVES the key (absence = not yet asked)" do
        sessions.update_briefing("s", field: "size", value: "M")
        session = sessions.update_briefing("s", field: "size", value: "   ")
        expect(session.briefing["fields"]).to eq({})
        expect(sessions.find("s").briefing["fields"]).to eq({})
      end

      it "utf8s the value (a non-UTF8 byte string is tagged)" do
        latin1 = "M".dup.force_encoding(Encoding::ISO_8859_1)
        sessions.update_briefing("s", field: "size", value: latin1)
        expect(sessions.find("s").briefing["fields"]["size"].encoding).to eq(Encoding::UTF_8)
      end

      it "coerces a non-string value with to_s" do
        session = sessions.update_briefing("s", field: "size", value: 42)
        expect(session.briefing["fields"]).to eq("size" => "42")
      end

      it "normalizes the field name to a String" do
        sessions.update_briefing("s", field: :size, value: "M")
        expect(sessions.find("s").briefing["fields"]).to eq("size" => "M")
      end

      it "leaves next_step untouched" do
        sessions.set_next_step("s", text: "send link at 10")
        session = sessions.update_briefing("s", field: "size", value: "M")
        expect(session.briefing["next_step"]).to eq("send link at 10")
      end

      it "raises NotFoundError on a nonexistent session" do
        expect { sessions.update_briefing("nope", field: "size", value: "M") }
          .to raise_error(Insika::NotFoundError)
      end
    end

    describe "#set_next_step" do
      it "sets the agreed next step" do
        session = sessions.set_next_step("s", text: "send the payment link tomorrow at 10")
        expect(session.briefing["next_step"]).to eq("send the payment link tomorrow at 10")
        expect(sessions.find("s").briefing["next_step"]).to eq("send the payment link tomorrow at 10")
      end

      it "a blank text clears to nil" do
        sessions.set_next_step("s", text: "send the payment link")
        session = sessions.set_next_step("s", text: "")
        expect(session.briefing["next_step"]).to be_nil
      end

      it "leaves fields untouched" do
        sessions.update_briefing("s", field: "size", value: "M")
        session = sessions.set_next_step("s", text: "send the payment link")
        expect(session.briefing["fields"]).to eq("size" => "M")
      end

      it "raises NotFoundError on a nonexistent session" do
        expect { sessions.set_next_step("nope", text: "x") }
          .to raise_error(Insika::NotFoundError)
      end
    end

    it "an old record without the 'briefing' key reads as empty (no migration, no nil leak)" do
      backend.set("sessions", "session:legacy", { "id" => "legacy", "messages" => [],
                                                   "vars" => {}, "memory_refs" => [],
                                                   "created_at" => "2026-01-01T00:00:00Z",
                                                   "updated_at" => "2026-01-01T00:00:00Z" })
      expect(sessions.find("legacy").briefing).to eq({ "fields" => {}, "next_step" => nil })
    end
  end

  describe "evidence (— the session evidence ledger memory)" do
    before { sessions.create(id: "s") }

    it "create initializes evidence to empty ids + ungrounded 0" do
      session = sessions.create(id: "s2")
      expect(session.evidence).to eq({ "ids" => [], "ungrounded" => 0 })
    end

    it "an old record without the 'evidence' key reads as nil (no migration)" do
      backend.set("sessions", "session:legacy2", { "id" => "legacy2", "messages" => [],
                                                    "vars" => {}, "memory_refs" => [],
                                                    "created_at" => "2026-01-01T00:00:00Z",
                                                    "updated_at" => "2026-01-01T00:00:00Z" })
      expect(sessions.find("legacy2").evidence).to be_nil
    end

    describe "#append_evidence" do
      it "merges + dedupes ids and accumulates the ungrounded delta" do
        sessions.append_evidence("s", ids: %w[SKU-1 SKU-2], ungrounded: 1)
        session = sessions.append_evidence("s", ids: %w[SKU-2 SKU-3], ungrounded: 2)

        expect(session.evidence["ids"]).to eq(%w[SKU-1 SKU-2 SKU-3])
        expect(session.evidence["ungrounded"]).to eq(3)
      end

      it "drops empty ids and caps at MAX_IDS (oldest evicted)" do
        many = (1..(Insika::EvidenceLedger::MAX_IDS + 5)).map { |i| "SKU-#{i}" }
        session = sessions.append_evidence("s", ids: [""] + many, ungrounded: 0)

        expect(session.evidence["ids"].size).to eq(Insika::EvidenceLedger::MAX_IDS)
        expect(session.evidence["ids"].first).to eq("SKU-6")
      end

      it "appends cleanly to an old record that never had the key" do
        backend.set("sessions", "session:legacy3", { "id" => "legacy3", "messages" => [],
                                                      "vars" => {}, "memory_refs" => [],
                                                      "created_at" => "2026-01-01T00:00:00Z",
                                                      "updated_at" => "2026-01-01T00:00:00Z" })
        session = sessions.append_evidence("legacy3", ids: %w[SKU-1], ungrounded: 1)
        expect(session.evidence["ids"]).to eq(["SKU-1"])
        expect(session.evidence["ungrounded"]).to eq(1)
      end

      it "raises NotFoundError on a nonexistent session" do
        expect { sessions.append_evidence("nope", ids: %w[SKU-1], ungrounded: 0) }
          .to raise_error(Insika::NotFoundError)
      end
    end
  end

  describe "compaction (RFC-0044 — the persisted boundary)" do
    before { sessions.create(id: "s") }

    it "a fresh session reads as compaction nil (old records need no migration)" do
      expect(sessions.find("s").compaction).to be_nil
    end

    it "#set_compaction persists summary/upto/model, stamps at, and counts runs" do
      sessions.set_compaction("s", summary: "resumo", upto: 12, model: "flash")
      state = sessions.find("s").compaction
      expect(state).to include("summary" => "resumo", "upto" => 12, "runs" => 1, "model" => "flash")
      expect(state["at"]).not_to be_nil
    end

    it "runs increments across compactions; upto moves forward" do
      sessions.set_compaction("s", summary: "a", upto: 10)
      sessions.set_compaction("s", summary: "b", upto: 20)
      expect(sessions.find("s").compaction).to include("summary" => "b", "upto" => 20, "runs" => 2)
    end

    it "upto is MONOTONIC: a stale write (same or lower boundary) is a no-op" do
      sessions.set_compaction("s", summary: "a", upto: 10)
      sessions.set_compaction("s", summary: "stale", upto: 10)
      sessions.set_compaction("s", summary: "staler", upto: 3)
      expect(sessions.find("s").compaction).to include("summary" => "a", "upto" => 10, "runs" => 1)
    end

    it "nil model is omitted (compact), the summary is utf8-scrubbed" do
      sessions.set_compaction("s", summary: "ok\xC3", upto: 1)
      state = sessions.find("s").compaction
      expect(state).not_to have_key("model")
      expect(state["summary"].valid_encoding?).to be(true)
    end

    it "raises NotFoundError on a nonexistent session" do
      expect { sessions.set_compaction("nope", summary: "x", upto: 1) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe "#delete" do
    it "returns true and removes an existing session" do
      sessions.create(id: "s")

      expect(sessions.delete("s")).to be(true)
      expect(sessions.find("s")).to be_nil
    end

    it "returns false for nonexistent id (no exception)" do
      expect(sessions.delete("nope")).to be(false)
    end
  end

  describe "#each_id" do
    it "enumerates ids without the 'session:' prefix" do
      %w[a b c].each { |id| sessions.create(id: id) }

      expect(sessions.each_id.to_a).to contain_exactly("a", "b", "c")
    end

    it "returns an Enumerator without a block" do
      expect(sessions.each_id).to be_a(Enumerator)
    end

    it "does not see keys from another backend scope (isolation)" do
      sessions.create(id: "a")
      backend.set("other-scope", "session:intruso", { "id" => "intruso" })

      expect(sessions.each_id.to_a).to eq(["a"])
    end
  end

  describe "backend error propagation" do
    it "lets StoreError propagate without re-wrapping" do
      # non-JSONable value forces the StoreError on the backend write;
      # the SessionStore must not capture/re-wrap.
      sessions.create(id: "s")

      expect { sessions.update_vars("s", { obj: Object.new }) }
        .to raise_error(Insika::StoreError)
    end
  end

  describe "smoke against Stores::SQLite ':memory:'" do
    it "create->append->find flow identical to Memory" do
      require "sqlite3"
      sqlite = Insika::Stores::SQLite.new(path: ":memory:")
      store = described_class.new(store: sqlite)

      store.create(id: "s")
      store.append_messages("s", { role: :user, content: "oi" })
      session = store.find("s")

      expect(session.messages.first).to include("role" => "user", "content" => "oi")
      expect(session.messages.first["at"]).not_to be_nil
    ensure
      sqlite&.close
    end
  end
end
