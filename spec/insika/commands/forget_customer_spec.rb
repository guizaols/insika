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
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox_store) { Insika::OutboxStore.new(store: backend) }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:proposal_store) { Insika::ProposalStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  subject(:command) do
    described_class.new(memory_store: memory_store, session_store: session_store,
                        tool_trace_store: tool_trace, context_trace_store: context_trace,
                        task_store: task_store, checkpoint_store: checkpoint_store,
                        outbox_store: outbox_store, event_stream: event_stream,
                        followup_store: followup_store, contact_store: contact_store,
                        proposal_store: proposal_store)
  end

  def run(customer:, tenant: nil, payload_tenant: nil)
    payload = { customer: customer }
    payload[:tenant] = payload_tenant if payload_tenant
    command.call(Insika::Command.build(:forget_customer, payload, tenant: tenant))
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

  # The transport (POST /v1/commands/forget_customer) is operator-grade, and an
  # operator principal carries NO tenant — so without a payload tenant the purge
  # zeroed "memory:<customer>" (a cell nobody writes) and deleted that customer's
  # sessions in EVERY tenant. Both halves of that are wrong; the tenant is named
  # in the payload.
  it "the tenant may come from the PAYLOAD (the operator naming it over HTTP)" do
    memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
    session_store.create(id: "acme:chat-1", vars: { "customer" => "123" })
    session_store.create(id: "loja-b:chat-1", vars: { "customer" => "123" })

    result = run(customer: "123", payload_tenant: "acme")

    expect(result[:tenant]).to eq("acme")
    expect(result[:memory_records]).to eq(1)
    expect(memory_store.facts(tenant: "acme:123")).to be_empty
    expect(session_store.find("acme:chat-1")).to be_nil
    expect(session_store.find("loja-b:chat-1")).not_to be_nil # another tenant's, untouched
  end

  it "the command meta's tenant WINS over the payload's (an internal caller acting as a tenant)" do
    memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")

    result = run(customer: "123", tenant: "acme", payload_tenant: "loja-b")

    expect(result[:tenant]).to eq("acme")
    expect(memory_store.facts(tenant: "acme:123")).to be_empty
  end

  # The message the customer typed lives in the task's persisted command; the
  # transcript lives in the checkpoints; the answer as delivered lives in the
  # outbox payload. Deleting the session alone left all three readable.
  it "purges the CONTENT too: the customer's tasks, checkpoints and outbox deliveries" do
    session_store.create(id: "acme:chat-1", vars: { "customer" => "123" })
    task = task_store.create(
      command: Insika::Command.build(:send_message,
                                     { agent: "bia", message: "meu CPF é 123.456.789-00" }).to_h,
      session_id: "acme:chat-1", id: "t-1"
    )
    checkpoint_store.save(Insika::Checkpoint.new(task_id: task.id, turn: 1, session_id: "acme:chat-1",
                                                 agent_id: "bia", messages: [{ "role" => "user" }],
                                                 completed_side_effects: [], created_at: nil))
    outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: task.id,
                        session_id: "acme:chat-1", payload: { "text" => "seu pedido chega amanhã" })

    # a neighbouring session's footprint must survive
    session_store.create(id: "acme:chat-2", vars: { "customer" => "456" })
    task_store.create(command: { agent: "bia" }, session_id: "acme:chat-2", id: "t-2")
    outbox_store.create(channel: "relay", to: "https://x.test/cb", task_id: "t-2",
                        session_id: "acme:chat-2", payload: { "text" => "outra pessoa" })

    result = run(customer: "123", tenant: "acme")

    expect(result[:tasks]).to eq(1)
    expect(result[:checkpoints]).to eq(1)
    expect(result[:deliveries]).to eq(1)
    expect(task_store.find("t-1")).to be_nil
    expect(checkpoint_store.latest("t-1")).to be_nil
    expect(outbox_store.pending.map(&:session_id)).to eq(["acme:chat-2"])
    expect(task_store.find("t-2")).not_to be_nil
  end

  it "customer is required; an unknown customer is a clean no-op" do
    expect { run(customer: nil) }.to raise_error(Insika::ValidationError, /customer is required/)
    expect { run(customer: "ghost") }.not_to raise_error
  end

  describe "RFC-0031 audit line" do
    let(:audit_store) { Insika::MemoryAuditStore.new(store: backend) }
    subject(:command) do
      described_class.new(memory_store: memory_store, session_store: session_store,
                          tool_trace_store: tool_trace, context_trace_store: context_trace,
                          task_store: task_store, checkpoint_store: checkpoint_store,
                          outbox_store: outbox_store, audit_store: audit_store,
                          event_stream: event_stream)
    end

    it "records a content-free purge line with counts after the purge" do
      memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
      memory_store.add_note(tenant: "acme:123", text: "prefere email")

      run(customer: "123", tenant: "acme")

      expect(memory_store.facts(tenant: "acme:123")).to be_empty
      entry = audit_store.for_cell("memory:acme:123").first
      expect(entry.action).to eq("purge")
      expect(entry.actor).to eq("operator")
      expect(entry.tenant).to eq("acme")
      expect(entry.customer).to eq("123")
      expect(entry.note).to include("memory_records: 2")
      expect(entry.note).to include("sessions: 0")
      # the audit line records the DELETION, never the deleted content
      expect(entry.old_hash).to be_nil
      expect(entry.new_hash).to be_nil
      expect(entry.note).not_to include("open")
    end

    it "the payload operator rides through" do
      memory_store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
      command.call(Insika::Command.build(:forget_customer, { customer: "123", tenant: "acme",
                                                              operator: "studio" }))
      expect(audit_store.for_cell("memory:acme:123").first.actor).to eq("studio")
    end
  end

  it "nil audit_store -> no audit line, no error (the minimal graph)" do
    expect { run(customer: "123", tenant: "acme") }.not_to raise_error
  end

  describe "RFC-0033 C11 — the follow-up footprint dies with the person" do
    it "purges the customer's records and contact cell; a neighbour survives" do
      followup_store.create(tenant: "acme", agent: "a", customer: "123", session_id: "s-1",
                            at: Time.now.utc + 3600, reason: "r1", arm: "schedule", id: "f1",
                            now: Time.now.utc)
      followup_store.create(tenant: "acme", agent: "a", customer: "456", session_id: "s-2",
                            at: Time.now.utc + 3600, reason: "r2", arm: "schedule", id: "f2",
                            now: Time.now.utc)
      contact_store.set_granted(tenant: "acme", customer: "123")
      contact_store.set_granted(tenant: "acme", customer: "456")

      result = run(customer: "123", tenant: "acme")

      expect(result[:followups]).to eq(1)
      expect(result[:contacts]).to eq(1)
      expect(followup_store.find("f1")).to be_nil
      expect(followup_store.find("f2")).not_to be_nil
      expect(contact_store.get(tenant: "acme", customer: "123")).to be_nil
      expect(contact_store.get(tenant: "acme", customer: "456")).not_to be_nil
    end
  end

  describe "RFC-0034 C8 — the proposals die with the person" do
    it "purges the customer's proposals (every status) and reports the count; a neighbour survives" do
      p1 = proposal_store.create(tenant: "acme", customer: "123", session_ref: "acme:s-1",
                                 key: "size", value: "M", id: "p1")
      proposal_store.create(tenant: "acme", customer: "456", session_ref: "acme:s-2",
                            key: "size", value: "L", id: "p2")
      proposal_store.dismiss(id: p1.id) # a terminal row dies too

      result = run(customer: "123", tenant: "acme")

      expect(result[:proposals]).to eq(1)
      expect(proposal_store.find("p1")).to be_nil
      expect(proposal_store.find("p2")).not_to be_nil
    end

    it "nil proposal_store -> no purge, no error (the minimal graph)" do
      cmd = described_class.new(memory_store: memory_store, session_store: session_store,
                                event_stream: event_stream, proposal_store: nil)
      expect { cmd.call(Insika::Command.build(:forget_customer, { customer: "123" })) }
        .not_to raise_error
    end
  end
end