# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::SessionInsights do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:insights) { described_class.new(session_store: sessions, task_store: tasks) }

  let(:flag) { { "category" => "invented_policy", "source" => "moderator", "detail" => "Pix 3% not in tools" } }

  before do
    # ran in the engine: two turns, the second reply flagged
    sessions.create(id: "real", vars: { "agent" => "shop", "customer" => "s1:c1" })
    sessions.append_messages("real", [{ "role" => "user", "content" => "tem pix?", "guardrail_flags" => [flag] },
                                      { "role" => "assistant", "content" => "Pix com 3% de desconto." }])
    2.times { tasks.create(command: { "type" => "send_message" }, session_id: "real") }
    # imported: messages, never a turn
    sessions.create(id: "imported", vars: { "agent" => "shop" })
    sessions.append_messages("imported", [{ "role" => "user", "content" => "oi" }])
    # simulator traffic
    sessions.create(id: "sim-1", vars: { "agent" => "shop" })
    tasks.create(command: { "type" => "send_message" }, session_id: "sim-1")
  end

  describe "#agent_summary" do
    it "counts sessions with turns apart from imported ones, without synthetic traffic" do
      row = insights.agent_summary.first
      expect(row).to include("agent" => "shop", "sessions" => 2, "sessions_with_turns" => 1, "turns" => 2,
                             "turns_by_status" => { "queued" => 2 }, "flagged_sessions" => 1)
    end

    it "never bulk-reads the tasks scope (each report held GBs in the worker)" do
      allow(backend).to receive(:entries).and_call_original
      expect(backend).not_to receive(:entries).with(Insika::TaskStore::SCOPE, anything)
      expect(insights.agent_summary.first["turns"]).to eq(2)
    end

    it "includes synthetic sessions when asked" do
      expect(insights.agent_summary(include_synthetic: true).first["sessions_with_turns"]).to eq(2)
    end
  end

  describe "#list_sessions" do
    it "lists only sessions the engine ran by default" do
      expect(insights.list_sessions.map { _1["session_id"] }).to eq(["real"])
    end

    it "lists only imported sessions with with_turns: false" do
      expect(insights.list_sessions(with_turns: false).map { _1["session_id"] }).to eq(["imported"])
    end

    it "filters by agent" do
      expect(insights.list_sessions(agent: "other")).to be_empty
    end
  end

  describe "#transcript" do
    it "returns each message with its flags" do
      t = insights.transcript("real")
      expect(t["turns"]).to eq(2)
      expect(t["messages"].first).to include("role" => "user", "guardrail_flags" => [flag])
    end

    it "is nil for an unknown session" do
      expect(insights.transcript("nope")).to be_nil
    end
  end

  describe "#list_flags" do
    it "returns the flag with the message it judged and the reply that followed" do
      expect(insights.list_flags.first).to include("session_id" => "real", "category" => "invented_policy",
                                                   "message" => "tem pix?", "reply" => "Pix com 3% de desconto.")
    end

    it "reports as reply the turn's last assistant text, not the empty tool call after the message" do
      sessions.create(id: "tool", vars: { "agent" => "shop" })
      sessions.append_messages("tool", [{ "role" => "user", "content" => "frete?", "guardrail_flags" => [flag] },
                                        { "role" => "assistant", "content" => "" },
                                        { "role" => "tool", "content" => "{\"faq\":\"...\"}" },
                                        { "role" => "assistant", "content" => "O frete sai pelo CEP no checkout." },
                                        { "role" => "user", "content" => "ok" },
                                        { "role" => "assistant", "content" => "Outro turno." }])
      tasks.create(command: { "type" => "send_message" }, session_id: "tool")
      row = insights.list_flags.find { _1["session_id"] == "tool" }
      expect(row["reply"]).to eq("O frete sai pelo CEP no checkout.")
    end

    it "filters by category" do
      expect(insights.list_flags(category: "injection")).to be_empty
    end

    it "lists a resolved flag only with include_resolved" do
      sessions.create(id: "done", vars: { "agent" => "shop" })
      resolved = flag.merge("review" => { "status" => "resolved" })
      sessions.append_messages("done", [{ "role" => "user", "content" => "x", "guardrail_flags" => [resolved] }])
      expect(insights.list_flags.map { _1["session_id"] }).not_to include("done")
      expect(insights.list_flags(include_resolved: true).map { _1["session_id"] }).to include("done")
    end

    it "opens sessions newest first only until limit, and pages with before" do
      3.times do |i|
        sessions.create(id: "f#{i}", vars: { "agent" => "shop" })
        sessions.append_messages("f#{i}", [{ "role" => "user", "content" => "m#{i}", "guardrail_flags" => [flag] }])
      end
      ages = { "real" => "2026-11-01T00:00:00Z", "f0" => "2026-11-02T00:00:00Z",
               "f1" => "2026-11-03T00:00:00Z", "f2" => "2026-11-03T00:00:00Z" }
      allow(sessions).to receive(:all_stats).and_wrap_original do |orig|
        orig.call.map { |s| ages[s.id] ? s.with(updated_at: ages[s.id]) : s }
      end
      allow(sessions).to receive(:flag_rows).and_call_original
      allow(sessions).to receive(:find).and_call_original

      page = insights.list_flags(limit: 1)
      # f1 and f2 share the newest updated_at: both go in, so the next page skips nothing
      expect(page.map { _1["session_id"] }).to contain_exactly("f1", "f2")
      expect(sessions).to have_received(:flag_rows).twice
      expect(sessions).not_to have_received(:find)

      expect(insights.list_flags(limit: 1, before: "2026-11-03T00:00:00Z").map { _1["session_id"] }).to eq(["f0"])
    end
  end

  describe "#agent_summary flagged_messages" do
    it "totals open flagged messages from stats, without opening a session" do
      allow(sessions).to receive(:find).and_call_original
      expect(insights.agent_summary.first["flagged_messages"]).to eq(1)
      expect(sessions).not_to have_received(:find)
    end
  end
end
