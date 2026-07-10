# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::ApproveAction do
  subject(:handler) do
    described_class.new(pending_action_store: pending_store, executor: executor, event_stream: events)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:pending_store) { Harness::PendingActionStore.new(store: backend) }
  let(:events) { SpyEventStream.new }
  let(:executor) { RecordingApproveExecutor.new }

  class RecordingApproveExecutor
    attr_reader :approved

    def initialize(live: true)
      @approved = []
      @live = live
    end

    def approve(task_id)
      @approved << task_id
      @live
    end
  end

  def pending(tool: "charge")
    pending_store.create(id: "t:1:#{tool}", task_id: "t", turn: 1, tool: tool, args: {})
  end

  def approve(pending_id, decision: "approved", operator: "alice")
    handler.call(Harness::Command.build(:approve_action,
                                        { pending_id: pending_id, decision: decision, operator: operator }))
  end

  it "resolve o PendingAction (approved) ANTES de acordar o fiber e emite :approval_resolved" do
    pa = pending
    resolved = approve(pa.id, decision: "approved")

    expect(resolved.status).to eq(:approved)
    expect(resolved.resolved_by).to eq("alice")
    # store resolvido no momento em que o executor é acordado
    expect(pending_store.find(pa.id).status).to eq(:approved)
    expect(executor.approved).to eq(["t"])
    expect(events.types).to include(:approval_resolved)
  end

  it "resolve rejected e acorda o fiber (turno seguirá com erro ao modelo)" do
    pa = pending
    resolved = approve(pa.id, decision: "rejected")
    expect(resolved.status).to eq(:rejected)
    expect(executor.approved).to eq(["t"])
  end

  it "no-op no executor sem fiber vivo (processo caiu): store fica resolvido" do
    dead = RecordingApproveExecutor.new(live: false)
    h = described_class.new(pending_action_store: pending_store, executor: dead, event_stream: events)
    pa = pending
    h.call(Harness::Command.build(:approve_action, { pending_id: pa.id, decision: "approved" }))
    expect(pending_store.find(pa.id).status).to eq(:approved) # durável p/ o recovery reexecutar
  end

  it "pending_id ausente -> ValidationError" do
    expect { handler.call(Harness::Command.build(:approve_action, { decision: "approved" })) }
      .to raise_error(Harness::ValidationError)
  end

  it "pending inexistente -> NotFoundError; decision inválida -> ValidationError" do
    expect { approve("ghost") }.to raise_error(Harness::NotFoundError)
    pa = pending
    expect { approve(pa.id, decision: "maybe") }.to raise_error(Harness::ValidationError)
  end

  it "dupla aprovação -> ValidationError (só :pending resolve)" do
    pa = pending
    approve(pa.id, decision: "approved")
    expect { approve(pa.id, decision: "rejected") }.to raise_error(Harness::ValidationError)
  end
end
