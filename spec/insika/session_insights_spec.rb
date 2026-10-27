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

    it "filters by category" do
      expect(insights.list_flags(category: "injection")).to be_empty
    end
  end
end
