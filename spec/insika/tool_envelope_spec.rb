# frozen_string_literal: true

require "spec_helper"
require "async"

# Characterization of the ToolEnvelope hot path (FOLLOWUP §11 R0): the branches
# the approval spec does NOT exercise — per-call timeout serialization, skip-on-resume,
# side-effect recording, and call correlation. LOCKS current behavior BEFORE R1
# (persisting tool calls/results) and the future R4 (parallel tools) touch it.
RSpec.describe Insika::ToolEnvelope do
  let(:backend) { Insika::Stores::Memory.new }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }

  # Tool fakes named to avoid collision with the approval spec's ChargeTool.
  # Each records its calls so we can assert (non-)execution.
  class EnvEchoTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "echo"
    def call(args) = (@calls << args) && "echoed"
  end

  # Sleeps on the reactor so ToolEnvelope's with_timeout can fire. A plain
  # Kernel#sleep would block the reactor and the timer would never run.
  class EnvSleepyTool
    attr_reader :calls

    def initialize = (@calls = [])
    def name = "slow"

    def call(args)
      @calls << args
      Async::Task.current.sleep(1)
      "done"
    end
  end

  # Delegate exposing impl_name: the envelope must resolve side_effect?/correlation
  # against the REAL registered name, not a capability alias.
  class EnvAliasTool
    def name = "capability_alias"
    def impl_name = "real_tool"
    def call(_args) = "ran"
  end

  def state_for(task_id: "t", session_id: nil, turn: 1, current_tool_call: nil)
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    task = Struct.new(:id, :session_id).new(task_id, session_id)
    st = Insika::TurnState.new(task: task, profile: profile, turn: turn, message: "oi")
    st.requires_approval = []
    st.current_tool_call = current_tool_call
    st
  end

  def envelope(tool, state, timeout: 60, skip_side_effects: [], tool_registry: FakeToolRegistry.new,
               trace_recorder: nil)
    described_class.new(tool, state: state, checkpoint_store: checkpoint_store,
                              tool_registry: tool_registry, timeout: timeout,
                              skip_side_effects: skip_side_effects, trace_recorder: trace_recorder)
  end

  describe "per-call timeout" do
    it "timeout fired -> returns a serialized error to the model, does NOT propagate (the turn continues)" do
      tool = EnvSleepyTool.new
      env = envelope(tool, state_for, timeout: 0.01)

      result = Sync { env.call({ "x" => 1 }) }

      expect(result).to eq({ error: "TimeoutError: tool exceeded 0.01s" })
      expect(tool.calls).to eq([{ "x" => 1 }]) # the tool WAS entered; it was interrupted midway
    end

    it "timeout does NOT record a side-effect (recorded only after a successful return)" do
      registry = FakeToolRegistry.new(side_effect_names: ["slow"])
      state = state_for(current_tool_call: Struct.new(:id).new("call-1"))
      env = envelope(EnvSleepyTool.new, state, timeout: 0.01, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to be_empty
    end

    it "timeout is traced with ok=false when there is a trace_recorder" do
      recorder = Insika::ToolTraceStore.new(store: backend)
      env = envelope(EnvSleepyTool.new, state_for(session_id: "s"), timeout: 0.01,
                                                                    trace_recorder: recorder)

      Sync { env.call({}) }

      trace = recorder.for_session("s")
      expect(trace.size).to eq(1)
      expect(trace.first).to include("ok" => false, "tool" => "slow")
      expect(trace.first["result"]).to include("TimeoutError")
    end
  end

  describe "skip-on-resume (side-effect already executed in the interrupted turn)" do
    it "call_id in skip_side_effects -> {skipped} marker, does NOT re-execute the tool" do
      tool = EnvEchoTool.new
      state = state_for(current_tool_call: Struct.new(:id).new("call-42"))
      env = envelope(tool, state, skip_side_effects: ["call-42"])

      result = Sync { env.call({ "amount" => 10 }) }

      expect(result).to eq({ "skipped" => "already_executed" })
      expect(tool.calls).to be_empty
    end

    it "call_id ABSENT from the skip set -> executes normally" do
      tool = EnvEchoTool.new
      state = state_for(current_tool_call: Struct.new(:id).new("call-99"))
      env = envelope(tool, state, skip_side_effects: ["outro-id"])

      result = Sync { env.call({}) }

      expect(result).to eq("echoed")
      expect(tool.calls.size).to eq(1)
    end

    it "correlation by NAME (workflow, no provider id): skip is per-tool, not per-call" do
      tool = EnvEchoTool.new # current_tool_call nil -> correlation_id falls back to the name "echo"
      env = envelope(tool, state_for, skip_side_effects: ["echo"])

      result = Sync { env.call({}) }

      expect(result).to eq({ "skipped" => "already_executed" })
      expect(tool.calls).to be_empty
    end
  end

  describe "record_side_effect! (records BEFORE the result returns to the model)" do
    it "tool marked as a side-effect -> records the correlation call_id in the checkpoint_store" do
      registry = FakeToolRegistry.new(side_effect_names: ["echo"])
      state = state_for(current_tool_call: Struct.new(:id).new("call-7"))
      env = envelope(EnvEchoTool.new, state, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["call-7"])
    end

    it "tool NOT marked -> records nothing" do
      state = state_for(current_tool_call: Struct.new(:id).new("call-7"))
      env = envelope(EnvEchoTool.new, state) # FakeToolRegistry without side_effect_names

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to be_empty
    end

    it "without current_tool_call, the side-effect is recorded by the tool's real NAME" do
      registry = FakeToolRegistry.new(side_effect_names: ["echo"])
      env = envelope(EnvEchoTool.new, state_for, tool_registry: registry)

      Sync { env.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["echo"])
    end
  end

  describe "impl_name (capability alias)" do
    it "resolves side_effect?/correlation against the real impl_name, not the alias" do
      registry = FakeToolRegistry.new(side_effect_names: ["real_tool"])
      env = envelope(EnvAliasTool.new, state_for, tool_registry: registry)

      result = Sync { env.call({}) }

      expect(result).to eq("ran")
      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["real_tool"])
    end
  end

  describe "delegation (SimpleDelegator)" do
    it "delegates name/description to the real tool" do
      env = envelope(EnvEchoTool.new, state_for)
      expect(env.name).to eq("echo")
    end
  end
end
