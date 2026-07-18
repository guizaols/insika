# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::SendMessage do
  subject(:handler) do
    described_class.new(profiles: profiles, session_store: session_store,
                        task_store: task_store, executor: executor)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt") }
  let(:profiles) { { "sales" => profile } }

  # Executor double that only records the spawn (the real fiber is the integration).
  let(:executor) do
    Class.new do
      attr_reader :spawned

      def initialize = (@spawned = [])
      def spawn_in_session(task, profile:, resume_from: nil) = @spawned << [task, profile]
    end.new
  end

  def payload(**over)
    { agent: "sales", message: "oi" }.merge(over)
  end

  it "happy path: creates a :queued Task with a persisted command, spawns and returns {task_id:}" do
    session = session_store.create(id: "s1")
    result = handler.call(Harness::Command.build(:send_message, payload(session_id: session.id)))

    expect(result).to match({ task_id: kind_of(String) })
    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:queued)
    expect(task.command["type"]).to eq("send_message")
    expect(task.session_id).to eq("s1")
    expect(executor.spawned.size).to eq(1)
    expect(executor.spawned.first.last).to be(profile)
  end

  it "XOR D2: session_id + history -> ValidationError, no Task created" do
    session_store.create(id: "s1")

    expect do
      handler.call(Harness::Command.build(:send_message,
                                          payload(session_id: "s1", history: [{ role: "user", content: "x" }])))
    end.to raise_error(Harness::ValidationError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "nonexistent agent -> NotFoundError" do
    expect { handler.call(Harness::Command.build(:send_message, payload(agent: "ghost"))) }
      .to raise_error(Harness::NotFoundError)
  end

  it "missing or empty agent/message -> ValidationError" do
    [payload(agent: ""), payload(agent: nil), payload(message: ""), payload(message: "   ")].each do |pl|
      expect { handler.call(Harness::Command.build(:send_message, pl)) }
        .to raise_error(Harness::ValidationError)
    end
  end

  it "nonexistent session -> NotFoundError, no Task" do
    expect { handler.call(Harness::Command.build(:send_message, payload(session_id: "ghost"))) }
      .to raise_error(Harness::NotFoundError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "malformed history -> ValidationError" do
    expect { handler.call(Harness::Command.build(:send_message, payload(history: [{ foo: 1 }]))) }
      .to raise_error(Harness::ValidationError)
  end

  it "one-shot (without session_id/history): Task with session_id nil" do
    result = handler.call(Harness::Command.build(:send_message, payload))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
  end

  it "valid history (without session): spawns, Task without session_id" do
    result = handler.call(Harness::Command.build(:send_message,
                                                 payload(history: [{ role: "user", content: "oi" }])))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
    expect(executor.spawned.size).to eq(1)
  end
end
