# frozen_string_literal: true

require "spec_helper"
require "insika/tools/schedule_followup" # the Executor loads it lazily; explicit in the test

# RFC-0033 C7 — the schedule/cancel_followup system builtins. Envelope-level
# behavior (at parsing, the consent write, the dedup/revoked refusals, the
# cancelled idempotence) — the tools' effects land on the stores like the
# engine reads them.
RSpec.describe Insika::Tools::ScheduleFollowup do
  let(:backend) { Insika::Stores::Memory.new }
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:stream) { SpyEventStream.new }

  let(:profile) do
    Insika::AgentProfile.build(
      id: "store-support", model: "m",
      followup: { "arm" => "schedule",
                  "policy" => { "cancel_keywords" => ["não quero mais contato"] } }
    )
  end
  let(:policy) { Insika::FollowupPolicy.parse!(profile.followup) }

  # A minimal turn-state double: the profile, the task (customer + transport
  # provenance) and the tenant the tools read.
  FollowupTaskDouble = Struct.new(:id, :session_id, :command)
  def state(customer: "c-1", tenant: "acme", transport: "channel:whatsapp")
    Struct.new(:profile, :task, :tenant) do
      def respond_to_missing?(*) = true
    end.new(
      profile,
      FollowupTaskDouble.new("t-1", "s-1",
                             { "type" => "send_message", "payload" => { "customer" => customer },
                               "meta" => { "transport" => transport } }),
      tenant
    )
  end

  subject(:tool) do
    described_class.new(contact_store: contact_store, followup_store: followup_store,
                        state: state, event_stream: stream)
  end

  def execute(at: "+6h", reason: "pix pending, customer said she would pay tonight")
    tool.execute(at: at, reason: reason)
  end

  it "schedules: writes :granted (the consent record IS the call), creates the record with arm + transport" do
    result = execute
    expect(result[:scheduled]).not_to be_nil
    record = followup_store.find(result[:scheduled])
    expect(record.status).to eq("pending")
    expect(record.arm).to eq("schedule")
    expect(record.transport).to eq("channel:whatsapp")
    expect(record.customer).to eq("c-1")
    expect(record.session_id).to eq("s-1")
    cell = contact_store.get(tenant: "acme", customer: "c-1")
    expect(cell.state).to eq("granted")
  end

  it "emits :followup_scheduled with ids + at, never the reason" do
    result = execute
    event = stream.events.find { |e| e.type == :followup_scheduled }
    expect(event).not_to be_nil
    expect(event.data).to eq(id: result[:scheduled], at: event.data[:at])
  end

  it "accepts an absolute ISO-8601 time at least 5 minutes out" do
    result = execute(at: (Time.now.utc + 3600).iso8601)
    expect(result[:scheduled]).not_to be_nil
  end

  it "refuses a non-parsable `at`" do
    expect(execute(at: "tomorrow")).to include(error: /ISO 8601/)
  end

  it "refuses a too-close or past `at` ('te chamo agora' is a normal turn, not a follow-up)" do
    expect(execute(at: "+1m")).to include(error: /5 minutes/)
    expect(execute(at: (Time.now.utc - 60).iso8601)).to include(error: /5 minutes/)
  end

  it "refuses an empty or overlong reason" do
    expect(execute(reason: "  ")).to include(error: /reason/)
    expect(execute(reason: "x" * 201)).to include(error: /reason/)
  end

  it "refuses a revoked customer (an opt-out is permanent)" do
    contact_store.set_revoked(tenant: "acme", customer: "c-1")
    expect(execute).to include(error: /opted out/)
    expect(followup_store.due(now: Time.now.utc + 9999)).to be_empty
  end

  it "a malformed policy is a tool error (D9)" do
    broken = Insika::AgentProfile.build(
      id: "store-support", model: "m",
      followup: { "arm" => "schedule", "policy" => { "max_frequency" => "2/3w" } }
    )
    tool = described_class.new(contact_store: contact_store, followup_store: followup_store,
                               state: Struct.new(:profile, :task, :tenant).new(
                                 broken, state.task, "acme"
                               ), event_stream: stream)
    expect(tool.execute(at: "+6h", reason: "r")).to include(error: /max_frequency/)
  end

  it "a re-booking NEVER un-silences a silent customer (review fix — the tool inside the scheduled turn cannot clear the protection)" do
    contact_store.bump_outbound(tenant: "acme", customer: "c-1")
    contact_store.bump_outbound(tenant: "acme", customer: "c-1")
    contact_store.mark_unavailable(tenant: "acme", customer: "c-1")

    result = execute(reason: "different reason")
    expect(result[:scheduled]).not_to be_nil # booked — but the state is intact
    cell = contact_store.get(tenant: "acme", customer: "c-1")
    expect(cell.state).to eq("unavailable")
    expect(cell.sends_without_reply).to eq(2)
  end

  it "a duplicate pending pair is refused, naming the existing id" do
    first = execute
    second = execute(reason: "pix pending, customer said she would pay tonight")
    expect(second[:error]).to include(first[:scheduled])
  end
end

RSpec.describe Insika::Tools::CancelFollowup do
  let(:backend) { Insika::Stores::Memory.new }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:profile) do
    Insika::AgentProfile.build(id: "store-support", model: "m",
                               followup: { "arm" => "schedule", "policy" => {} })
  end

  def state(tenant: "acme")
    Struct.new(:profile, :task, :tenant).new(profile, nil, tenant)
  end

  subject(:tool) do
    described_class.new(followup_store: followup_store, state: state)
  end

  def book!(tenant: "acme", id: SecureRandom.uuid)
    followup_store.create(tenant: tenant, agent: "store-support", customer: "c-1",
                          session_id: "s-1", at: Time.now.utc + 3600, reason: "r",
                          arm: "schedule", id: id)
  end

  it "cancels a pending record" do
    record = book!
    expect(tool.execute(id: record.id)).to eq(cancelled: record.id)
    expect(followup_store.find(record.id).status).to eq("cancelled")
  end

  it "is an idempotent no-op for an already-cancelled record" do
    record = book!
    tool.execute(id: record.id)
    expect(tool.execute(id: record.id)).to eq(cancelled: record.id)
  end

  it "refuses a fired record (':fired — it is in the air; it fires once')" do
    record = book!
    followup_store.transition_fired(id: record.id, task_id: "t-1")
    expect(tool.execute(id: record.id)).to include(error: /in the air/)
  end

  it "refuses a blocked record (terminal, like fired)" do
    record = book!
    followup_store.block(id: record.id, reason: :frequency)
    expect(tool.execute(id: record.id)).to include(error: /blocked/)
  end

  it "refuses a record of another tenant (WS1)" do
    record = book!(tenant: "zed")
    expect(tool.execute(id: record.id)).to include(error: /another tenant/)
    expect(followup_store.find(record.id).status).to eq("pending")
  end

  it "an unknown id is a tool error" do
    expect(tool.execute(id: "nope")).to include(error: /no follow-up/)
  end
end
