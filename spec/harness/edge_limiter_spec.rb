# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::EdgeLimiter do
  let(:store)  { Harness::Stores::Memory.new }
  let(:ledger) { Harness::UsageLedger.new(store: store) }

  # Hand-rolled settings fake (same idiom as the other specs): only #get matters.
  def limiter(edge = nil)
    settings = edge && Class.new { def initialize(e) = (@e = e); def get = { "edge" => @e } }.new(edge)
    described_class.new(ledger: ledger, settings_store: settings)
  end

  # Minimal state: the limiter touches profile/turn_context/usage + the halt fields.
  def state(agent: "bia", chat: "chat-1", limits: {})
    prof = Harness::AgentProfile.build(id: agent, limits: limits)
    st = Harness::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
    st.turn_context = { chat_id: chat, agent_id: agent, tenant: chat, store_id: nil }
    st
  end

  def run(mw, st, usage: nil)
    called = false
    mw.call(st) do |s|
      called = true
      s.usage = usage if usage
    end
    called
  end

  describe "parity (nothing configured)" do
    it "passes through and writes NOTHING to the store" do
      st = state
      expect(run(limiter, st)).to be(true)
      expect(st.halt_response).to be_nil
      expect(store.list(Harness::UsageLedger::SCOPE)).to be_empty
    end

    it "an edge section full of nils (the defaults) is also off" do
      mw = limiter({ "chat_rate_limit" => nil, "agent_token_ceiling" => nil })
      expect(run(mw, state)).to be(true)
      expect(store.list(Harness::UsageLedger::SCOPE)).to be_empty
    end
  end

  describe "chat rate limit" do
    it "blocks the attempt PAST the limit with a graceful halt (no LLM)" do
      mw = limiter({ "chat_rate_limit" => 2, "chat_rate_window" => 60 })
      expect(run(mw, state)).to be(true)
      expect(run(mw, state)).to be(true)

      st = state
      expect(run(mw, st)).to be(false) # 3rd attempt: nxt NOT called
      expect(st.halt_response).to eq(described_class::DEFAULT_RESPONSE)
      expect(st.guardrail_block).to include(category: "rate_limit", source: "edge", action: "refuse")
      expect(st.guardrail_block[:detail]).to include("chat-1")
    end

    it "keeps counting blocked attempts (a flood stays at the wall)" do
      mw = limiter({ "chat_rate_limit" => 1 })
      run(mw, state)
      expect(run(mw, state)).to be(false)
      expect(run(mw, state)).to be(false)
    end

    it "chats are independent buckets" do
      mw = limiter({ "chat_rate_limit" => 1 })
      expect(run(mw, state(chat: "a"))).to be(true)
      expect(run(mw, state(chat: "b"))).to be(true)
    end

    it "skips the check for a blank chat id (never lumps anonymous traffic)" do
      mw = limiter({ "chat_rate_limit" => 1 })
      2.times { expect(run(mw, state(chat: nil))).to be(true) }
    end

    it "uses the settings' limit_response when configured" do
      mw = limiter({ "chat_rate_limit" => 1, "limit_response" => "Calma lá, parceiro." })
      run(mw, state)
      st = state
      run(mw, st)
      expect(st.halt_response).to eq("Calma lá, parceiro.")
    end

    it "per-agent chat_rate_limit overrides the platform value" do
      mw = limiter({ "chat_rate_limit" => 100 })
      run(mw, state(limits: { chat_rate_limit: 1 }))
      expect(run(mw, state(limits: { chat_rate_limit: 1 }))).to be(false)
    end

    it "per-agent 0 disables a platform limit for that agent" do
      mw = limiter({ "chat_rate_limit" => 1 })
      3.times { expect(run(mw, state(limits: { chat_rate_limit: 0 }))).to be(true) }
    end
  end

  describe "agent token ceiling" do
    it "records the turn's usage on the agent ledger AFTER the terminal" do
      mw = limiter({ "agent_token_ceiling" => 1_000, "agent_token_window" => 3_600 })
      run(mw, state, usage: { total_tokens: 400, input_tokens: 300, output_tokens: 100 })
      expect(ledger.count("tokens", "bia", window: 3_600)).to eq(400)
    end

    it "blocks the turn once the accumulated spend reaches the ceiling" do
      mw = limiter({ "agent_token_ceiling" => 500, "agent_token_window" => 3_600 })
      expect(run(mw, state, usage: { total_tokens: 600 })).to be(true) # 1st passes, records 600

      st = state
      expect(run(mw, st)).to be(false) # over the ceiling now: blocked before the LLM
      expect(st.guardrail_block).to include(category: "token_ceiling", source: "edge")
      expect(st.guardrail_block[:detail]).to include("600/500")
    end

    it "ceilings are per agent (one agent's spend never blocks another)" do
      mw = limiter({ "agent_token_ceiling" => 500 })
      run(mw, state(agent: "bia"), usage: { total_tokens: 600 })
      expect(run(mw, state(agent: "outra", chat: "chat-2"))).to be(true)
    end

    it "per-agent agent_token_ceiling overrides the platform value" do
      mw = limiter({ "agent_token_ceiling" => 1_000_000 })
      run(mw, state(limits: { agent_token_ceiling: 100 }), usage: { total_tokens: 150 })
      expect(run(mw, state(limits: { agent_token_ceiling: 100 }))).to be(false)
    end

    it "a nil usage (workflow turn / provider without counts) records nothing" do
      mw = limiter({ "agent_token_ceiling" => 500 })
      run(mw, state)
      expect(ledger.count("tokens", "bia", window: described_class::DEFAULT_TOKEN_WINDOW)).to eq(0)
    end

    it "a rate-limit-only config never writes token counters" do
      mw = limiter({ "chat_rate_limit" => 10 })
      run(mw, state, usage: { total_tokens: 400 })
      keys = store.list(Harness::UsageLedger::SCOPE)
      expect(keys).to all(start_with("chat:"))
    end
  end

  describe "per-agent limits without any settings store (base wiring)" do
    it "enforces the profile's own limits" do
      mw = limiter(nil)
      run(mw, state(limits: { chat_rate_limit: 1 }))
      expect(run(mw, state(limits: { chat_rate_limit: 1 }))).to be(false)
    end
  end
end
