# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/confirm_pending"

RSpec.describe "confirm_pending / cancel_pending" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:pending) { Insika::PendingActionStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(sink) = @sink = sink; def emit(e) = @sink << e }.new(events) }

  class ConfirmableOrderTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "create_order"
    def call(args) = (@calls << args) && { "order_id" => "o-1" }
  end

  def state(session_id: "s1", task_id: "t2", tools: [])
    profile = Insika::AgentProfile.build(id: "a", model: "m", customer_confirm: ["create_order"])
    task = Struct.new(:id, :session_id).new(task_id, session_id)
    st = Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "sim")
    st.requires_approval = []
    st.pending_action_store = pending
    st.allowed_tools = tools
    st
  end

  def enveloped(tool, st)
    Insika::ToolEnvelope.new(tool, state: st, checkpoint_store: checkpoint_store,
                                   tool_registry: FakeToolRegistry.new, timeout: 60)
  end

  def hold(session_id: "s1", args: { "cart_id" => "c1" })
    pending.create(id: Insika::PendingActionStore.confirmation_id(session_id, "create_order"),
                   task_id: "t1", session_id: session_id, turn: 1, tool: "create_order",
                   args: args, kind: Insika::PendingActionStore::CUSTOMER)
  end

  it "confirm resolves the hold approved, then runs the ORIGINAL tool with the recorded args" do
    tool = ConfirmableOrderTool.new
    st = state(tools: [enveloped(tool, st = nil) || nil].compact)
    st.allowed_tools = [enveloped(tool, st)]
    pa = hold
    result = Sync { Insika::Tools::ConfirmPending.new(event_stream: event_stream, state: st).execute(pending_id: pa.id) }

    expect(result).to eq("order_id" => "o-1")
    expect(tool.calls).to eq([{ "cart_id" => "c1" }])
    resolved = pending.find(pa.id)
    expect(resolved.status).to eq(:approved)
    expect(resolved.resolved_by).to eq("customer")
    expect(events.map(&:type)).to eq([:confirmation_confirmed])
  end

  it "confirm refuses an unknown, foreign, operator or already-resolved id — with an error body, and runs nothing" do
    tool = ConfirmableOrderTool.new
    st = state
    st.allowed_tools = [enveloped(tool, st)]
    confirm = Insika::Tools::ConfirmPending.new(event_stream: event_stream, state: st)

    expect(confirm.execute(pending_id: "nope")[:error]).to match(/no held action/)
    other = hold(session_id: "s2")
    expect(confirm.execute(pending_id: other.id)[:error]).to match(/another conversation/)
    op = pending.create(task_id: "t2", turn: 1, tool: "create_order", session_id: "s1")
    expect(confirm.execute(pending_id: op.id)[:error]).to match(/not a customer confirmation/)
    done = hold
    pending.resolve(done.id, decision: :rejected, operator: "customer")
    expect(confirm.execute(pending_id: done.id)[:error]).to match(/already rejected/)
    expect(tool.calls).to be_empty
  end

  it "confirm on a tool the turn no longer allows -> error body, hold left as it was" do
    st = state(tools: [])
    pa = hold
    result = Insika::Tools::ConfirmPending.new(event_stream: event_stream, state: st).execute(pending_id: pa.id)
    expect(result[:error]).to match(/not available/)
    expect(pending.find(pa.id).status).to eq(:pending)
  end

  it "cancel resolves the hold rejected by the customer and says so" do
    st = state
    pa = hold
    result = Insika::Tools::CancelPending.new(event_stream: event_stream, state: st).execute(pending_id: pa.id)
    expect(result).to eq("status" => "cancelled", "tool" => "create_order")
    expect(pending.find(pa.id).status).to eq(:rejected)
    expect(pending.find(pa.id).resolved_by).to eq("customer")
    expect(events.map(&:type)).to eq([:confirmation_cancelled])
  end
end
