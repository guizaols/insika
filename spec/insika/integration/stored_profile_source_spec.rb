# frozen_string_literal: true

require "spec_helper"

# (criterion): the runtime consumes DYNAMIC profiles.
# A profile created at runtime in the ConfigStore is resolved by a turn
# Command via StoredProfileSource — no frozen Hash, no restart.
RSpec.describe "Integration: turn with StoredProfileSource" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }

  # Records the spawn and declines the doors — what matters here is the PROFILE
  # the Command resolved and handed over.
  let(:executor) { FakeTurnExecutor.new }

  let(:handler) do
    Insika::Commands::SendMessage.new(
      profiles: profiles, session_store: session_store, task_store: task_store, executor: executor
    )
  end

  it "resolves a freshly created profile in the ConfigStore (dynamic, no frozen Hash)" do
    # no agent yet -> NotFoundError
    expect do
      handler.call(Insika::Command.build(:send_message, { agent: "bia", message: "oi" }))
    end.to raise_error(Insika::NotFoundError)

    # creates the agent at RUNTIME (what the Studio will do via :create_agent)
    profiles.put(Insika::AgentProfile.build(id: "bia", model: "deepseek-chat", provider: :deepseek))

    res = handler.call(Insika::Command.build(:send_message, { agent: "bia", message: "oi" }))
    expect(res[:task_id]).to be_a(String)
    spawned_profile = executor.spawned.last.last
    expect(spawned_profile.id).to eq("bia")
    expect(spawned_profile.provider).to eq(:deepseek) # round-trip preserved on the real path
  end
end
