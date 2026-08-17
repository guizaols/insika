# frozen_string_literal: true

require "spec_helper"

# WS8 phase 2 (LGPD): delete_tenant_data zeroes everything the engine holds
# about ONE tenant — sessions (+traces), memory cells (tenant + customers)
# and outcomes — without touching a neighbouring tenant's data.
RSpec.describe Insika::Commands::DeleteTenantData do
  let(:backend) { Insika::Stores::Memory.new }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:tool_trace) { Insika::ToolTraceStore.new(store: backend) }
  let(:context_trace) { Insika::ContextTraceStore.new(store: backend) }
  let(:outcome_store) { Insika::OutcomeStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox_store) { Insika::OutboxStore.new(store: backend) }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  subject(:command) do
    described_class.new(memory_store: memory_store, session_store: session_store,
                        tool_trace_store: tool_trace, context_trace_store: context_trace,
                        outcome_store: outcome_store, task_store: task_store,
                        checkpoint_store: checkpoint_store, outbox_store: outbox_store,
                        event_stream: event_stream,
                        followup_store: followup_store, contact_store: contact_store)
  end

  def run(tenant:)
    command.call(Insika::Command.build(:delete_tenant_data, { tenant: tenant }))
  end

  it "purges the tenant's sessions, traces, memory cells and outcomes; the neighbour survives" do
    # tenant acme: two sessions (one with a customer + traces), memory in the
    # tenant cell and a customer cell, one outcome
    memory_store.put_fact(tenant: "acme", key: "catalogo", value: "v2")
    memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
    session_store.create(id: "acme:chat-1", vars: { "customer" => "123" })
    tool_trace.record(session_id: "acme:chat-1", entry: { tool: "x", ok: true })
    context_trace.record(session_id: "acme:chat-1", entry: { turn: [1], tokens: 10 })
    session_store.create(id: "acme:chat-2")
    outcome_store.create(tenant: "acme", agent: "bia", outcome: "conversion", value: 10)

    # tenant loja-b: untouched neighbour
    memory_store.put_fact(tenant: "loja-b", key: "catalogo", value: "v1")
    s2 = session_store.create(id: "loja-b:chat-1")
    outcome_store.create(tenant: "loja-b", agent: "bia", outcome: "deflected")

    result = run(tenant: "acme")

    expect(result[:sessions].sort).to eq(%w[acme:chat-1 acme:chat-2])
    expect(result[:memory_records]).to eq(2)
    expect(result[:outcomes]).to eq(1)
    expect(memory_store.facts(tenant: "acme")).to be_empty
    expect(memory_store.facts(tenant: "acme:123")).to be_empty
    expect(session_store.find("acme:chat-1")).to be_nil
    expect(session_store.find("acme:chat-2")).to be_nil
    expect(tool_trace.for_session("acme:chat-1")).to be_empty
    expect(context_trace.for_session("acme:chat-1")).to be_empty
    expect(outcome_store.all.size).to eq(1)

    # the neighbour is intact
    expect(memory_store.get_fact(tenant: "loja-b", key: "catalogo").value).to eq("v1")
    expect(session_store.find("loja-b:chat-1")).not_to be_nil
  end

  it "a customer cell with NO session left is still purged (scope enumeration, not session-derived)" do
    memory_store.put_fact(tenant: "acme:orphan", key: "x", value: 1)
    session_store.create(id: "acme:chat-1")

    run(tenant: "acme")

    expect(memory_store.facts(tenant: "acme:orphan")).to be_empty
  end

  # "Zera o escopo" was false for exactly the data LGPD is about: the message
  # text (task command payload), the transcript (checkpoints) and the delivered
  # answer (outbox payload) all outlived the command.
  it "purges the CONTENT of the tenant's sessions: tasks, checkpoints and outbox deliveries" do
    session_store.create(id: "acme:chat-1")
    task_store.create(command: Insika::Command.build(:send_message,
                                                     { agent: "bia", message: "meu endereço é…" }).to_h,
                      session_id: "acme:chat-1", id: "t-1")
    checkpoint_store.save(Insika::Checkpoint.new(task_id: "t-1", turn: 1, session_id: "acme:chat-1",
                                                 agent_id: "bia", messages: [], completed_side_effects: [],
                                                 created_at: nil))
    outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: "t-1",
                        session_id: "acme:chat-1", payload: { "text" => "ok!" })

    session_store.create(id: "loja-b:chat-1")
    task_store.create(command: { agent: "bia" }, session_id: "loja-b:chat-1", id: "t-b")

    result = run(tenant: "acme")

    expect(result[:tasks]).to eq(1)
    expect(result[:checkpoints]).to eq(1)
    expect(result[:deliveries]).to eq(1)
    expect(task_store.find("t-1")).to be_nil
    expect(checkpoint_store.latest("t-1")).to be_nil
    expect(outbox_store.pending).to be_empty
    expect(task_store.find("t-b")).not_to be_nil # the neighbour's, untouched
  end

  # The purge used to leave the tenant's credentials resolving: an offboarded
  # tenant kept authenticating and could open a brand-new session over the
  # erasure that had just reported success.
  describe "credentials (WS1 + WS8)" do
    let(:token_store) { Insika::TokenStore.new(store: backend) }
    subject(:command) do
      described_class.new(memory_store: memory_store, session_store: session_store,
                          outcome_store: outcome_store, task_store: task_store,
                          checkpoint_store: checkpoint_store, outbox_store: outbox_store,
                          token_store: token_store, event_stream: event_stream)
    end

    it "revokes every active token of the tenant; the neighbour's and the operator's resolve" do
      gone = token_store.issue(tenant_id: "acme", label: "prod")
      also_gone = token_store.issue(tenant_id: "acme", label: "staging")
      neighbour = token_store.issue(tenant_id: "loja-b")
      operator = token_store.issue

      result = run(tenant: "acme")

      expect(result[:tokens_revoked]).to eq(2)
      expect(token_store.resolve(gone.token)).to be_nil
      expect(token_store.resolve(also_gone.token)).to be_nil
      expect(token_store.resolve(neighbour.token).tenant_id).to eq("loja-b")
      expect(token_store.resolve(operator.token).role).to eq("operator")
    end

    it "no token store (single_tenant) -> 0, never an error" do
      expect(described_class.new(memory_store: memory_store, session_store: session_store,
                                event_stream: event_stream).call(
                                  Insika::Command.build(:delete_tenant_data, { tenant: "acme" })
                                )[:tokens_revoked]).to eq(0)
    end
  end

  # RFC-0032 C6: the tenant purge reaches the funnel's cells, cursor and
  # baseline — the funnel dies with the tenant, and the event carries the count.
  describe "funnel (RFC-0032)" do
    let(:funnel_store) { Insika::FunnelStore.new(store: backend) }
    subject(:command) do
      described_class.new(memory_store: memory_store, session_store: session_store,
                          outcome_store: outcome_store, funnel_store: funnel_store,
                          event_stream: event_stream)
    end

    it "purges the tenant's funnel cells/cursor/baseline; the neighbour's pair is untouched" do
      funnel_store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                       counts: { "greeted" => 1 })
      funnel_store.set_cursor(tenant: "acme", agent: "a", at: "2026-08-14T10:00:00Z", ids: ["x"])
      funnel_store.set_baseline(tenant: "acme", agent: "a", record: { "frozen_at" => "2026-08-15" })
      funnel_store.add(tenant: "loja-b", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                       counts: { "greeted" => 5 })

      result = run(tenant: "acme")

      expect(result[:funnel]).to eq(3)
      expect(funnel_store.day(tenant: "acme", agent: "a", day: "2026-08-14")).to eq({})
      expect(funnel_store.cursor(tenant: "acme", agent: "a")["at"]).to be_nil
      expect(funnel_store.baseline(tenant: "acme", agent: "a")).to be_nil
      expect(funnel_store.day(tenant: "loja-b", agent: "a", day: "2026-08-14")["greeted"]).to eq(5)
    end

    it "the event carries the funnel count" do
      funnel_store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                       counts: { "greeted" => 1 })
      events = SpyEventStream.new
      described_class.new(memory_store: memory_store, session_store: session_store,
                          outcome_store: outcome_store, funnel_store: funnel_store,
                          event_stream: events)
        .call(Insika::Command.build(:delete_tenant_data, { tenant: "acme" }))

      ev = events.events.find { |e| e.type == :tenant_data_deleted }
      expect(ev.data[:funnel]).to eq(1)
    end

    it "no funnel store -> 0, never an error (parity)" do
      result = described_class.new(memory_store: memory_store, session_store: session_store,
                                   event_stream: event_stream)
                              .call(Insika::Command.build(:delete_tenant_data, { tenant: "acme" }))
      expect(result[:funnel]).to eq(0)
    end
  end

  it "tenant is required" do
    expect { command.call(Insika::Command.build(:delete_tenant_data, {})) }
      .to raise_error(Insika::ValidationError, /tenant is required/)
  end

  describe "RFC-0033 C11 — the follow-up footprint dies with the tenant" do
    it "purges the tenant's follow-up records and contact cells; the neighbour survives" do
      followup_store.create(tenant: "acme", agent: "a", customer: "123", session_id: "s-1",
                            at: Time.now.utc + 3600, reason: "r1", arm: "schedule", id: "f1",
                            now: Time.now.utc)
      followup_store.create(tenant: "loja-b", agent: "a", customer: "123", session_id: "s-2",
                            at: Time.now.utc + 3600, reason: "r2", arm: "schedule", id: "f2",
                            now: Time.now.utc)
      contact_store.set_granted(tenant: "acme", customer: "123")
      contact_store.set_granted(tenant: "loja-b", customer: "123")

      result = run(tenant: "acme")

      expect(result[:followups]).to eq(1)
      expect(result[:contacts]).to eq(1)
      expect(followup_store.find("f1")).to be_nil
      expect(followup_store.find("f2")).not_to be_nil
      expect(contact_store.get(tenant: "acme", customer: "123")).to be_nil
      expect(contact_store.get(tenant: "loja-b", customer: "123")).not_to be_nil
    end

    it "no stores wired -> 0, never an error (parity)" do
      result = described_class.new(memory_store: memory_store, session_store: session_store,
                                   event_stream: event_stream)
                              .call(Insika::Command.build(:delete_tenant_data, { tenant: "acme" }))
      expect(result[:followups]).to eq(0)
      expect(result[:contacts]).to eq(0)
    end
  end
end
