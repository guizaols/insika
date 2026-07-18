# frozen_string_literal: true

require "spec_helper"

# Phase 4 D2 (Stage A criterion): the runtime consumes DYNAMIC profiles.
# A profile created at runtime in the ConfigStore is resolved by a turn
# Command via StoredProfileSource — no frozen Hash, no restart.
RSpec.describe "Integration: turn with StoredProfileSource (Phase 4 D2)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:config_store) { Harness::ConfigStore.new(store: backend) }
  let(:profiles) { Harness::StoredProfileSource.new(config_store: config_store) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:session_store) { Harness::SessionStore.new(store: backend) }

  # Executor double: only records the profile the Command resolved and passed to spawn.
  let(:executor) do
    Class.new do
      attr_reader :spawned
      def spawn_in_session(task, profile:, resume_from: nil) = (@spawned = profile; task.id)
    end.new
  end

  let(:handler) do
    Harness::Commands::SendMessage.new(
      profiles: profiles, session_store: session_store, task_store: task_store, executor: executor
    )
  end

  it "resolves a freshly created profile in the ConfigStore (dynamic, no frozen Hash)" do
    # no agent yet -> NotFoundError
    expect do
      handler.call(Harness::Command.build(:send_message, { agent: "bia", message: "oi" }))
    end.to raise_error(Harness::NotFoundError)

    # creates the agent at RUNTIME (what the Studio will do via :create_agent)
    profiles.put(Harness::AgentProfile.build(id: "bia", model: "deepseek-chat", provider: :deepseek))

    res = handler.call(Harness::Command.build(:send_message, { agent: "bia", message: "oi" }))
    expect(res[:task_id]).to be_a(String)
    expect(executor.spawned.id).to eq("bia")
    expect(executor.spawned.provider).to eq(:deepseek) # round-trip preserved on the real path
  end
end
