# frozen_string_literal: true

require "spec_helper"

#   — the operator cancels ONE pending follow-up record (the
# Studio's Cancel button). Tenant-scoped (WS1); a non-pending record (the tick
# fired it between the render and the click) is a domain error the Studio can
# flash — never a 500.
RSpec.describe Insika::Commands::CancelFollowup do
  let(:backend) { Insika::Stores::Memory.new }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:stream) { SpyEventStream.new }
  subject(:handler) { described_class.new(followup_store: followup_store, event_stream: stream) }

  def book!(id: SecureRandom.uuid, tenant: "acme", **rest)
    followup_store.create(tenant: tenant, agent: "a", customer: "c-1", session_id: "s-1",
                          at: Time.now.utc + 3600, reason: "r", arm: "schedule",
                          id: id, **rest)
  end

  def cancel(id, tenant: "acme")
    handler.call(Insika::Command.build(:cancel_followup, { "followup_id" => id }, tenant: tenant))
  end

  it "cancels the record and emits :followup_cancelled with the operator label" do
    record = book!
    cancel(record.id)
    expect(followup_store.find(record.id).status).to eq("cancelled")
    event = stream.events.find { |e| e.type == :followup_cancelled }
    expect(event.data).to include(id: record.id, cancelled_by: "operator")
  end

  it "a missing followup_id is a ValidationError" do
    expect { handler.call(Insika::Command.build(:cancel_followup, {})) }
      .to raise_error(Insika::ValidationError)
  end

  it "a nonexistent id is a NotFoundError" do
    expect { cancel("nope") }
      .to raise_error(Insika::NotFoundError)
  end

  it "is idempotent: an already-cancelled record returns as-is, one event" do
    record = book!
    cancel(record.id)
    cancel(record.id)
    expect(followup_store.find(record.id).status).to eq("cancelled")
    expect(stream.events.count { |e| e.type == :followup_cancelled }).to eq(2)
  end

  it "is tenant-scoped: a tenant token cannot cancel another tenant's record by id" do
    record = book!(tenant: "acme")
    expect { cancel(record.id, tenant: "zed") }
      .to raise_error(Insika::ValidationError, /another tenant/)
    expect(followup_store.find(record.id).status).to eq("pending")
  end

  it "a non-pending record (the tick fired it mid-click) is a ValidationError, never a 500" do
    record = book!
    followup_store.transition_fired(id: record.id, task_id: "t-1", now: Time.now.utc)
    expect { cancel(record.id) }
      .to raise_error(Insika::ValidationError, /cannot cancel/)
    expect(followup_store.find(record.id).status).to eq("fired")
  end
end