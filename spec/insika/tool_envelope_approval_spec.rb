# frozen_string_literal: true

require "spec_helper"
require "async"

# Approval gate: the ToolEnvelope suspends via the coordinator
# when the tool is in requires_approval; Executor#request_approval is the
# real coordinator (creates PendingAction, :waiting, await, store decision).
RSpec.describe "ToolEnvelope — approval gate" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }

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
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    task = Struct.new(:id, :session_id).new("t", nil)
    st = Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
    st.requires_approval = requires_approval
    st.approval_coordinator = coordinator
    st.actor = nil
    st
  end

  def envelope(tool, state)
    Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
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

  describe "native approval resolver" do
    let(:tool) { ChargeTool.new }
    let(:coordinator) { FakeCoordinator.new("approved") }
    let(:state) { state_with(requires_approval: ["charge"], coordinator: coordinator) }
    let(:env) { envelope(tool, state) }
    let(:call) { RubyLLM::ToolCall.new(id: "charge-1", name: "charge", arguments: { "amount" => 10 }) }

    before do
      allow(state).to receive(:native_approvals).and_return(true)
    end

    it "advertises approval only for native chats and keeps the real tool name behind aliases" do
      expect(env.requires_approval?).to be(true)
      allow(state).to receive(:native_approvals).and_return(false)
      expect(env.requires_approval?).to be(false)
      aliased = Insika::Capability::ResolvedTool.new(tool, capability_name: "pay", impl_name: "charge")
      expect(envelope(aliased, state).approval_tool_name).to eq("charge")
    end

    it "queries decisions repeatedly without requesting approval or changing call context" do
      expect(coordinator).to receive(:approval_decision).with(
        task: state.task, turn: 1, tool: "charge", args: call.arguments, call_id: "charge-1"
      ).twice.and_return(nil)
      2.times { expect(env.approval_resolver.call(call)).to be_nil }
      expect(coordinator.requested).to be_empty
      expect(state.current_tool_call).to be_nil
      expect(tool.calls).to be_empty
    end

    it "lets the envelope return provenance blocks before querying approval" do
      def tool.requires_evidence = { "params" => ["product_id"] }
      expect(coordinator).not_to receive(:approval_decision)
      expect(env.approval_resolver.call(call)).to be(true)
      expect(Sync { env.call(call.arguments, tool_call: call) }).to be_a(Insika::ToolEnvelope::Blocked)
      expect(tool.calls).to be_empty
    end

    it "lets the envelope hold customer confirmation without creating a hold during resolver reads" do
      allow(state).to receive(:profile).and_return(
        Insika::AgentProfile.build(id: "a", model: "m", customer_confirm: ["charge"])
      )
      state.task.session_id = "s"
      state.pending_action_store = Insika::PendingActionStore.new(store: backend)
      expect(coordinator).not_to receive(:approval_decision)
      2.times { expect(env.approval_resolver.call(call)).to be(true) }
      expect(state.pending_action_store.all_open).to be_empty
      expect(Sync { env.call(call.arguments, tool_call: call) }).to be_a(Insika::ToolEnvelope::Held)
      expect(state.pending_action_store.all_open.size).to eq(1)
      expect(tool.calls).to be_empty
    end

    it "skips completed side effects before approval" do
      skipped = Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
        tool_registry: FakeToolRegistry.new, timeout: 60, skip_side_effects: [call.id])
      expect(coordinator).not_to receive(:approval_decision)
      expect(skipped.approval_resolver.call(call)).to be(true)
      expect(Sync { skipped.call(call.arguments, tool_call: call) }).to eq("skipped" => "already_executed")
      expect(tool.calls).to be_empty
    end

    it "rechecks approval at execution instead of retaining a resolver grant" do
      expect(coordinator).to receive(:approval_decision).ordered.and_return(true)
      expect(coordinator).to receive(:approval_decision).ordered.and_return(false)
      expect(env.approval_resolver.call(call)).to be(true)
      expect(Sync { env.call(call.arguments, tool_call: call) }).to eq(error: "rejected by operator")
      expect(coordinator.requested).to be_empty
      expect(tool.calls).to be_empty
    end

    it "runs an approved native call without the blocking approval path" do
      expect(coordinator).to receive(:approval_decision).with(
        task: state.task, turn: 1, tool: "charge", args: call.arguments, call_id: call.id
      ).and_return(true)
      expect(Sync { env.call(call.arguments, tool_call: call) }).to eq("charged")
      expect(tool.calls).to eq([call.arguments])
      expect(coordinator.requested).to be_empty
    end

    it "does not repeat a recorded native side effect within the same chat" do
      registry = FakeToolRegistry.new
      allow(registry).to receive(:side_effect?).with("charge").and_return(true)
      guarded = Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
        tool_registry: registry, timeout: 60)
      expect(coordinator).to receive(:approval_decision).once.and_return(true)
      Sync do
        expect(guarded.call(call.arguments, tool_call: call)).to eq("charged")
        expect(guarded.approval_resolver.call(call)).to be(true)
        expect(guarded.call(call.arguments, tool_call: call)).to eq("skipped" => "already_executed")
      end
      expect(tool.calls).to eq([call.arguments])
    end

    it "restores a checkpointed halt when replay skips its completed side effect" do
      def tool.call(args) = (@calls << args) && Insika::ToolDefinition::Halt.new(content: "Delivered")
      state.approval_continuation = { "messages" => [] }
      checkpoint_store.save(Insika::Checkpoint.new(task_id: state.task.id, turn: state.turn,
        session_id: nil, agent_id: "a", messages: [], completed_side_effects: [], created_at: nil,
        continuation: state.approval_continuation))
      registry = FakeToolRegistry.new
      allow(registry).to receive(:side_effect?).with("charge").and_return(true)
      guarded = Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
        tool_registry: registry, timeout: 60)
      expect(coordinator).to receive(:approval_decision).once.and_return(true)
      expect(Sync { guarded.call(call.arguments, tool_call: call) }).to be_a(Insika::ToolDefinition::Halt)
      expect(state.approval_continuation.fetch("halts")).to eq(call.id => { "content" => "Delivered" })

      state.approval_continuation = checkpoint_store.latest(state.task.id).continuation
      expect(state.approval_continuation.fetch("halts")).to eq(call.id => { "content" => "Delivered" })
      replay = Insika::ToolEnvelope.new(tool, state: state, checkpoint_store: checkpoint_store,
        tool_registry: registry, timeout: 60, skip_side_effects: checkpoint_store.side_effects(state.task.id, turn: state.turn))
      result = Sync { replay.call(call.arguments, tool_call: call) }
      expect(result).to eq(Insika::ToolDefinition::Halt.new(content: "Delivered"))
      expect(tool.calls).to eq([call.arguments])
    end

    it "fails closed when the decision is unresolved" do
      expect(coordinator).to receive(:approval_decision).and_return(nil)
      expect(Sync { env.call(call.arguments, tool_call: call) }).to eq(error: "rejected by operator")
      expect(tool.calls).to be_empty
      expect(coordinator.requested).to be_empty
    end

    it "validates the executed arguments even when the provider call carries approved arguments" do
      changed = { "amount" => 100 }
      expect(coordinator).to receive(:approval_decision).with(
        task: state.task, turn: 1, tool: "charge", args: changed, call_id: call.id
      ).and_raise(Insika::Error, "approval binding mismatch")
      expect { Sync { env.call(changed, tool_call: call) } }
        .to raise_error(Insika::Error, /binding mismatch/)
      expect(tool.calls).to be_empty
      expect(coordinator.requested).to be_empty
    end

    it "keeps workflow and confirmed calls on the blocking route even with current call context" do
      expect(coordinator).not_to receive(:approval_decision)
      Sync do
        state.current_tool_call = call
        expect(env.call(call.arguments)).to eq("charged")
        expect(env.call_confirmed(call.arguments)).to eq("charged")
      end
      expect(coordinator.requested.size).to eq(2)
    end

    it "does not let RubyLLM in-memory approval bypass the persisted resolver" do
      chat = RubyLLM.context { |config| config.deepseek_api_key = "spec-only" }
        .chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true)
      chat.with_tools(env)
      chat.add_message(role: :assistant, content: nil, tool_calls: { call.id => call })
      allow(coordinator).to receive(:approval_decision).and_return(nil)
      chat.approve(call)
      expect(chat.awaiting_approval?).to be(true)
      expect(chat.step).to be_nil
      expect(tool.calls).to be_empty
      expect(coordinator.requested).to be_empty
    end

    it "includes the provider call id on each lookup of the same tool" do
      second = RubyLLM::ToolCall.new(id: "charge-2", name: "charge", arguments: call.arguments)
      expect(coordinator).to receive(:approval_decision).with(
        task: state.task, turn: 1, tool: "charge", args: call.arguments, call_id: call.id
      ).and_return(true)
      expect(coordinator).to receive(:approval_decision).with(
        task: state.task, turn: 1, tool: "charge", args: second.arguments, call_id: second.id
      ).and_return(nil)
      expect(env.approval_resolver.call(call)).to be(true)
      expect(env.approval_resolver.call(second)).to be_nil
    end

    it "routes tool-declared approvals through persisted decisions too" do
      def tool.requires_approval? = true
      def tool.approval_resolver = ->(*) { true }
      state.requires_approval = []
      expect(coordinator).to receive(:approval_decision).and_return(nil)
      expect(env.requires_approval?).to be(true)
      expect(env.approval_resolver.call(call)).to be_nil
    end
  end

  describe "tool-call trace" do
    def traced_state(session_id:)
      profile = Insika::AgentProfile.build(id: "a", model: "m")
      task = Struct.new(:id, :session_id).new("t", session_id)
      st = Insika::TurnState.new(task: task, profile: profile, turn: 2, message: "oi")
      st.requires_approval = []
      st
    end

    it "records name + args + result per call when a trace_recorder is present" do
      recorder = Insika::ToolTraceStore.new(store: Insika::Stores::Memory.new)
      env = Insika::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: "sess-1"),
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
      recorder = Insika::ToolTraceStore.new(store: Insika::Stores::Memory.new)
      env = Insika::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: nil),
                                      checkpoint_store: checkpoint_store, tool_registry: FakeToolRegistry.new,
                                      timeout: 60, trace_recorder: recorder)
      Sync { env.call({}) }
      expect(recorder.for_session("")).to eq([])
    end

    it "no trace_recorder (nil) -> runs normally, does not break" do
      env = Insika::ToolEnvelope.new(ChargeTool.new, state: traced_state(session_id: "s"),
                                      checkpoint_store: checkpoint_store, tool_registry: FakeToolRegistry.new,
                                      timeout: 60)
      expect(Sync { env.call({}) }).to eq("charged")
    end
  end

  describe "Executor#request_approval (real coordinator)" do
    let(:task_store) { Insika::TaskStore.new(store: backend) }
    let(:pending_store) { Insika::PendingActionStore.new(store: backend) }
    let(:event_stream) { SpyEventStream.new }

    let(:executor) do
      Insika::Executor.new(
        context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
        middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
        profiles: {}, session_store: Insika::SessionStore.new(store: backend),
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
        actor = Insika::TaskActor.new(task_id: "t")
        waiter = top.async do
          decision = executor.request_approval(task: task, turn: 1, tool: "charge", args: { "a" => 1 }, actor: actor)
        end
        top.sleep(0.02)
        expect(task_store.find("t").status).to eq(:waiting)
        expect(event_stream.types).to include(:approval_requested)

        # simulates the ApproveAction: resolves the store + posts:approval
        pending_store.resolve("t:1:charge", decision: :approved, operator: "op")
        actor.post(:approval)
        waiter.wait
      end

      expect(decision).to eq("approved")
      expect(task_store.find("t").status).to eq(:running)
    end

    it "fail-closed: no PendingActionStore configured -> Error (does not hang, does not auto-approve)" do
      no_store = Insika::Executor.new(
        context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
        middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
        profiles: {}, session_store: Insika::SessionStore.new(store: backend),
        task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
      ) # pending_action_store: nil
      running_task

      Sync do
        actor = Insika::TaskActor.new(task_id: "t")
        expect { no_store.request_approval(task: task_store.find("t"), turn: 1, tool: "charge", args: {}, actor: actor) }
          .to raise_error(Insika::Error, /PendingActionStore/)
      end
    end

    it "fail-closed: a spurious :approval (before resolving) does NOT unblock — re-waits" do
      task = running_task
      decision = nil

      Sync do |top|
        actor = Insika::TaskActor.new(task_id: "t")
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
        actor = Insika::TaskActor.new(task_id: "t")
        executor.request_approval(task: task_store.find("t"), turn: 1, tool: "charge", args: {}, actor: actor)
      end

      expect(decision).to eq("rejected")
      expect(task_store.find("t").status).to eq(:running) # did not go to :waiting
    end
  end
end
