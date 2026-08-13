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
  let(:settings) { Struct.new(:get).new({ "retention_days" => days }) }
  let(:days) { 30 }
  let(:now) { Time.utc(2026, 8, 13, 12, 0, 0) }

  subject(:retention) do
    described_class.new(
      store: backend, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, memory_store: memory_store,
      outcome_store: outcome_store, tool_trace_store: tool_trace,
      context_trace_store: context_trace, settings_store: settings, now: now
    )
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

  it "the daily claim: a second run inside the window sweeps nothing" do
    session_store.create(id: "chat-old")
    backdate_session("chat-old", (now - 40 * 86_400).iso8601)

    expect(retention.run[:claimed]).to be(true)
    expect(retention.run).to eq({ claimed: false })
    expect(session_store.find("chat-old")).to be_nil # swept by the FIRST run only
  end
end
