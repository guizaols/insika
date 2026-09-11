# frozen_string_literal: true

require "spec_helper"
require "async"

# Customer confirmation: a tool in profile.customer_confirm is HELD by the
# envelope — recorded as a customer pending, returned to the model as
# pending_confirmation, the turn goes on to ask. Nothing runs until
# confirm_pending re-enters through #call_confirmed on a later turn.
RSpec.describe "ToolEnvelope — customer confirmation" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:pending) { Insika::PendingActionStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(sink) = @sink = sink; def emit(e) = @sink << e }.new(events) }

  class HeldOrderTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "create_order"
    def call(args) = (@calls << args) && "created"
  end

  class HeldGatedTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "add_to_cart"
    def requires_evidence = { "params" => ["product_id"] }
    def call(args) = (@calls << args) && "added"
  end

  class RecordingCoordinator
    attr_reader :requested

    def initialize = (@requested = [])

    def request_approval(**kw)
      @requested << kw
      "approved"
    end
  end

  def state_for(confirm: ["create_order"], approvals: [], session_id: "s1", store: pending, task_id: "t1")
    profile = Insika::AgentProfile.build(id: "a", model: "m", customer_confirm: confirm)
    task = Struct.new(:id, :session_id).new(task_id, session_id)
    st = Insika::TurnState.new(task: task, profile: profile, turn: 2, message: "fecha")
    st.requires_approval = approvals
    st.approval_coordinator = RecordingCoordinator.new
    st.pending_action_store = store
    st.actor = nil
    st
  end

  def envelope(tool, state)
    Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
                                   tool_registry: FakeToolRegistry.new, timeout: 60,
                                   event_stream: event_stream)
  end

  it "holds the call: the tool does not run, the model gets the held shape, one customer pending exists" do
    tool = HeldOrderTool.new
    result = Sync { envelope(tool, state_for).call({ "cart_id" => "c1" }) }

    expect(tool.calls).to be_empty
    expect(result).to be_a(Insika::ToolEnvelope::Held)
    expect(result).to include("status" => "pending_confirmation", "gate" => "confirmation",
                              "tool" => "create_order", "args" => { "cart_id" => "c1" },
                              "instruction" => Insika::ToolEnvelope::CONFIRMATION_INSTRUCTION)
    pa = pending.find(result["pending_id"])
    expect(pa.status).to eq(:pending)
    expect(pa.kind).to eq("customer")
    expect(pa.session_id).to eq("s1")
    expect(pa.task_id).to eq("t1")
    expect(pa.args).to eq("cart_id" => "c1")
    expect(events.map(&:type)).to eq([:confirmation_requested])
    expect(events.first.data).to include(pending_id: pa.id, tool: "create_order")
  end

  it "the id is per (session, tool): the same tool held twice is one row, the newest args" do
    st = state_for
    Sync do
      envelope(HeldOrderTool.new, st).call({ "cart_id" => "c1" })
      envelope(HeldOrderTool.new, st).call({ "cart_id" => "c2" })
    end
    open = pending.open_for_session("s1", kind: "customer")
    expect(open.size).to eq(1)
    expect(open.first.args).to eq("cart_id" => "c2")
    expect(open.first.id).to eq(Insika::PendingActionStore.confirmation_id("s1", "create_order"))
  end

  it "a tool outside customer_confirm runs as before" do
    tool = HeldOrderTool.new
    result = Sync { envelope(tool, state_for(confirm: ["delete_customer"])).call({ "cart_id" => "c1" }) }
    expect(result).to eq("created")
    expect(pending.all_open).to be_empty
  end

  it "runs after the provenance gate: an unseen id is blocked, not put to the customer" do
    tool = HeldGatedTool.new
    result = Sync { envelope(tool, state_for(confirm: ["add_to_cart"])).call({ "product_id" => "999" }) }
    expect(result).to be_a(Insika::ToolEnvelope::Blocked)
    expect(pending.all_open).to be_empty
  end

  it "runs before the approval gate: the operator is never asked about a call the customer has not confirmed" do
    st = state_for(approvals: ["create_order"])
    expect { Insika::AgentProfile.build(id: "a", model: "m", customer_confirm: ["x"], approvals_required: ["x"]) }
      .to raise_error(Insika::ValidationError, /not both/)
    # profile validation forbids the overlap; an inconsistent turn state still holds first
    Sync { envelope(HeldOrderTool.new, st).call({}) }
    expect(st.approval_coordinator.requested).to be_empty
  end

  it "fails loud with no PendingActionStore or no session — never runs the write" do
    tool = HeldOrderTool.new
    expect { Sync { envelope(tool, state_for(store: nil)).call({}) } }
      .to raise_error(Insika::Error, /no PendingActionStore/)
    expect { Sync { envelope(tool, state_for(session_id: nil)).call({}) } }
      .to raise_error(Insika::Error, /no session/)
    expect(tool.calls).to be_empty
  end

  it "#call_confirmed skips only the hold: the tool runs, and every other check still applies" do
    tool = HeldOrderTool.new
    result = Sync { envelope(tool, state_for).call_confirmed({ "cart_id" => "c1" }) }
    expect(result).to eq("created")
    expect(tool.calls).to eq([{ "cart_id" => "c1" }])
    expect(pending.all_open).to be_empty

    gated = HeldGatedTool.new
    blocked = Sync { envelope(gated, state_for(confirm: ["add_to_cart"])).call_confirmed({ "product_id" => "999" }) }
    expect(blocked).to be_a(Insika::ToolEnvelope::Blocked)
    expect(gated.calls).to be_empty
  end

  it "the trace records the hold under gate=confirmation" do
    traces = []
    recorder = Class.new { def initialize(s) = @s = s; def record(session_id:, entry:) = @s << entry }.new(traces)
    env = Insika::ToolEnvelope.new(HeldOrderTool.new, state: state_for, checkpoint_store: checkpoint_store,
                                                      tool_registry: FakeToolRegistry.new, timeout: 60,
                                                      trace_recorder: recorder)
    Sync { env.call({ "cart_id" => "c1" }) }
    expect(traces.first).to include("tool" => "create_order", "gate" => "confirmation")
  end
end
