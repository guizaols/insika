# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::ResumeTask do
  subject(:handler) do
    described_class.new(profiles: profiles, task_store: task_store,
                        checkpoint_store: checkpoint_store, executor: executor)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt") }
  let(:profiles) { { "sales" => profile } }

  # Executor double with recordable running?/spawn/resume_live.
  let(:executor) do
    Class.new do
      attr_reader :spawned, :resumed_live
      attr_accessor :running

      def initialize = (@spawned = []; @resumed_live = []; @running = false)
      def running?(_id) = @running
      def spawn_in_session(task, profile:, resume_from: nil) = @spawned << { task: task, profile: profile, resume_from: resume_from }
      def resume_live(id) = @resumed_live << id
    end.new
  end

  # Creates a task in the target state (valid path) + optional checkpoint.
  def seed(id, status:, checkpoint: true, agent_id: "sales")
    task_store.create(command: { "type" => "send_message", "payload" => {} }, id: id)
    task_store.begin_execution(id)
    task_store.transition(id, to: :running)
    case status
    when :waiting then task_store.transition(id, to: :waiting)
    when :paused then task_store.transition(id, to: :paused)
    when :completed then (task_store.finish_execution(id, outcome: "ok"); task_store.transition(id, to: :completed))
    when :cancelled then task_store.transition(id, to: :cancelled)
    when :failed then task_store.transition(id, to: :failed, error: { class: "E", message: "m" })
    end
    if checkpoint
      checkpoint_store.save(Harness::Checkpoint.new(
                              task_id: id, turn: 1, session_id: nil, agent_id: agent_id,
                              messages: [], completed_side_effects: [], created_at: nil
                            ))
    end
    id
  end

  def resume(id)
    handler.call(Harness::Command.build(:resume_task, { task_id: id }))
  end

  it "paused WITHOUT a live fiber (crash): re-dispatches with resume_from = checkpoint" do
    seed("t", status: :paused)
    executor.running = false
    expect(resume("t")).to eq({ task_id: "t" })
    expect(executor.spawned.size).to eq(1)
    expect(executor.spawned.first[:resume_from].turn).to eq(1)
    expect(executor.resumed_live).to be_empty
  end

  it "paused WITH a live fiber (P2): resumes IN-PROCESS (posts :resume, does NOT re-dispatch)" do
    seed("t", status: :paused)
    executor.running = true
    expect(resume("t")).to eq({ task_id: "t" })
    expect(executor.resumed_live).to eq(["t"])
    expect(executor.spawned).to be_empty
  end

  it "waiting with a checkpoint: resumable" do
    seed("t", status: :waiting)
    resume("t")
    expect(executor.spawned.size).to eq(1)
  end

  it "orphaned running (running? false): resumable" do
    seed("t", status: :running)
    executor.running = false
    resume("t")
    expect(executor.spawned.size).to eq(1)
  end

  it "live running (running? true): ValidationError, does not spawn" do
    seed("t", status: :running)
    executor.running = true
    expect { resume("t") }.to raise_error(Harness::ValidationError, /is running/)
    expect(executor.spawned).to be_empty
  end

  it "queued (never started): re-runs from scratch via spawn_in_session (resume_from nil)" do
    # a turn that was in the SessionActor queue at crash time — no checkpoint; recovers
    # by running from the original Command (P2-03). The profile comes from the Command's agent.
    task_store.create(command: { "type" => "send_message", "payload" => { "agent" => "sales" } }, id: "q")

    expect(resume("q")).to eq({ task_id: "q" })
    expect(executor.spawned.size).to eq(1)
    expect(executor.spawned.first[:resume_from]).to be_nil # from scratch, not from the checkpoint
  end

  it "queued with a nonexistent agent: NotFoundError" do
    task_store.create(command: { "type" => "send_message", "payload" => { "agent" => "ghost" } }, id: "q")
    expect { resume("q") }.to raise_error(Harness::NotFoundError, /ghost/)
  end

  it "terminal states are not resumable" do
    %i[completed failed cancelled].each_with_index do |st, i|
      id = seed("t#{i}", status: st)
      expect { resume(id) }.to raise_error(Harness::ValidationError)
    end
  end

  it "without a checkpoint: ValidationError unrecoverable" do
    seed("t", status: :paused, checkpoint: false)
    expect { resume("t") }.to raise_error(Harness::ValidationError, /unrecoverable/)
  end

  it "nonexistent task: NotFoundError" do
    expect { resume("ghost") }.to raise_error(Harness::NotFoundError)
  end

  it "the checkpoint's agent vanished from the config: NotFoundError" do
    seed("t", status: :paused, agent_id: "ghost")
    expect { resume("t") }.to raise_error(Harness::NotFoundError, /ghost/)
  end

  it "uses the checkpoint with the highest turn (latest)" do
    seed("t", status: :paused, checkpoint: false)
    checkpoint_store.save(Harness::Checkpoint.new(task_id: "t", turn: 2, session_id: nil,
                                                  agent_id: "sales", messages: [],
                                                  completed_side_effects: [], created_at: nil))
    checkpoint_store.save(Harness::Checkpoint.new(task_id: "t", turn: 4, session_id: nil,
                                                  agent_id: "sales", messages: [],
                                                  completed_side_effects: [], created_at: nil))
    resume("t")
    expect(executor.spawned.first[:resume_from].turn).to eq(4)
  end

  it "missing task_id: ValidationError" do
    expect { handler.call(Harness::Command.build(:resume_task, {})) }
      .to raise_error(Harness::ValidationError)
  end
end
