# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::SendMessage do
  subject(:handler) do
    described_class.new(profiles: profiles, session_store: session_store,
                        task_store: task_store, executor: executor)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt") }
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
    result = handler.call(Insika::Command.build(:send_message, payload(session_id: session.id)))

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
      handler.call(Insika::Command.build(:send_message,
                                          payload(session_id: "s1", history: [{ role: "user", content: "x" }])))
    end.to raise_error(Insika::ValidationError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "nonexistent agent -> NotFoundError" do
    expect { handler.call(Insika::Command.build(:send_message, payload(agent: "ghost"))) }
      .to raise_error(Insika::NotFoundError)
  end

  it "missing or empty agent/message -> ValidationError" do
    [payload(agent: ""), payload(agent: nil), payload(message: ""), payload(message: "   ")].each do |pl|
      expect { handler.call(Insika::Command.build(:send_message, pl)) }
        .to raise_error(Insika::ValidationError)
    end
  end

  it "nonexistent session -> NotFoundError, no Task" do
    expect { handler.call(Insika::Command.build(:send_message, payload(session_id: "ghost"))) }
      .to raise_error(Insika::NotFoundError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "malformed history -> ValidationError" do
    expect { handler.call(Insika::Command.build(:send_message, payload(history: [{ foo: 1 }]))) }
      .to raise_error(Insika::ValidationError)
  end

  it "one-shot (without session_id/history): Task with session_id nil" do
    result = handler.call(Insika::Command.build(:send_message, payload))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
  end

  it "valid history (without session): spawns, Task without session_id" do
    result = handler.call(Insika::Command.build(:send_message,
                                                 payload(history: [{ role: "user", content: "oi" }])))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
    expect(executor.spawned.size).to eq(1)
  end

  describe "RFC-0015 §5.5 — coalescing is offered only where `merged` can be reported" do
    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: collecting_executor)
    end

    # Accepts every fragment, so any call that reaches it merges.
    let(:collecting_executor) do
      Class.new do
        attr_reader :spawned, :asked

        def initialize
          @spawned = []
          @asked = []
        end

        def spawn_in_session(task, profile:, resume_from: nil) = @spawned << [task, profile]

        def collect_into_pending(session_id, text, profile:)
          @asked << [session_id, text]
          "t-open"
        end

        # Never reached in this group: a turn is either at the door or running.
        def steer_into_running(_session_id, _text, profile:) = nil
      end.new
    end

    def send_from(transport, **over)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1", **over),
                                          transport: transport))
    end

    it "http:json (the aggregated form) coalesces and reports the turn it joined" do
      result = send_from(:"http:json")

      expect(result).to eq({ task_id: "t-open", merged: true })
      expect(collecting_executor.spawned).to be_empty   # no turn of its own
      expect(task_store.each_id.to_a).to be_empty       # and NO orphan :queued task
    end

    it "a channel surface coalesces too (RFC-0011 §6.2 defines the field)" do
      expect(send_from(:"channel:relay")).to eq({ task_id: "t-open", merged: true })
    end

    it "/v1/responses (plain :http) does NOT coalesce — its body cannot carry the verdict" do
      result = send_from(:http)

      expect(result).to match({ task_id: kind_of(String) })
      expect(collecting_executor.asked).to be_empty     # the door was never even opened
      expect(collecting_executor.spawned.size).to eq(1) # a turn of its own, as before
    end

    it "an internal caller (subagent delivery, tests) does not coalesce" do
      expect(send_from(:internal)).to match({ task_id: kind_of(String) })
      expect(collecting_executor.asked).to be_empty
    end

    it "validation still runs BEFORE the door: a bad message never reaches collect" do
      session_store.create(id: "s1")

      expect do
        handler.call(Insika::Command.build(:send_message, payload(session_id: "s1", message: "  "),
                                            transport: :"http:json"))
      end.to raise_error(Insika::ValidationError)
      expect(collecting_executor.asked).to be_empty
    end

    it "no pending turn to join -> the ordinary path, with a real task" do
      declining = Class.new do
        attr_reader :spawned

        def initialize = (@spawned = [])
        def spawn_in_session(task, profile:, resume_from: nil) = @spawned << task
        def collect_into_pending(_session_id, _text, profile:) = nil
        def steer_into_running(_session_id, _text, profile:) = nil
      end.new
      session_store.create(id: "s1")

      result = described_class.new(profiles: profiles, session_store: session_store,
                                   task_store: task_store, executor: declining)
                              .call(Insika::Command.build(:send_message, payload(session_id: "s1"),
                                                           transport: :"http:json"))

      expect(result).to match({ task_id: kind_of(String) })
      expect(declining.spawned.size).to eq(1)
    end
  end

  describe "RFC-0015 §5.1 — steering a turn that is already running" do
    # No turn at the door (collect declines), one running (steer accepts).
    let(:steering_executor) do
      Class.new do
        attr_reader :spawned, :asked

        def initialize
          @spawned = []
          @asked = []
        end

        def spawn_in_session(task, profile:, resume_from: nil) = @spawned << [task, profile]
        def collect_into_pending(_session_id, _text, profile:) = nil

        def steer_into_running(session_id, text, profile:)
          @asked << [session_id, text]
          "t-running"
        end
      end.new
    end

    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: steering_executor)
    end

    def send_from(transport)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1"), transport: transport))
    end

    it "answers with the RUNNING turn's id and says the caller does not own the reply" do
      result = send_from(:"http:json")

      expect(result).to eq({ task_id: "t-running", steered: true })
      expect(steering_executor.spawned).to be_empty # no turn of its own
      expect(task_store.each_id.to_a).to be_empty   # and no task at all
    end

    it "is refused on a surface that cannot carry the verdict, exactly like collect" do
      result = send_from(:http)

      expect(result).to match({ task_id: kind_of(String) })
      expect(steering_executor.asked).to be_empty
      expect(steering_executor.spawned.size).to eq(1)
    end
  end
end
