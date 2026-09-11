# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::PendingConfirmation do
  let(:backend) { Insika::Stores::Memory.new }
  let(:pending) { Insika::PendingActionStore.new(store: backend) }
  let(:provider) { described_class.new(pending_action_store: pending) }
  let(:session) { Struct.new(:id).new("s1") }

  def profile(confirm: ["create_order"]) = Insika::AgentProfile.build(id: "a", model: "m", customer_confirm: confirm)

  def request(prof = profile, sess = session)
    Insika::ContextRequest.new(session: sess, message: "sim", profile: prof, tenant: nil, vars: {}, checkpoint: nil)
  end

  def hold(tool: "create_order", args: { "cart_id" => "c1" }, session_id: "s1", kind: Insika::PendingActionStore::CUSTOMER)
    pending.create(id: Insika::PendingActionStore.confirmation_id(session_id, tool), task_id: "t1",
                   session_id: session_id, turn: 1, tool: tool, args: args, kind: kind)
  end

  it "is enabled only for a profile with customer_confirm, and not governed by the allowlist" do
    expect(provider.enabled_for?(profile(confirm: nil))).to be(false)
    expect(provider.enabled_for?(profile)).to be(true)
    expect(provider.allowlisted?).to be(false)
  end

  it "renders nothing with no session, no open hold, or only operator pendings" do
    expect(provider.call(request(profile, nil))).to eq([])
    expect(provider.call(request)).to eq([])
    pending.create(task_id: "t1", turn: 1, tool: "create_order", session_id: "s1")
    expect(provider.call(request)).to eq([])
  end

  it "renders ONE pinned tail fragment naming every open hold of the session with its args and id" do
    hold
    hold(tool: "delete_customer", args: { "id" => "c9" })
    hold(session_id: "s2") # another conversation's hold never leaks in
    frags = provider.call(request)

    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.pinned, f.priority, f.source]).to eq([:tail, true, Insika::Context::Priority::PENDING_CONFIRMATION, "pending_confirmation"])
    expect(f.content).to include("## Awaiting the customer's confirmation")
    expect(f.content).to include('create_order {"cart_id":"c1"} — pending_id confirm:s1:create_order')
    expect(f.content).to include('delete_customer {"id":"c9"}')
    expect(f.content).not_to include("confirm:s2:")
    expect(f.content).to include("cancel_pending")
  end
end
