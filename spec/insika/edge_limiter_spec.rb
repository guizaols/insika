# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::EdgeLimiter do
  let(:store)  { Insika::Stores::Memory.new }
  let(:ledger) { Insika::UsageLedger.new(store: store) }

  # Hand-rolled settings fake (same idiom as the other specs): only #get matters.
  def limiter(edge = nil)
    settings = edge && Class.new { def initialize(e) = (@e = e); def get = { "edge" => @e } }.new(edge)
    described_class.new(ledger: ledger, settings_store: settings)
  end

  # Minimal state: the limiter touches profile/turn_context/usage + the halt fields.
  def state(agent: "bia", chat: "chat-1", limits: {})
    prof = Insika::AgentProfile.build(id: agent, limits: limits)
    st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
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
      expect(store.list(Insika::UsageLedger::SCOPE)).to be_empty
    end

    it "an edge section full of nils (the defaults) is also off" do
      mw = limiter({ "chat_rate_limit" => nil, "agent_token_ceiling" => nil })
      expect(run(mw, state)).to be(true)
      expect(store.list(Insika::UsageLedger::SCOPE)).to be_empty
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

    it "records the cached prefix too — the ceiling sees the real spend" do
      mw = limiter({ "agent_token_ceiling" => 1_000_000, "agent_token_window" => 3_600 })
      # The measured pilot shape: total_tokens 88 with a 26_624-token cached prefix.
      run(mw, state, usage: { total_tokens: 88, input_tokens: 60, output_tokens: 28,
                              cached_tokens: 26_624 })
      expect(ledger.count("tokens", "bia", window: 3_600)).to eq(26_712)
    end

    it "records cache-creation (write) tokens as spend as well" do
      mw = limiter({ "agent_token_ceiling" => 1_000_000, "agent_token_window" => 3_600 })
      run(mw, state, usage: { total_tokens: 100, cached_tokens: 200, cache_creation_tokens: 300 })
      expect(ledger.count("tokens", "bia", window: 3_600)).to eq(600)
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
      keys = store.list(Insika::UsageLedger::SCOPE)
      expect(keys).to all(start_with("chat:"))
    end
  end

  describe "resumed turns (crash/pause recovery)" do
    it "skips the entry checks (an admitted turn is never swallowed by the wall)" do
      mw = limiter({ "chat_rate_limit" => 1 })
      run(mw, state) # saturates the chat window
      st = state
      st.resumed = true
      expect(run(mw, st)).to be(true) # would be blocked if it counted again
    end

    it "never blocks a resume on the token ceiling, but still records its usage" do
      mw = limiter({ "agent_token_ceiling" => 100, "agent_token_window" => 3_600 })
      run(mw, state, usage: { total_tokens: 200 }) # ledger now over the ceiling
      st = state
      st.resumed = true
      expect(run(mw, st, usage: { total_tokens: 50 })).to be(true)
      expect(ledger.count("tokens", "bia", window: 3_600)).to eq(250)
    end
  end

  describe "scheduled turns (RFC-0033 D5-bis)" do
    def scheduled_state
      task = Struct.new(:id, :session_id, :command)
             .new("t", "s", { "type" => "scheduled_followup", "payload" => {} })
      prof = Insika::AgentProfile.build(id: "bia")
      st = Insika::TurnState.new(task: task, profile: prof, turn: 1, message: "oi")
      st.turn_context = { chat_id: "chat-1", agent_id: "bia", tenant: nil, store_id: nil }
      st
    end

    it "skips the ENTRY checks exactly like a resume (a follow-up never gets the rate-limit reply)" do
      mw = limiter({ "chat_rate_limit" => 1 })
      run(mw, state) # saturates the window for chat-1
      expect(run(mw, scheduled_state)).to be(true) # would be blocked if it counted again
    end

    it "skips the token-ceiling entry check but its usage still lands on the ledger" do
      mw = limiter({ "agent_token_ceiling" => 100, "agent_token_window" => 3_600 })
      run(mw, state, usage: { total_tokens: 200 }) # ledger over the ceiling
      expect(run(mw, scheduled_state, usage: { total_tokens: 50 })).to be(true)
      expect(ledger.count("tokens", "bia", window: 3_600)).to eq(250)
    end

    it "a NORMAL task is unchanged (the skip is keyed on the command type)" do
      mw = limiter({ "chat_rate_limit" => 1 })
      run(mw, state)
      expect(run(mw, state)).to be(false) # second normal turn blocked
    end
  end

  describe "per-agent limits without any settings store (base wiring)" do
    it "enforces the profile's own limits" do
      mw = limiter(nil)
      run(mw, state(limits: { chat_rate_limit: 1 }))
      expect(run(mw, state(limits: { chat_rate_limit: 1 }))).to be(false)
    end
  end

  describe "WS2 calendar budgets" do
    def budget_mw(budget_ledger)
      described_class.new(ledger: ledger, budget_ledger: budget_ledger, event_stream: nil)
    end

    it "a turn that FAILS after burning tokens still counts against the budget (WS2)" do
      budget_ledger = Insika::BudgetLedger.new(store: Insika::Stores::Memory.new)
      prof = Insika::AgentProfile.build(id: "bia", budget: { "daily" => 10_000 })
      st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
      st.turn_context = { chat_id: "chat-1", agent_id: "bia", tenant: nil, store_id: nil }

      # the ask consumed tokens, then a LATER stage failed the turn
      expect do
        budget_mw(budget_ledger).call(st) do |s|
          s.usage = { total_tokens: 400, cached_tokens: 100 }
          raise Insika::Error, "tool crashed after the ask"
        end
      end.to raise_error(Insika::Error)

      expect(budget_ledger.current(tenant: nil, agent: "bia")).to eq(daily: 500, monthly: 500)
    end

    it "the soft CAP crossing still warns when the alert_at marker already fired" do
      budget_ledger = Insika::BudgetLedger.new(store: Insika::Stores::Memory.new)
      mw = budget_mw(budget_ledger)
      prof = Insika::AgentProfile.build(id: "bia", budget: { "daily" => 1_000, "soft" => true })
      st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
      st.turn_context = { chat_id: "chat-1", agent_id: "bia", tenant: nil, store_id: nil }

      # simulate a spent cell at the alert_at crossing, then at/over the cap
      expect { mw.call(st) { nil } }.not_to raise_error
      expect(budget_ledger.mark_alert(tenant: nil, agent: "bia", window: :daily,
                                      level: "alert_at")).to be(false)
      budget_ledger.add(tenant: nil, agent: "bia", by: 1_000)
      expect { mw.call(st) { nil } }.not_to raise_error
      expect(budget_ledger.alerted?(tenant: nil, agent: "bia", window: :daily,
                                    level: "cap")).to be(true) # warned "cap" despite the alert_at marker
    end
  end
end
