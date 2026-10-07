# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'Required shared conversation persistence' do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:checkpoints) { Insika::CheckpointStore.new(store: backend) }
  let(:events) { SpyEventStream.new }
  let(:bridge) { double('shared conversations') }
  let(:chat) { FakeChat.new }
  let(:profile) { Insika::AgentProfile.build(id: 'synthetic', model: 'fake', shared_conversations: true) }
  let(:executor) do
    Insika::Executor.new(context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new, tool_registry: FakeToolRegistry.new,
      skill_catalog: Insika::SkillCatalog.new([]), profiles: {}, session_store: sessions,
      task_store: tasks, checkpoint_store: checkpoints, event_stream: events, shared_conversations: bridge)
  end
  let(:task) do
    sessions.create(id: 'synthetic')
    command = Insika::Command.build(:send_message, { agent: 'synthetic', message: 'hello' })
    tasks.create(command: command.to_h, session_id: 'synthetic', id: 'synthetic-turn')
  end
  before { allow(bridge).to receive(:input_attachments).and_return([]) }
  def run_turn
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  it 'fails admission before context building or any model work' do
    expect(bridge).to receive(:begin_turn).with(task: task, profile: profile).and_raise(Insika::StoreError, 'central unavailable')
    expect(executor).not_to receive(:create_chat)
    run_turn
    expect(tasks.find(task.id).status).to eq(:failed)
    expect(events.types & %i[content task_completed]).to eq([])
  end

  it 'withholds answer and channel delivery on a failed required completion' do
    allow(bridge).to receive(:begin_turn).and_return([])
    allow(executor).to receive(:create_chat).and_return(chat)
    expect(bridge).to receive(:complete) do |**args|
      expect(checkpoints.latest(task.id)).not_to be_nil
      raise Insika::StoreError, 'central unavailable'
    end
    expect(executor).not_to receive(:finalize_channel_delivery)
    run_turn
    expect(tasks.find(task.id).status).to eq(:failed)
    expect(events.types & %i[content task_completed]).to eq([])
  end

  it 'publishes only the final accepted text after the central acknowledgment' do
    allow(bridge).to receive(:begin_turn).and_return([])
    allow(executor).to receive(:create_chat).and_return(chat)
    expect(bridge).to receive(:complete) do |**args|
      expect(events.types).not_to include(:content, :task_completed)
      expect(args.fetch(:messages).last.fetch('role')).to eq('assistant')
    end
    run_turn
    expect(tasks.find(task.id).status).to eq(:completed)
    expect(events.types.count(:content)).to eq(1)
  end

  it 'returns a recovered accepted answer without creating a chat' do
    allow(bridge).to receive(:begin_turn).and_raise(Insika::SharedConversations::Recovered.new('recorded answer'))
    expect(executor).not_to receive(:create_chat)
    run_turn
    expect(tasks.find(task.id).status).to eq(:completed)
    expect(events.types).to include(:content, :task_completed)
  end

  it 'keeps native mode independent when the profile is off' do
    allow(executor).to receive(:create_chat).and_return(chat)
    expect(bridge).not_to receive(:begin_turn)
    expect(bridge).not_to receive(:complete)
    run_profile = profile.with(shared_conversations: false)
    Sync do
      executor.spawn(task, profile: run_profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
    expect(tasks.find(task.id).status).to eq(:completed)
    expect(events.types).to include(:content, :task_completed)
  end
  it 'fails closed on shared memory outage before reserving or invoking the model' do
    expect(bridge).to receive(:memory_context).and_raise(Insika::StoreError, 'memory unavailable')
    expect(bridge).not_to receive(:begin_turn)
    expect(executor).not_to receive(:create_chat)
    Sync do
      executor.spawn(task, profile: profile.with(memory:true))
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
    expect(tasks.find(task.id).status).to eq(:failed)
    expect(events.types & %i[content task_completed]).to eq([])
  end

end
