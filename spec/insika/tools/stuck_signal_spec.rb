# frozen_string_literal: true

require "spec_helper"
require "insika/tools/stuck_signal" # the Executor loads it lazily; explicit in the test

RSpec.describe Insika::Tools::StuckSignal do
  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:profile) { Insika::AgentProfile.build(id: "a", model: "m", stuck_signal: true) }
  let(:state) { Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "oi") }

  def tool
    described_class.new(state: state)
  end

  it "def name = 'signal_stuck' (not one derived from the class)" do
    expect(tool.name).to eq("signal_stuck")
  end

  it "records the stuck outcome on the state (reason + message)" do
    result = tool.execute(reason: "out of scope", message: "I'll transfer you")

    expect(state.stuck_outcome).to eq(reason: "out of scope", message: "I'll transfer you")
    expect(result).to be_a(::RubyLLM::Tool::Halt) # ends the tool loop there
  end

  it "a Halt with no custom say publishes no fallback (the model's lead-in wins)" do
    tool.execute(reason: "missing data")
    expect(state.stuck_outcome[:message]).to eq("")
  end

  it "stuck_outcome is nil before the tool runs (normal turn)" do
    expect(state.stuck_outcome).to be_nil
  end
end
