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
  let(:event_stream) { Insika::EventStream.new }
  subject(:command) do
    described_class.new(memory_store: memory_store, session_store: session_store,
                        tool_trace_store: tool_trace, context_trace_store: context_trace,
                        outcome_store: outcome_store, event_stream: event_stream)
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

  it "tenant is required" do
    expect { command.call(Insika::Command.build(:delete_tenant_data, {})) }
      .to raise_error(Insika::ValidationError, /tenant is required/)
  end
end
