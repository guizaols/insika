require "spec_helper"

#   — the channel opt-out event (mapped by the integration) or the
# operator force-revoking a contact: the cell + every pending record fall in
# ONE transaction — a half-cancelled opt-out is the spam bug (D2).
RSpec.describe Insika::Commands::RevokeContact do
  let(:backend) { Insika::Stores::Memory.new }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:stream) { SpyEventStream.new }
  subject(:handler) do
    described_class.new(contact_store: contact_store, followup_store: followup_store,
                        store: backend, event_stream: stream)
  end

  def book!(tenant: "acme", customer: "c-1", id: SecureRandom.uuid, reason: "r", at: nil)
    followup_store.create(tenant: tenant, agent: "a", customer: customer, session_id: "s-1",
                          at: at || Time.now.utc + 3600, reason: reason, arm: "schedule",
                          id: id)
  end

  it "revokes the contact and cancels EVERY pending record of the customer in one call" do
    pending_a = book!(id: "a")
    pending_b = book!(id: "b", reason: "r2")
    contact_store.set_granted(tenant: "acme", customer: "c-1")

    handler.call(Insika::Command.build(:revoke_contact, { "customer" => "c-1" }, tenant: "acme"))

    expect(contact_store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
    expect(followup_store.find("a").status).to eq("cancelled")
    expect(followup_store.find("b").status).to eq("cancelled")
  end

  it "emits :contact_revoked + :followups_cancelled with counts" do
    book!(id: "a")
    handler.call(Insika::Command.build(:revoke_contact, { "customer" => "c-1" }, tenant: "acme"))
    expect(stream.types).to include(:contact_revoked, :followups_cancelled)
    cancelled = stream.events.find { |e| e.type == :followups_cancelled }
    expect(cancelled.data).to include(customer: "c-1", count: 1)
  end

  it "a missing customer is a ValidationError" do
    expect { handler.call(Insika::Command.build(:revoke_contact, {})) }
      .to raise_error(Insika::ValidationError)
  end

  it "is tenant-scoped: a tenant revokes only its own cell and records" do
    book!(id: "acme-a", tenant: "acme")
    book!(id: "zed-a", tenant: "zed")
    contact_store.set_granted(tenant: "acme", customer: "c-1")
    contact_store.set_granted(tenant: "zed", customer: "c-1")

    handler.call(Insika::Command.build(:revoke_contact, { "customer" => "c-1" }, tenant: "acme"))

    expect(contact_store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
    expect(contact_store.get(tenant: "zed", customer: "c-1").state).to eq("granted")
    expect(followup_store.find("acme-a").status).to eq("cancelled")
    expect(followup_store.find("zed-a").status).to eq("pending")
  end

  it "revocation does NOT touch blocked or fired records" do
    fired = book!(id: "fired")
    blocked = book!(id: "blocked", reason: "r2")
    followup_store.transition_fired(id: "fired", task_id: "t-1")
    followup_store.block(id: "blocked", reason: :frequency)

    handler.call(Insika::Command.build(:revoke_contact, { "customer" => "c-1" }, tenant: "acme"))

    expect(followup_store.find("fired").status).to eq("fired")
    expect(followup_store.find("blocked").status).to eq("blocked")
    expect(stream.events.find { |e| e.type == :followups_cancelled }.data[:count]).to eq(0)
  end
end
