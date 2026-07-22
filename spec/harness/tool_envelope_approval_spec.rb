# frozen_string_literal: true

require "spec_helper"
require "async"

# Approval gate (P2 task 7): the ToolEnvelope suspends via the coordinator
# when the tool is in requires_approval; Executor#request_approval is the
# real coordinator (creates PendingAction, :waiting, await, store decision).
RSpec.describe "ToolEnvelope — approval gate" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }

  # Fake tool: records the received args and returns a result.
  class ChargeTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "charge"
    def call(args) = (@calls << args) && "charged"
  end

  # Fake coordinator: returns the configured decision, recording the call.
  class FakeCoordinator
    attr_reader :requested

    def initialize(decision) = (@decision = decision; @requested = [])

    def request_approval(task:, turn:, tool:, args:, actor:)
      @requested << { task: task.id, turn: turn, tool: tool, args: args }
      @decision
    end
  end

  def state_with(requires_approval:, coordinator:)
    profile = Harness::AgentProfile.build(id: "a", model: "m")
    task = Struct.new(:id, :session_id).new("t", nil)
    st = Harness::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
    st.requires_approval = requires_approval
    st.approval_coordinator = coordinator
    st.actor = nil
    st
  end

  def envelope(tool, state)
    Harness::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
                                    tool_registry: FakeToolRegistry.new, timeout: 60)
  end

  it "marked tool + approved -> runs the tool" do
    tool = ChargeTool.new
    coord = FakeCoordinator.new("approved")
    env = envelope(tool, state_with(requires_approval: ["charge"], coordinator: coord))

    result = Sync { env.call({ "amount" => 10 }) }

    expect(result).to eq("charged")
    expect(tool.calls).to eq([{ "amount" => 10 }])
    expect(coord.requested.first).to include(tool: "charge")
  end

  it "marked tool + rejected -> {error: rejected}, does NOT run (turn continues)" do
    tool = ChargeTool.new
    coord = FakeCoordinator.new("rejected")
    env = envelope(tool, state_with(requires_approval: ["charge"], coordinator: coord))

    result = Sync { env.call({ "amount" => 10 }) }

    expect(result).to eq({ error: "rejected by operator" })
    expect(tool.calls).to be_empty
  end

  it "tool NOT marked -> runs without consulting the coordinator" do
    tool = ChargeTool.new
    coord = FakeCoordinator.new("rejected") # must not be called
    env = envelope(tool, state_with(requires_approval: ["outra"], coordinator: coord))

    result = Sync { env.call({}) }

    expect(result).to eq("charged")
    expect(coord.requested).to be_empty
  end

  describe "tool-call trace (FOLLOWUP §3.1)" do
    def traced_state(session_id:)
      profile = Harness::AgentProfile.build(id: "a", model: "m")
      task = Struct.new(:id, :session_id).new("t", session_id)
      st = Harness::TurnState.new(task: task, profile: profile, turn: 2, message: "oi")
      st.requires_approval = []
      st
    end

    it "records name + args + result per call when a trace_recorder is present" do
      recorder = Harness::ToolTraceStore.new(store: Harness::Stores::Memory.new)
      env = Harness::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: "sess-1"),
                                      checkpoint_store: checkpoint_store, tool_registry: FakeToolRegistry.new,
                                      timeout: 60, trace_recorder: recorder)

      result = Sync { env.call({ "amount" => 10 }) }

      expect(result).to eq("charged")
      tr = recorder.for_session("sess-1")
      expect(tr.size).to eq(1)
      expect(tr.first).to include("tool" => "charge", "turn" => 2, "ok" => true)
      expect(tr.first["args"]).to include("amount")
      expect(tr.first["result"]).to include("charged")
      expect(tr.first["ms"]).to be_a(Integer)
    end

    it "session_id nil -> does not record (no session, nothing to attach)" do
      recorder = Harness::ToolTraceStore.new(store: Harness::Stores::Memory.new)
      env = Harness::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: nil),
                                      checkpoint_store: checkpoint_store, tool_registry: FakeToolRegistry.new,
                                      timeout: 60, trace_recorder: recorder)
      Sync { env.call({}) }
      expect(recorder.for_session("")).to eq([])
    end

    it "no trace_recorder (nil) -> runs normally, does not break" do
      env = Harness::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: "s"),
                                      checkpoint_store: checkpoint_store, tool_registry: FakeToolRegistry.new,
                                      timeout: 60)
      expect(Sync { env.call({}) }).to eq("charged")
    end
  end

  describe "Executor#request_approval (real coordinator)" do
    let(:task_store) { Harness::TaskStore.new(store: backend) }
    let(:pending_store) { Harness::PendingActionStore.new(store: backend) }
    let(:event_stream) { SpyEventStream.new }

    let(:executor) do
      Harness::Executor.new(
        context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
        middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
        profiles: {}, session_store: Harness::SessionStore.new(store: backend),
        task_store: task_store, checkpoint_store: checkpoint_store,
        event_stream: event_stream, pending_action_store: pending_store
      )
    end

    def running_task
      task_store.create(command: { "type" => "send_message" }, id: "t")
      task_store.begin_execution("t")
      task_store.transition("t", to: :running)
      task_store.find("t")
    end

    it "suspends at :waiting, emits :approval_requested, resumes at :approval with the store decision" do
      task = running_task
      decision = nil

      Sync do |top|
        actor = Harness::TaskActor.new(task_id: "t")
        waiter = top.async do
          decision = executor.request_approval(task: task, turn: 1, tool: "charge", args: { "a" => 1 }, actor: actor)
        end
        top.sleep(0.02)
        expect(task_store.find("t").status).to eq(:waiting)
        expect(event_stream.types).to include(:approval_requested)

        # simulates the ApproveAction (task 8): resolves the store + posts :approval
        pending_store.resolve("t:1:charge", decision: :approved, operator: "op")
        actor.post(:approval)
        waiter.wait
      end

      expect(decision).to eq("approved")
      expect(task_store.find("t").status).to eq(:running)
    end

    it "fail-closed: no PendingActionStore configured -> Error (does not hang, does not auto-approve)" do
      no_store = Harness::Executor.new(
        context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
        middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
        profiles: {}, session_store: Harness::SessionStore.new(store: backend),
        task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
      ) # pending_action_store: nil
      running_task

      Sync do
        actor = Harness::TaskActor.new(task_id: "t")
        expect { no_store.request_approval(task: task_store.find("t"), turn: 1, tool: "charge", args: {}, actor: actor) }
          .to raise_error(Harness::Error, /PendingActionStore/)
      end
    end

    it "fail-closed: a spurious :approval (before resolving) does NOT unblock — re-waits" do
      task = running_task
      decision = nil

      Sync do |top|
        actor = Harness::TaskActor.new(task_id: "t")
        waiter = top.async do
          decision = executor.request_approval(task: task, turn: 1, tool: "charge", args: {}, actor: actor)
        end
        top.sleep(0.02)
        actor.post(:approval)   # spurious: nothing has been resolved yet
        top.sleep(0.02)
        expect(task_store.find("t").status).to eq(:waiting) # still waiting

        pending_store.resolve("t:1:charge", decision: :approved, operator: "op")
        actor.post(:approval)   # real
        waiter.wait
      end

      expect(decision).to eq("approved")
    end

    it "re-run: an already resolved PendingAction is reused WITHOUT re-suspending" do
      running_task
      pending_store.create(id: "t:1:charge", task_id: "t", turn: 1, tool: "charge", args: {})
      pending_store.resolve("t:1:charge", decision: :rejected, operator: "op")

      decision = Sync do
        actor = Harness::TaskActor.new(task_id: "t")
        executor.request_approval(task: task_store.find("t"), turn: 1, tool: "charge", args: {}, actor: actor)
      end

      expect(decision).to eq("rejected")
      expect(task_store.find("t").status).to eq(:running) # did not go to :waiting
    end
  end
end
