# frozen_string_literal: true

require "spec_helper"

# WS8 phase 2 (LGPD): forget_customer zeroes everything the engine holds about
# one customer — memory cell, sessions, per-session traces — without touching
# the tenant's other customers.
RSpec.describe Insika::Commands::ForgetCustomer do
  let(:backend) { Insika::Stores::Memory.new }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:tool_trace) { Insika::ToolTraceStore.new(store: backend) }
  let(:context_trace) { Insika::ContextTraceStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  subject(:command) do
    described_class.new(memory_store: memory_store, session_store: session_store,
                        tool_trace_store: tool_trace, context_trace_store: context_trace,
                        event_stream: event_stream)
  end

  def run(customer:, tenant: nil)
    command.call(Insika::Command.build(:forget_customer, { customer: customer }, tenant: tenant))
  end

  it "purges the customer's memory, sessions and traces; the other customer survives" do
    # customer 123: memory + a stamped session with traces
    memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
    memory_store.add_note(tenant: "acme:123", text: "prefere email")
    session_store.create(id: "acme:chat-1", vars: { "customer" => "123" })
    tool_trace.record(session_id: "acme:chat-1", entry: { tool: "x", ok: true })
    context_trace.record(session_id: "acme:chat-1", entry: { turn: [1], tokens: 10 })

    # customer 456: untouched neighbour
    memory_store.put_fact(tenant: "acme:456", key: "pedido", value: "delivered")
    s2 = session_store.create(id: "acme:chat-2", vars: { "customer" => "456" })

    result = run(customer: "123", tenant: "acme")

    expect(result[:memory_records]).to eq(2)
    expect(result[:sessions]).to eq(["acme:chat-1"])
    expect(memory_store.facts(tenant: "acme:123")).to be_empty
    expect(memory_store.notes(tenant: "acme:123")).to be_empty
    expect(session_store.find("acme:chat-1")).to be_nil
    expect(tool_trace.for_session("acme:chat-1")).to be_empty
    expect(context_trace.for_session("acme:chat-1")).to be_empty

    # the neighbour is intact
    expect(memory_store.get_fact(tenant: "acme:456", key: "pedido").value).to eq("delivered")
    expect(session_store.find("acme:chat-2")).not_to be_nil
  end

  it "in a specific tenant, only that tenant's sessions of the customer go" do
    a = session_store.create(id: "loja-a:chat-1", vars: { "customer" => "123" })
    b = session_store.create(id: "loja-b:chat-1", vars: { "customer" => "123" })

    result = run(customer: "123", tenant: "loja-a")

    expect(result[:sessions]).to eq(["loja-a:chat-1"])
    expect(session_store.find("loja-b:chat-1")).not_to be_nil
  end

  it "customer is required; an unknown customer is a clean no-op" do
    expect { run(customer: nil) }.to raise_error(Insika::ValidationError, /customer is required/)
    expect { run(customer: "ghost") }.not_to raise_error
  end
end