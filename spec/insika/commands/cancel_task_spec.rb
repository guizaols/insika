# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::CancelTask do
  subject(:handler) { described_class.new(task_store: task_store, executor: executor) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:executor) { RecordingExecutor.new }

  # Executor double (contract: #cancel(task_id)); the real one lands in task 10.
  class RecordingExecutor
    attr_reader :cancelled

    def initialize = (@cancelled = [])
    def cancel(task_id) = @cancelled << task_id
  end

  def create_task(id, status: nil)
    task_store.create(command: { type: "send_message", payload: {}, meta: {} }, id: id)
    return if status.nil?

    task_store.begin_execution(id)
    task_store.transition(id, to: :running)
    task_store.transition(id, to: status) unless status == :running
  end

  it "posts cancel to the executor and returns the Task for a live task" do
    create_task("t", status: :running)

    task = handler.call(Insika::Command.build(:cancel_task, { task_id: "t" }))

    expect(executor.cancelled).to eq(["t"])
    expect(task).to be_a(Insika::TaskStore::Task)
    expect(task.id).to eq("t")
  end

  it "raises NotFoundError and does NOT call the executor for a nonexistent task" do
    expect { handler.call(Insika::Command.build(:cancel_task, { task_id: "ghost" })) }
      .to raise_error(Insika::NotFoundError)
    expect(executor.cancelled).to be_empty
  end

  it "raises ValidationError for a missing task_id" do
    expect { handler.call(Insika::Command.build(:cancel_task, {})) }
      .to raise_error(Insika::ValidationError)
  end

  it "raises ValidationError for an empty task_id" do
    expect { handler.call(Insika::Command.build(:cancel_task, { task_id: "" })) }
      .to raise_error(Insika::ValidationError)
  end

  it "is a no-op without error for a terminal task (returns the Task unchanged)" do
    create_task("done", status: :running)
    task_store.finish_execution("done", outcome: "completed")
    task_store.transition("done", to: :completed)

    task = handler.call(Insika::Command.build(:cancel_task, { task_id: "done" }))

    expect(task.status).to eq(:completed)
    expect(executor.cancelled).to eq(["done"])
  end

  it "is idempotent: two calls in a row return a Task without exception" do
    create_task("t", status: :running)
    command = Insika::Command.build(:cancel_task, { task_id: "t" })

    expect { 2.times { handler.call(command) } }.not_to raise_error
    expect(executor.cancelled).to eq(%w[t t])
  end

  it "accepts task_id with a string key (transport JSON)" do
    create_task("t", status: :running)

    task = handler.call(Insika::Command.build(:cancel_task, { "task_id" => "t" }))

    expect(task.id).to eq("t")
  end
end
