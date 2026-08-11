# frozen_string_literal: true

require "spec_helper"
require "async"

# 03 (criterion): two concurrent send_message on the SAME session
# are SERIALIZED by the SessionActor — the transcript stays consistent (FIFO, without
# the read-modify-write clobber that would occur with two fibers on the same
# session_id). Distinct sessions remain concurrent.
RSpec.describe "Integration: per-session turn serialization (03)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "sales" => profile }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end
  let(:bus) { Insika::CommandBus.new }
  let(:handler) do
    Insika::Commands::SendMessage.new(profiles: { "sales" => profile },
                                       session_store: session_store, task_store: task_store,
                                       executor: executor)
  end

  before do
    bus.register(:send_message, handler)
    # each turn responds "ok:<message>" (distinguishes turns in the transcript)
    allow(executor).to receive(:create_chat) do
      chat = FakeChat.new
      chat.script = proc { |*| chat.instance_variable_set(:@final_content, "ok:#{@asked}") }
      chat
    end
  end

  TERMINAL = %w[completed failed cancelled].freeze

  def wait_terminal(parent, *task_ids)
    200.times do
      break if task_ids.all? { |id| (t = task_store.find(id)) && TERMINAL.include?(t.status.to_s) }

      parent.sleep(0.005)
    end
  end

  def dispatch(message, session_id:)
    bus.dispatch(Insika::Command.build(:send_message, { agent: "sales", message: message, session_id: session_id }))
  end

  it "two concurrent turns on the SAME session: FIFO transcript, no clobber" do
    session_store.create(id: "s1")

    Sync do |parent|
      executor.supervised = true # SessionActor only serializes in serving mode
      r1 = dispatch("a", session_id: "s1")
      r2 = dispatch("b", session_id: "s1")
      expect(r1[:task_id]).not_to eq(r2[:task_id]) # two distinct turns, immediate 202 for both
      wait_terminal(parent, r1[:task_id], r2[:task_id])
      executor.stop_session_actors
      executor.instance_variable_get(:@supervisor)&.stop
    end

    contents = session_store.find("s1").messages.map { |m| m["content"] }
    # 4 messages, in ARRIVAL order — nothing lost/interleaved
    expect(contents).to eq(["a", "ok:a", "b", "ok:b"])
  end

  it "DISTINCT sessions do not block each other (concurrency preserved)" do
    session_store.create(id: "s1")
    session_store.create(id: "s2")

    Sync do |parent|
      executor.supervised = true
      r1 = dispatch("a", session_id: "s1")
      r2 = dispatch("b", session_id: "s2")
      wait_terminal(parent, r1[:task_id], r2[:task_id])
      executor.stop_session_actors
      executor.instance_variable_get(:@supervisor)&.stop
    end

    expect(session_store.find("s1").messages.map { |m| m["content"] }).to eq(["a", "ok:a"])
    expect(session_store.find("s2").messages.map { |m| m["content"] }).to eq(["b", "ok:b"])
  end
end
