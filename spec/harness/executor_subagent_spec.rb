# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0010 (item 21): Executor#run_subagent spawns an ISOLATED child turn inside
# the parent's fiber and returns its result. These are integration specs — a real
# Executor drives a real child turn through the pipeline with a FakeChat.
RSpec.describe "Harness::Executor#run_subagent (RFC-0010)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }

  let(:child_profile) { Harness::AgentProfile.build(id: "researcher", model: "gpt", base_prompt: "CHILD") }
  let(:parent_profile) do
    Harness::AgentProfile.build(id: "parent", model: "parent-model", base_prompt: "PARENT",
                                subagents: ["researcher"])
  end

  def build_executor(profiles:)
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  # A parent TurnState with the fields run_subagent reads (profile/task/turn_context/
  # model_selection). The parent task/session exist so the linkage + events are real.
  def parent_state(model_selection: nil, depth: 0, subagents: parent_profile)
    session_store.create(id: "parent-sess")
    cmd = Harness::Command.build(:send_message, { agent: "parent", message: "go" }).to_h
    task = task_store.create(command: cmd, session_id: "parent-sess", id: "parent-task")
    st = Harness::TurnState.new(task: task, profile: subagents, turn: 1, message: "go")
    st.turn_context = { delegation_depth: depth }
    st.model_selection = model_selection
    st
  end

  def find_task_by_session(sid)
    id = task_store.each_id.find { |tid| task_store.find(tid).session_id == sid }
    id && task_store.find(id)
  end

  # Runs run_subagent with the child's chat stubbed to yield `child_answer`.
  def delegate(executor, agent:, message: "task", ps: nil, child_answer: "child answer")
    ps ||= parent_state
    child_chat = FakeChat.new.tap { |c| c.final_content = child_answer }
    allow(executor).to receive(:create_chat).and_return(child_chat)
    result = nil
    Sync { result = executor.run_subagent(agent: agent, message: message, parent_state: ps) }
    result
  end

  describe "the happy path" do
    it "runs the child turn and returns its text + linked child session id" do
      executor = build_executor(profiles: { "researcher" => child_profile })

      result = delegate(executor, agent: "researcher")

      expect(result[:text]).to eq("child answer")
      expect(result[:session_id]).to start_with("sub-")
    end

    it "isolates the child in its OWN session (the parent session is untouched)" do
      executor = build_executor(profiles: { "researcher" => child_profile })

      result = delegate(executor, agent: "researcher", message: "find X")

      child = session_store.find(result[:session_id])
      expect(child.messages.map { |m| m["content"] }).to eq(["find X", "child answer"])
      # the parent session got nothing from the child (isolation)
      expect(session_store.find("parent-sess").messages).to eq([])
    end

    it "links the child session back to the parent (auditable lineage)" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      result = delegate(executor, agent: "researcher")
      child = session_store.find(result[:session_id])
      expect(child.vars).to include("parent_session_id" => "parent-sess",
                                    "parent_task_id" => "parent-task", "delegation_depth" => 1)
    end

    it "emits :subagent_started and :subagent_completed correlated to the PARENT task" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      delegate(executor, agent: "researcher")

      started = event_stream.events.find { |e| e.type == :subagent_started }
      completed = event_stream.events.find { |e| e.type == :subagent_completed }
      expect(started.data).to include(agent: "researcher", parent_task_id: "parent-task", depth: 1)
      expect(started.meta[:task_id]).to eq("parent-task")
      expect(completed.data).to include(agent: "researcher", state: "completed")
    end
  end

  describe "R1 — capacity never inherits (the gate is the parent's allowlist)" do
    it "refuses an agent NOT in parent.subagents" do
      executor = build_executor(profiles: { "researcher" => child_profile,
                                            "other" => Harness::AgentProfile.build(id: "other", model: "m") })
      result = delegate(executor, agent: "other")
      expect(result[:error]).to match(/not in this agent's subagents allowlist/)
    end

    it "refuses an unknown agent" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      ps = parent_state(subagents: Harness::AgentProfile.build(id: "parent", subagents: ["ghost"]))
      result = delegate(executor, agent: "ghost", ps: ps)
      expect(result[:error]).to match(/not configured/)
    end
  end

  describe "R2 — environment (model/thinking) inherits as default" do
    it "seeds the child model from the parent's resolved selection when the child omits it" do
      childless_model = Harness::AgentProfile.build(id: "researcher", base_prompt: "CHILD") # no model
      executor = build_executor(profiles: { "researcher" => childless_model })
      captured = nil
      allow(executor).to receive(:create_chat) do |profile, _state|
        captured = profile
        FakeChat.new.tap { |c| c.final_content = "ok" }
      end
      sel = Harness::ModelSelection.new(model: "inherited-model", provider: :deepseek,
                                        params: { thinking: "off" })
      Sync { executor.run_subagent(agent: "researcher", message: "t", parent_state: parent_state(model_selection: sel)) }

      expect(captured.model).to eq("inherited-model")
      expect(captured.params["thinking"]).to eq("off")
    end

    it "does NOT override a model the child set explicitly" do
      executor = build_executor(profiles: { "researcher" => child_profile }) # model 'gpt'
      captured = nil
      allow(executor).to receive(:create_chat) do |profile, _state|
        captured = profile
        FakeChat.new.tap { |c| c.final_content = "ok" }
      end
      sel = Harness::ModelSelection.new(model: "inherited-model")
      Sync { executor.run_subagent(agent: "researcher", message: "t", parent_state: parent_state(model_selection: sel)) }

      expect(captured.model).to eq("gpt")
    end
  end

  describe "R5 — runtime depth guard" do
    it "refuses when the incremented depth would exceed the cap" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      cap = Harness::SubagentGraph.depth_cap
      result = delegate(executor, agent: "researcher", ps: parent_state(depth: cap))
      expect(result[:error]).to match(/exceeds cap #{cap}/)
    end

    it "stamps depth+1 into the child so a grandchild sees the incremented value" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      result = delegate(executor, agent: "researcher", ps: parent_state(depth: 2))
      child_task = find_task_by_session(result[:session_id])
      expect(child_task.command["payload"]["delegation_depth"]).to eq(3)
    end
  end

  describe "#run_subagents — parallel fan-out (RFC-0010 §A)" do
    it "runs N children and returns all results in the requested order" do
      writer = Harness::AgentProfile.build(id: "writer", model: "gpt")
      executor = build_executor(profiles: { "researcher" => child_profile, "writer" => writer })
      # each child gets a distinct answer keyed by its agent id
      allow(executor).to receive(:create_chat) do |profile, _state|
        FakeChat.new.tap { |c| c.final_content = "answer:#{profile.id}" }
      end
      ps = parent_state(subagents: Harness::AgentProfile.build(id: "parent", subagents: %w[researcher writer]))

      result = nil
      Sync { result = executor.run_subagents(tasks: [{ "agent" => "researcher", "message" => "a" },
                                                      { "agent" => "writer", "message" => "b" }], parent_state: ps) }

      expect(result[:results].map { |r| r[:text] }).to eq(["answer:researcher", "answer:writer"])
      expect(result[:results].map { |r| r[:session_id] }).to all(start_with("sub-"))
    end

    it "keeps a per-task error in its ordered slot (a bad task does not sink the batch)" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      allow(executor).to receive(:create_chat).and_return(FakeChat.new.tap { |c| c.final_content = "ok" })
      ps = parent_state

      result = nil
      Sync { result = executor.run_subagents(tasks: [{ "agent" => "researcher", "message" => "a" },
                                                     { "agent" => "ghost", "message" => "b" }], parent_state: ps) }

      expect(result[:results][0]).to include(text: "ok", agent: "researcher")
      expect(result[:results][1]).to include(agent: "ghost")
      expect(result[:results][1][:error]).to match(/not in this agent's subagents allowlist/)
    end

    it "rejects a fan-out larger than the cap" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      cap = Harness::SubagentGraph.fan_out_cap
      tasks = Array.new(cap + 1) { { "agent" => "researcher", "message" => "x" } }
      result = executor.run_subagents(tasks: tasks, parent_state: parent_state)
      expect(result[:error]).to match(/too many subagents/)
    end

    it "rejects an empty list" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      expect(executor.run_subagents(tasks: [], parent_state: parent_state)[:error]).to match(/non-empty/)
    end
  end

  describe "child failure" do
    it "returns { error: } carrying the child's terminal error, never raising" do
      executor = build_executor(profiles: { "researcher" => child_profile })
      # child turn fails inside the pipeline (create_chat raises a ProviderError).
      allow(executor).to receive(:create_chat).and_raise(Harness::ProviderError, "boom")
      result = nil
      Sync { result = executor.run_subagent(agent: "researcher", message: "t", parent_state: parent_state) }
      expect(result[:error]).to match(/subagent 'researcher' failed: boom/)
      expect(event_stream.events.find { |e| e.type == :subagent_completed }.data[:state]).to eq("failed")
    end
  end
end
