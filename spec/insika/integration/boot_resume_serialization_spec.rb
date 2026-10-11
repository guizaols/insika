# frozen_string_literal: true

require "spec_helper"
require "async"

# The serving boot order, as config.ru runs it: Falcon loads config.ru INSIDE
# the worker's live reactor, so Server::Boot's recovery only DISPATCHES the
# resumed turns (no Sync wait) and the listen follows right away. A message that
# arrives for the same session while the resumed turn is still running must
# queue behind it — the SessionActor's FIFO — not run beside it.
RSpec.describe "Integration: a resumed turn and a new turn on the same session" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }
  let(:profiles) { { "sales" => profile } }

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: Insika::EventStream.new
    )
  end
  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:resume_task, Insika::Commands::ResumeTask.new(
                                 profiles: profiles, task_store: task_store,
                                 checkpoint_store: checkpoint_store, executor: executor
                               ))
      b.register(:send_message, Insika::Commands::SendMessage.new(
                                  profiles: profiles, session_store: session_store,
                                  task_store: task_store, executor: executor
                                ))
    end
  end

  TERMINAL = %w[completed failed cancelled].freeze

  it "the new turn starts only after the resumed one finishes" do
    session_store.create(id: "s1")
    # A turn left :queued by the previous process (its SessionActor queue died with it).
    command = Insika::Command.build(:send_message, { agent: "sales", message: "a", session_id: "s1" })
    task_store.create(command: command.to_h, session_id: "s1", id: "resumed")

    log = []
    allow(executor).to receive(:create_chat) do
      chat = FakeChat.new
      chat.script = proc do
        log << [:start, @asked]
        Async::Task.current.sleep(0.05) # the resumed turn is still running when "b" lands
        log << [:end, @asked]
      end
      chat
    end

    Sync do |parent|
      # config.ru order: serving mode, then recovery, then traffic.
      executor.supervised = true
      executor.start_supervisor!
      Insika::Recovery.new(task_store: task_store, checkpoint_store: checkpoint_store,
                           command_bus: bus).run
      fresh = bus.dispatch(Insika::Command.build(:send_message,
                                                 { agent: "sales", message: "b", session_id: "s1" }))

      400.times do
        break if ["resumed", fresh[:task_id]].all? { |id| TERMINAL.include?(task_store.find(id).status.to_s) }

        parent.sleep(0.005)
      end
      executor.stop_session_actors
      executor.instance_variable_get(:@supervisor)&.stop
    end

    expect(log.map(&:first)).to eq(%i[start end start end]), "turns overlapped: #{log.inspect}"
  end
end
