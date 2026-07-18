# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::PauseTask do
  subject(:handler) { described_class.new(task_store: task_store, executor: executor) }

  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:executor) { RecordingPauseExecutor.new }

  # Executor double (contract: #pause(task_id) -> was there a fiber?).
  class RecordingPauseExecutor
    attr_reader :paused

    def initialize(live: true)
      @paused = []
      @live = live
    end

    def pause(task_id)
      @paused << task_id
      @live
    end
  end

  def create_task(id, status: :running)
    task_store.create(command: { type: "send_message", payload: {}, meta: {} }, id: id)
    task_store.begin_execution(id)
    task_store.transition(id, to: :running)
    task_store.transition(id, to: status) unless status == :running
  end

  it "posts :pause to the executor and returns the Task" do
    create_task("t")

    task = handler.call(Harness::Command.build(:pause_task, { task_id: "t" }))

    expect(executor.paused).to eq(["t"])
    expect(task).to be_a(Harness::TaskStore::Task)
    expect(task.id).to eq("t")
  end

  it "is a no-op without a live fiber (executor returns false) — no error" do
    dead = RecordingPauseExecutor.new(live: false)
    h = described_class.new(task_store: task_store, executor: dead)
    create_task("t")

    expect { h.call(Harness::Command.build(:pause_task, { task_id: "t" })) }.not_to raise_error
    expect(dead.paused).to eq(["t"])
  end

  it "raises NotFoundError and does NOT call the executor for a nonexistent task" do
    expect { handler.call(Harness::Command.build(:pause_task, { task_id: "ghost" })) }
      .to raise_error(Harness::NotFoundError)
    expect(executor.paused).to be_empty
  end

  it "raises ValidationError for a missing/empty task_id" do
    expect { handler.call(Harness::Command.build(:pause_task, {})) }
      .to raise_error(Harness::ValidationError)
    expect { handler.call(Harness::Command.build(:pause_task, { task_id: "" })) }
      .to raise_error(Harness::ValidationError)
  end

  it "accepts task_id with a string key (transport JSON)" do
    create_task("t")

    task = handler.call(Harness::Command.build(:pause_task, { "task_id" => "t" }))

    expect(task.id).to eq("t")
  end
end
