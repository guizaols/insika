# frozen_string_literal: true

require "spec_helper"
require "harness/tools/subagent" # the Executor loads it lazily in create_chat; explicit here

RSpec.describe Harness::Tools::Subagent do
  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:state) do
    profile = Harness::AgentProfile.build(id: "parent", model: "m", subagents: ["researcher"])
    Harness::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
  end

  # Captures the call and returns a canned result (the Executor is the real runner).
  def runner(result)
    Class.new do
      attr_reader :calls
      def initialize(result) = (@result = result; @calls = [])
      def run_subagent(**kw) = (@calls << kw; @result)
    end.new(result)
  end

  it "def name = 'spawn_subagent' (not the one derived from the class)" do
    expect(described_class.new(runner: runner({}), state: state).name).to eq("spawn_subagent")
  end

  it "delegates to run_subagent with agent/message/parent_state and returns {text, session_id}" do
    r = runner({ text: "child answer", session_id: "sub-1" })
    tool = described_class.new(runner: r, state: state)

    result = tool.execute(agent: "researcher", message: "find X")

    expect(result).to eq({ text: "child answer", session_id: "sub-1" })
    expect(r.calls).to eq([{ agent: "researcher", message: "find X", parent_state: state, async: false }])
  end

  it "async:true dispatches and returns the ack (result arrives later as a new turn)" do
    r = runner({ dispatched: "child-task-1", agent: "researcher", session_id: "sub-9" })
    result = described_class.new(runner: r, state: state).execute(agent: "researcher", message: "long job", async: true)

    expect(result).to eq({ dispatched: true, agent: "researcher", session_id: "sub-9" })
    expect(r.calls.first).to include(async: true)
  end

  it "coerces agent/message to strings before delegating" do
    r = runner({ text: "ok", session_id: "sub-2" })
    described_class.new(runner: r, state: state).execute(agent: :researcher, message: 42)
    expect(r.calls.first).to include(agent: "researcher", message: "42")
  end

  it "surfaces a runner error as { error: } (never raises — it is a message to the model)" do
    r = runner({ error: "agent 'x' not in allowlist" })
    result = described_class.new(runner: r, state: state).execute(agent: "x", message: "hi")
    expect(result).to eq({ error: "agent 'x' not in allowlist" })
  end
end
