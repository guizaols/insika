# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::PendingActionStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }

  def create(task_id: "t", turn: 1, tool: "charge", args: { "amount" => 10 })
    store.create(task_id: task_id, turn: turn, tool: tool, args: args)
  end

  it "create returns :pending with the fields populated" do
    pa = create
    expect(pa.status).to eq(:pending)
    expect(pa.task_id).to eq("t")
    expect(pa.tool).to eq("charge")
    expect(pa.args).to eq("amount" => 10)
    expect(pa.requested_at).to be_a(String)
    expect(pa.resolved_by).to be_nil
  end

  it "find retrieves by id; nil if absent" do
    pa = create
    expect(store.find(pa.id).id).to eq(pa.id)
    expect(store.find("ghost")).to be_nil
  end

  it "normalizes symbol->string on write (round-trip of nested args)" do
    pa = store.create(task_id: "t", turn: 1, tool: :charge, args: { nested: { k: :v } })
    reloaded = store.find(pa.id)
    expect(reloaded.tool).to eq("charge")
    expect(reloaded.args).to eq("nested" => { "k" => "v" })
  end

  it "open_for filters by task_id and :pending status" do
    a = create(task_id: "t1")
    create(task_id: "t2")
    resolved = create(task_id: "t1")
    store.resolve(resolved.id, decision: :approved, operator: "op")

    open = store.open_for("t1")
    expect(open.map(&:id)).to eq([a.id]) # only the :pending one from t1
  end

  it "all_open returns every:pending across tasks (approvals inbox)" do
    a = create(task_id: "t1")
    b = create(task_id: "t2")
    resolved = create(task_id: "t1")
    store.resolve(resolved.id, decision: :rejected, operator: "op")

    expect(store.all_open.map(&:id)).to contain_exactly(a.id, b.id) # both tasks, only :pending
  end

  it "resolve approved records decision, operator and timestamp" do
    pa = create
    resolved = store.resolve(pa.id, decision: :approved, operator: "alice")
    expect(resolved.status).to eq(:approved)
    expect(resolved.resolved_by).to eq("alice")
    expect(resolved.resolved_at).to be_a(String)
  end

  it "resolve rejected" do
    pa = create
    expect(store.resolve(pa.id, decision: :rejected, operator: "bob").status).to eq(:rejected)
  end

  it "resolve of absent -> NotFoundError" do
    expect { store.resolve("ghost", decision: :approved) }.to raise_error(Insika::NotFoundError)
  end

  it "double resolve -> ValidationError (only :pending resolves)" do
    pa = create
    store.resolve(pa.id, decision: :approved, operator: "op")
    expect { store.resolve(pa.id, decision: :rejected, operator: "op") }
      .to raise_error(Insika::ValidationError, /already resolved/)
  end

  it "invalid decision -> ValidationError" do
    pa = create
    expect { store.resolve(pa.id, decision: :maybe) }.to raise_error(Insika::ValidationError, /decision/)
  end
end
