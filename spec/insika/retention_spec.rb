# frozen_string_literal: true

require "spec_helper"
require "time"

# WS8 (phase 2): retention — the age-based sweep of the conversation
# footprint. The knob is data (`settings.retention_days`; nil/0 = OFF —
# parity). The sweep runs at most once per day (the internal claim), touches
# ONLY what is older than the cutoff, and never a non-terminal task.
RSpec.describe Insika::Retention do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:outcome_store) { Insika::OutcomeStore.new(store: backend) }
  let(:tool_trace) { Insika::ToolTraceStore.new(store: backend) }
  let(:context_trace) { Insika::ContextTraceStore.new(store: backend) }
  let(:outbox_store) { Insika::OutboxStore.new(store: backend) }
  let(:settings) { Struct.new(:get).new({ "retention_days" => days, "memory_ttl_days" => ttl_days }) }
  let(:days) { 30 }
  let(:ttl_days) { nil }
  let(:now) { Time.utc(2026, 8, 13, 12, 0, 0) }

  subject(:retention) do
    described_class.new(
      store: backend, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, memory_store: memory_store,
      outcome_store: outcome_store, tool_trace_store: tool_trace,
      context_trace_store: context_trace, outbox_store: outbox_store,
      settings_store: settings, now: now
    )
  end
  def backdate_delivery(id, iso)
    record = backend.get("outbox", "outbox:#{id}").merge("created_at" => iso)
    backend.set("outbox", "outbox:#{id}", record)
  end

  def backdate_session(id, iso)
    record = session_store.find(id).to_h.merge("updated_at" => iso)
    backend.set("sessions", "session:#{id}", record)
  end

  def backdate_fact(tenant, key, iso)
    record = memory_store.get_fact(tenant: tenant, key: key).to_h.merge("updated_at" => iso)
    backend.set("memory:#{tenant}", "fact:#{key}", record)
  end

  def backdate_task(id, iso)
    record = task_store.find(id).to_h.merge("updated_at" => iso)
    backend.set("tasks", "task:#{id}", record)
  end

  it "nil/0 retention_days -> OFF (claimed: false, nothing touched)" do
    settings.get["retention_days"] = nil
    session_store.create(id: "chat-1")
    session_store.create(id: "chat-2")

    expect(retention.run).to eq({ claimed: false })
    expect(session_store.find("chat-1")).not_to be_nil
  end

  it "sweeps sessions older than the cutoff (+ their traces), keeps the fresh ones" do
    old = session_store.create(id: "chat-old")
    fresh = session_store.create(id: "chat-fresh")
    backdate_session("chat-old", (now - 40 * 86_400).iso8601)
    tool_trace.record(session_id: "chat-old", entry: { tool: "x", ok: true })
    context_trace.record(session_id: "chat-old", entry: { turn: [1], tokens: 10 })

    summary = retention.run

    expect(summary[:claimed]).to be(true)
    expect(summary[:sessions]).to eq(1)
    expect(session_store.find("chat-old")).to be_nil
    expect(tool_trace.for_session("chat-old")).to be_empty
    expect(session_store.find("chat-fresh")).not_to be_nil
  end

  it "sweeps TERMINAL tasks older than the cutoff (+ checkpoints), never a live one" do
    task_store.create(command: { agent: "a" }, session_id: "s1", id: "t-old",
                      at: (now - 40 * 86_400).iso8601)
    task_store.transition("t-old", to: :running)
    task_store.transition("t-old", to: :completed)
    backdate_task("t-old", (now - 40 * 86_400).iso8601)
    checkpoint_store.save(Insika::Checkpoint.new(task_id: "t-old", turn: 1, session_id: "s1",
                                                 agent_id: "a", messages: [],
                                                 completed_side_effects: [], created_at: nil))
    task_store.create(command: { agent: "a" }, session_id: "s2", id: "t-run",
                      at: (now - 40 * 86_400).iso8601)
    task_store.transition("t-run", to: :running)
    backdate_task("t-run", (now - 40 * 86_400).iso8601)

    summary = retention.run

    expect(summary[:tasks]).to eq(1)
    expect(task_store.find("t-old")).to be_nil
    expect(checkpoint_store.find("t-old", turn: 1)).to be_nil
    expect(task_store.find("t-run")).not_to be_nil
  end

  it "sweeps outcomes and memory cells older than the cutoff" do
    outcome_store.create(tenant: "acme", agent: "bia", outcome: "conversion",
                         at: now - 40 * 86_400)
    outcome_store.create(tenant: "acme", agent: "bia", outcome: "deflected", at: now)
    memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
    memory_store.put_fact(tenant: "acme:123", key: "prefer", value: "email")
    backdate_fact("acme:123", "pedido", (now - 40 * 86_400).iso8601)

    summary = retention.run

    expect(summary[:outcomes]).to eq(1)
    expect(summary[:memory]).to eq(1)
    expect(outcome_store.all.size).to eq(1)
    expect(memory_store.get_fact(tenant: "acme:123", key: "pedido")).to be_nil
    expect(memory_store.get_fact(tenant: "acme:123", key: "prefer")).not_to be_nil
  end

  # The delivery's payload IS the answer the customer got — conversation
  # content, which used to live in the store forever because nothing swept it.
  it "sweeps DELIVERED/FAILED outbox records older than the cutoff, never a pending one" do
    old = outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: "t-1",
                              session_id: "s1", payload: { "text" => "chega amanhã" })
    outbox_store.claim(old.id)
    outbox_store.mark_delivered(old.id)
    backdate_delivery(old.id, (now - 40 * 86_400).iso8601)

    stuck = outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: "t-2",
                                session_id: "s2", payload: { "text" => "ainda não entregue" })
    backdate_delivery(stuck.id, (now - 40 * 86_400).iso8601)

    fresh = outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: "t-3",
                                session_id: "s3", payload: { "text" => "de hoje" })
    outbox_store.claim(fresh.id)
    outbox_store.mark_delivered(fresh.id)

    summary = retention.run

    expect(summary[:deliveries]).to eq(1)
    expect(outbox_store.find(old.id)).to be_nil
    expect(outbox_store.find(stuck.id)).not_to be_nil # still owed to somebody
    expect(outbox_store.find(fresh.id)).not_to be_nil
  end

  # WS2 counter GC: those cells are engine bookkeeping whose window already
  # rolled over, not customer content — so they are swept even with retention
  # OFF (the default), which is exactly where they used to leak forever.
  # RFC-0032 C6: the funnel cells are swept with the outcomes they fold —
  # same retention_days gate, same daily claim. The fold dies with its source.
  describe "funnel sweep (RFC-0032)" do
    let(:funnel_store) { Insika::FunnelStore.new(store: backend) }
    subject(:retention) do
      described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, outbox_store: outbox_store,
        settings_store: settings, funnel_store: funnel_store, now: now
      )
    end

    it "sweeps day cells older than the cutoff, keeps newer, cursor/baseline survive" do
      funnel_store.add(tenant: "acme", agent: "a", at: now - 40 * 86_400,
                       counts: { "greeted" => 1 })
      funnel_store.add(tenant: "acme", agent: "a", at: now - 2 * 86_400,
                       counts: { "greeted" => 1 })
      funnel_store.set_cursor(tenant: "acme", agent: "a", at: "2026-01-01T00:00:00Z", ids: ["old"])
      funnel_store.set_baseline(tenant: "acme", agent: "a", record: { "frozen_at" => "2026-01-01" })

      summary = retention.run

      expect(summary[:claimed]).to be(true)
      expect(summary[:funnel]).to eq(1)
      expect(funnel_store.day(tenant: "acme", agent: "a", day: (now - 40 * 86_400).strftime("%Y-%m-%d")))
        .to eq({})
      expect(funnel_store.day(tenant: "acme", agent: "a", day: (now - 2 * 86_400).strftime("%Y-%m-%d"))["greeted"])
        .to eq(1)
      expect(funnel_store.cursor(tenant: "acme", agent: "a")["at"]).to eq("2026-01-01T00:00:00Z")
      expect(funnel_store.baseline(tenant: "acme", agent: "a")).to eq("frozen_at" => "2026-01-01")
    end

    it "with retention_days OFF nothing is swept (funnel untouched, claimed false)" do
      settings.get["retention_days"] = nil
      funnel_store.add(tenant: "acme", agent: "a", at: now - 40 * 86_400,
                       counts: { "greeted" => 1 })

      expect(retention.run).to eq({ claimed: false })
      expect(funnel_store.day(tenant: "acme", agent: "a",
                              day: (now - 40 * 86_400).strftime("%Y-%m-%d"))["greeted"]).to eq(1)
    end

    it "nil funnel_store -> the summary key is absent (parity)" do
      settings.get["retention_days"] = nil
      summary = described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, settings_store: settings, now: now
      ).run
      expect(summary).to eq({ claimed: false })
    end
  end

  describe "budget counter GC" do
    let(:budget_ledger) { Insika::BudgetLedger.new(store: backend) }
    subject(:retention) do
      described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, outbox_store: outbox_store,
        settings_store: settings, budget_ledger: budget_ledger, now: now
      )
    end

    def stale_cells
      budget_ledger.add(tenant: "loja-42", agent: "bia", by: 100, now: now - (3 * 86_400))
      budget_ledger.mark_alert(tenant: "loja-42", agent: "bia", window: :daily,
                               level: "cap", now: now - (3 * 86_400))
    end

    it "sweeps the expired cells even with retention_days OFF" do
      settings.get["retention_days"] = nil
      stale_cells
      session_store.create(id: "chat-1")

      expect(retention.run).to eq({ claimed: false, budget_cells: 2 })
      expect(session_store.find("chat-1")).not_to be_nil # retention is still OFF
      expect(backend.list(Insika::BudgetLedger::ALERT_SCOPE)).to be_empty
    end

    it "rides the age-based summary when retention IS on, on its own daily claim" do
      stale_cells

      expect(retention.run).to include(claimed: true, budget_cells: 2)
      # second pass inside the window: neither sweep runs again
      expect(retention.run).to eq({ claimed: false })
    end

    it "no ledger wired -> the summary is byte-identical to before (parity)" do
      settings.get["retention_days"] = nil
      expect(described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, settings_store: settings, now: now
      ).run).to eq({ claimed: false })
    end
  end

  it "the daily claim: a second run inside the window sweeps nothing" do
    session_store.create(id: "chat-old")
    backdate_session("chat-old", (now - 40 * 86_400).iso8601)

    expect(retention.run[:claimed]).to be(true)
    expect(retention.run).to eq({ claimed: false })
    expect(session_store.find("chat-old")).to be_nil # swept by the FIRST run only
  end

  describe "memory TTL sweep (RFC-0031, E4)" do
    # E4: a fact with an explicit expires_at in the past is GONE after `run` —
    # on its own daily claim, NOT gated by retention_days.
    it "expires_at in the past -> gone after run, counted in memory_ttl:" do
      settings.get["retention_days"] = nil # the memory TTL is the only sweep here
      settings.get["memory_ttl_days"] = 10
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "deadline", value: "x",
                                      expires_at: (now - 1 * 86_400).iso8601)
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "keep", value: "y",
                                      expires_at: (now + 5 * 86_400).iso8601)

      summary = retention.run

      expect(summary[:claimed]).to be(false)
      expect(summary[:memory_ttl]).to eq(1)
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "deadline")).to be_nil
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "keep")).not_to be_nil
    end

    it "Integer TTL prunes a cell by updated_at; an explicit later expires_at survives" do
      settings.get["memory_ttl_days"] = 30
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "old", value: "1")
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "pinned", value: "2",
                                      expires_at: (now + 365 * 86_400).iso8601)
      # age both past the cutoff
      retention.memory_store.instance_variable_get(:@store).set("memory:acme:c-1", "fact:old",
        { "key" => "old", "value" => "1", "origin" => "engine",
          "created_at" => (now - 60 * 86_400).iso8601(6), "updated_at" => (now - 60 * 86_400).iso8601(6),
          "expires_at" => nil })
      retention.memory_store.instance_variable_get(:@store).set("memory:acme:c-1", "fact:pinned",
        { "key" => "pinned", "value" => "2", "origin" => "engine",
          "created_at" => (now - 60 * 86_400).iso8601(6), "updated_at" => (now - 60 * 86_400).iso8601(6),
          "expires_at" => (now + 365 * 86_400).iso8601 })

      summary = retention.run

      expect(summary[:memory_ttl]).to eq(1)
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "old")).to be_nil
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "pinned")).not_to be_nil
    end

    it "Hash TTL: per-tenant cell uses its tenant's days, an absent tenant falls back to '*'" do
      settings.get["memory_ttl_days"] = { "acme" => 10, "*" => 30 }
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "a", value: "1")
      retention.memory_store.put_fact(tenant: "globex:c-1", key: "b", value: "2")
      # age acme past ITS 10d, globex past the '*' 30d
      [["memory:acme:c-1", "fact:a", 20], ["memory:globex:c-1", "fact:b", 40]].each do |sc, k, days_ago|
        rec = retention.memory_store.instance_variable_get(:@store).get(sc, k)
        retention.memory_store.instance_variable_get(:@store).set(sc, k,
          rec.merge("updated_at" => (now - days_ago * 86_400).iso8601(6)))
      end

      summary = retention.run

      expect(summary[:memory_ttl]).to eq(2)
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "a")).to be_nil # tenant's 10d
      expect(retention.memory_store.get_fact(tenant: "globex:c-1", key: "b")).to be_nil # '*' 30d
    end

    it "Hash TTL: a cell with no resolution (no '*') is untouched" do
      settings.get["retention_days"] = nil # only the memory TTL sweep runs
      settings.get["memory_ttl_days"] = { "acme" => 10 }
      retention.memory_store.put_fact(tenant: "solo", key: "c", value: "3")
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "a", value: "1")
      [["memory:solo", "fact:c", 40], ["memory:acme:c-1", "fact:a", 20]].each do |sc, k, days_ago|
        rec = retention.memory_store.instance_variable_get(:@store).get(sc, k)
        retention.memory_store.instance_variable_get(:@store).set(sc, k,
          rec.merge("updated_at" => (now - days_ago * 86_400).iso8601(6)))
      end

      summary = retention.run

      expect(summary[:memory_ttl]).to eq(1)
      expect(retention.memory_store.get_fact(tenant: "acme:c-1", key: "a")).to be_nil
      expect(retention.memory_store.get_fact(tenant: "solo", key: "c")).not_to be_nil # no resolution
    end

    it "runs with retention_days nil/0 (its own knob, not gated); a second run the same day does not claim" do
      settings.get["retention_days"] = nil
      settings.get["memory_ttl_days"] = 10
      retention.memory_store.put_fact(tenant: "acme:c-1", key: "old", value: "1")
      retention.memory_store.instance_variable_get(:@store).set("memory:acme:c-1", "fact:old",
        { "key" => "old", "value" => "1", "origin" => "engine",
          "created_at" => (now - 60 * 86_400).iso8601(6), "updated_at" => (now - 60 * 86_400).iso8601(6),
          "expires_at" => nil })

      first = retention.run
      expect(first[:claimed]).to be(false)
      expect(first[:memory_ttl]).to eq(1)
      # the age-based sweep did NOT run (retention_days off): a session survives
      session_store.create(id: "chat-1")

      second = retention.run
      expect(second[:memory_ttl]).to be_nil # claim held for the day
      expect(session_store.find("chat-1")).not_to be_nil
    end

    it "no settings_store / nil setting -> nothing, byte-identical to today" do
      memory_store.put_fact(tenant: "acme:c-1", key: "k", value: "v")
      expect(described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, now: now
      ).run).to eq({ claimed: false })
    end
  end

  # RFC-0033 C11: the follow-up footprint dies with the rest — schedule records
  # and contact cells under the SAME retention_days gate + daily claim.
  describe "follow-up sweep (RFC-0033)" do
    let(:followup_store) { Insika::FollowupStore.new(store: backend) }
    let(:contact_store) { Insika::ContactStore.new(store: backend) }
    subject(:retention) do
      described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, outbox_store: outbox_store,
        settings_store: settings, followup_store: followup_store,
        contact_store: contact_store, now: now
      )
    end

    # Follow-up `create` refuses a past `at` (the tool's rule); a record that
    # has ALREADY passed its scheduled time exists only via the direct path
    # (a deferred-then-stale record, or a legacy write) — seeded through the
    # backend like the cron arm writes.
    def seed!(id:, at:, reason:, status: "pending", task_id: nil, updated_at: nil)
      backend.set("followups", "acme:a:c-1:#{at.iso8601}:#{id}",
                  { "id" => id, "tenant" => "acme", "agent" => "a", "customer" => "c-1",
                    "session_id" => "s-1", "at" => at.iso8601, "reason" => reason,
                    "arm" => "schedule", "status" => status, "task_id" => task_id,
                    "blocked_reason" => nil, "transport" => "channel:whatsapp",
                    "created_at" => now.iso8601, "updated_at" => (updated_at || now).iso8601 })
    end

    def book!(id:, at: nil, reason: "r")
      followup_store.create(tenant: "acme", agent: "a", customer: "c-1", session_id: "s-1",
                            at: at || now + 3600, reason: reason, arm: "schedule", id: id,
                            now: now)
    end

    it "sweeps terminal records + old contact cells; a future pending survives; a zombie pending dies" do
      seed!(id: "old-fired", at: now - 60, reason: "r1", status: "fired", task_id: "t-1",
            updated_at: now - 40 * 86_400)
      # a ZOMBIE: still pending, its scheduled time long past (deferred past the
      # point of no return — retention ages it out rather than firing late)
      seed!(id: "zombie", at: now - 40 * 86_400, reason: "r2")
      book!(id: "future", at: now + 400 * 86_400, reason: "r3") # pending, well out
      contact_store.set_granted(tenant: "acme", customer: "old", now: now - 60 * 86_400)
      contact_store.set_granted(tenant: "acme", customer: "new", now: now - 60)

      summary = retention.run

      expect(summary[:claimed]).to be(true)
      expect(summary[:followups]).to eq(2)
      expect(followup_store.find("old-fired")).to be_nil
      expect(followup_store.find("zombie")).to be_nil
      expect(followup_store.find("future")).not_to be_nil
      expect(summary[:contacts]).to eq(1)
      expect(contact_store.get(tenant: "acme", customer: "old")).to be_nil
      expect(contact_store.get(tenant: "acme", customer: "new")).not_to be_nil
    end

    it "with retention_days OFF nothing is swept" do
      settings.get["retention_days"] = nil
      seed!(id: "keep", at: now - 60, reason: "r")
      contact_store.set_granted(tenant: "acme", customer: "c-1", now: now - 60 * 86_400)

      expect(retention.run).to eq({ claimed: false })
      expect(followup_store.find("keep")).not_to be_nil
      expect(contact_store.get(tenant: "acme", customer: "c-1")).not_to be_nil
    end

    it "RFC-0034 C8 — proposals older than the cutoff are swept (pending included); a recent one survives" do
      proposal_store = Insika::ProposalStore.new(store: backend)
      r = described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, tool_trace_store: tool_trace,
        context_trace_store: context_trace, outbox_store: outbox_store,
        settings_store: settings, now: now, proposal_store: proposal_store
      )
      proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "acme:s-old",
                            key: "size", value: "M", id: "old",
                            now: now - 40 * 86_400)
      proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "acme:s-old",
                            key: "budget", value: "100", id: "old-term",
                            now: now - 40 * 86_400)
      proposal_store.dismiss(id: "old-term", now: now - 40 * 86_400)
      proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "acme:s-new",
                            key: "size", value: "L", id: "fresh", now: now)

      summary = r.run

      expect(summary[:claimed]).to be(true)
      expect(summary[:proposals]).to eq(2)
      expect(proposal_store.find("old")).to be_nil      # a zombie pending ages out
      expect(proposal_store.find("old-term")).to be_nil  # terminal ages out
      expect(proposal_store.find("fresh")).not_to be_nil
    end

    it "RFC-0034 C8 — with retention_days OFF proposals are untouched" do
      proposal_store = Insika::ProposalStore.new(store: backend)
      r = described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, tool_trace_store: tool_trace,
        context_trace_store: context_trace, outbox_store: outbox_store,
        settings_store: settings, now: now, proposal_store: proposal_store
      )
      settings.get["retention_days"] = nil
      proposal_store.create(tenant: "acme", customer: "c-1", session_ref: "acme:s-old",
                            key: "size", value: "M", id: "keep", now: now - 400 * 86_400)

      expect(r.run).to eq({ claimed: false })
      expect(proposal_store.find("keep")).not_to be_nil
    end

    it "nil collaborators -> the summary keys are absent (base graph parity)" do
      settings.get["retention_days"] = 30
      summary = described_class.new(
        store: backend, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, memory_store: memory_store,
        outcome_store: outcome_store, settings_store: settings, now: now
      ).run
      expect(summary).not_to have_key(:followups)
      expect(summary).not_to have_key(:contacts)
    end
  end
end
