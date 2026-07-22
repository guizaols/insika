# frozen_string_literal: true

require "spec_helper"
require "async"
require "harness/tools/subagent" # the delivery turn (parent has subagents) wires it;
#                                  the Executor requires it lazily in create_chat, which
#                                  these specs stub — so load it explicitly here.

# RFC-0010 Fase 2 (item 21): async/durable delegation. run_subagent(async:true)
# dispatches a child NON-blocking and returns immediately; when the child finishes,
# its result is delivered to the parent session as a NEW turn (never spliced
# mid-turn). Durable: DelegationStore + terminal hook + boot recovery.
RSpec.describe "Harness::Executor async delegation (RFC-0010 Fase 2)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:delegation_store) { Harness::DelegationStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }

  let(:child_profile) { Harness::AgentProfile.build(id: "researcher", model: "gpt", base_prompt: "CHILD") }
  let(:parent_profile) do
    Harness::AgentProfile.build(id: "parent", model: "pm", base_prompt: "PARENT", subagents: ["researcher"])
  end

  def build_executor(delegation: delegation_store)
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: { "parent" => parent_profile, "researcher" => child_profile },
      session_store: session_store, task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, delegation_store: delegation
    )
  end

  def parent_state
    session_store.create(id: "parent-sess")
    cmd = Harness::Command.build(:send_message, { agent: "parent", message: "go" }).to_h
    task = task_store.create(command: cmd, session_id: "parent-sess", id: "parent-task")
    st = Harness::TurnState.new(task: task, profile: parent_profile, turn: 1, message: "go")
    st.turn_context = { delegation_depth: 0 }
    st
  end

  # Drives child + delivery fibers to completion. In non-serving mode the child is
  # parented at the current fiber, so Sync's structured concurrency already awaits
  # it (and its delivery grandchild); the drain loop is a belt for any stragglers.
  def dispatch(executor, child_answer: "child answer", raise_child: nil)
    # key on the profile: only the CHILD (researcher) turn should fail; the parent
    # DELIVERY turn must still run to persist the error note.
    allow(executor).to receive(:create_chat) do |profile, _state|
      raise(*raise_child) if raise_child && profile.id == "researcher"

      FakeChat.new.tap { |c| c.final_content = child_answer }
    end
    result = nil
    Sync do
      result = executor.run_subagent(agent: "researcher", message: "deep task", parent_state: parent_state, async: true)
      running = executor.instance_variable_get(:@running)
      20.times { break if running.empty?; running.values.each(&:wait) }
    end
    result
  end

  describe "dispatch" do
    it "returns the ack immediately (not the result) and records a Delegation" do
      executor = build_executor
      result = dispatch(executor)

      expect(result).to include(:dispatched, agent: "researcher")
      expect(result[:session_id]).to start_with("sub-")
      d = delegation_store.undelivered.first || delegation_store.find_by_child_task(result[:dispatched])
      expect(d.child_agent).to eq("researcher")
    end

    it "falls back to SYNC when no delegation_store is wired (async off — parity)" do
      executor = build_executor(delegation: nil)
      allow(executor).to receive(:create_chat).and_return(FakeChat.new.tap { |c| c.final_content = "sync answer" })
      result = nil
      Sync { result = executor.run_subagent(agent: "researcher", message: "t", parent_state: parent_state, async: true) }
      expect(result).to include(text: "sync answer") # blocked + returned the result
      expect(result).not_to have_key(:dispatched)
    end
  end

  describe "delivery as a NEW turn on the parent session" do
    it "delivers the child result to the parent session and marks the delegation delivered" do
      executor = build_executor
      result = dispatch(executor, child_answer: "the finding")

      # the parent session received a NEW turn whose USER message carries the result
      msgs = session_store.find("parent-sess").messages
      user_msg = msgs.find { |m| m["role"] == "user" }
      expect(user_msg["content"]).to include("[subagent:researcher]").and include("the finding")

      d = delegation_store.find_by_child_task(result[:dispatched])
      expect(d.status).to eq(:delivered)
      expect(event_stream.types).to include(:subagent_delivered)
    end

    it "delivers an ERROR note when the child turn fails" do
      executor = build_executor
      dispatch(executor, raise_child: [Harness::ProviderError, "provider down"])

      user_msg = session_store.find("parent-sess").messages.find { |m| m["role"] == "user" }
      expect(user_msg["content"]).to include("FAILED").and include("provider down")
    end
  end

  describe "at-most-once (the claim)" do
    it "a second finalize does NOT deliver again" do
      executor = build_executor
      result = dispatch(executor)
      before = session_store.find("parent-sess").messages.size

      Sync { executor.send(:finalize_delegation, result[:dispatched]) } # idempotent
      expect(session_store.find("parent-sess").messages.size).to eq(before)
    end
  end

  describe "boot recovery (recover_delegations)" do
    it "re-delivers a completed-but-undelivered delegation after a crash" do
      executor = build_executor
      # Simulate a crash AFTER the child completed and its result was captured, but
      # BEFORE delivery: a completed, unclaimed delegation whose child task is terminal.
      session_store.create(id: "parent-sess")
      session_store.create(id: "sub-x")
      d = delegation_store.create(parent_task_id: "pt", parent_session_id: "parent-sess",
                                  parent_agent: "parent", child_agent: "researcher",
                                  child_task_id: "ct-x", child_session_id: "sub-x", depth: 1)
      delegation_store.mark_completed(d.id, result: "recovered result")
      # a real async child carries its delegation_id in the command payload.
      task_store.create(command: Harness::Command.build(:send_message,
                                                        { agent: "researcher", message: "t",
                                                          session_id: "sub-x", delegation_id: d.id }).to_h,
                        session_id: "sub-x", id: "ct-x")
      task_store.transition("ct-x", to: :running)
      task_store.transition("ct-x", to: :completed)

      allow(executor).to receive(:create_chat).and_return(FakeChat.new)
      summary = nil
      Sync do
        summary = executor.recover_delegations
        running = executor.instance_variable_get(:@running)
        20.times { break if running.empty?; running.values.each(&:wait) }
      end

      expect(summary[:delivered]).to include(d.id)
      expect(delegation_store.find(d.id).status).to eq(:delivered)
      user_msg = session_store.find("parent-sess").messages.find { |m| m["role"] == "user" }
      expect(user_msg["content"]).to include("recovered result")
    end

    it "leaves a delegation whose child is still running (the task Recovery will resume it)" do
      executor = build_executor
      task_store.create(command: Harness::Command.build(:send_message, { agent: "researcher", message: "t" }).to_h,
                        session_id: "sub-y", id: "ct-y")
      task_store.transition("ct-y", to: :running) # NOT terminal
      d = delegation_store.create(parent_task_id: "pt", parent_session_id: "parent-sess",
                                  parent_agent: "parent", child_agent: "researcher",
                                  child_task_id: "ct-y", child_session_id: "sub-y", depth: 1)

      summary = executor.recover_delegations
      expect(summary[:delivered]).to be_empty
      expect(delegation_store.find(d.id).status).to eq(:dispatched) # untouched
    end

    it "is a no-op without a delegation_store" do
      expect(build_executor(delegation: nil).recover_delegations).to eq({ delivered: [] })
    end
  end
end
