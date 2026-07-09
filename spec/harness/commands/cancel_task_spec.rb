# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::CancelTask do
  subject(:handler) { described_class.new(task_store: task_store, executor: executor) }

  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:executor) { RecordingExecutor.new }

  # Duplo do executor (contrato: #cancel(task_id)); real chega na task 10.
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

  it "posta cancel no executor e retorna a Task para task viva" do
    create_task("t", status: :running)

    task = handler.call(Harness::Command.build(:cancel_task, { task_id: "t" }))

    expect(executor.cancelled).to eq(["t"])
    expect(task).to be_a(Harness::TaskStore::Task)
    expect(task.id).to eq("t")
  end

  it "levanta NotFoundError e NÃO chama o executor para task inexistente" do
    expect { handler.call(Harness::Command.build(:cancel_task, { task_id: "ghost" })) }
      .to raise_error(Harness::NotFoundError)
    expect(executor.cancelled).to be_empty
  end

  it "levanta ValidationError para task_id ausente" do
    expect { handler.call(Harness::Command.build(:cancel_task, {})) }
      .to raise_error(Harness::ValidationError)
  end

  it "levanta ValidationError para task_id vazio" do
    expect { handler.call(Harness::Command.build(:cancel_task, { task_id: "" })) }
      .to raise_error(Harness::ValidationError)
  end

  it "é no-op sem erro para task terminal (retorna a Task inalterada)" do
    create_task("done", status: :running)
    task_store.finish_execution("done", outcome: "completed")
    task_store.transition("done", to: :completed)

    task = handler.call(Harness::Command.build(:cancel_task, { task_id: "done" }))

    expect(task.status).to eq(:completed)
    expect(executor.cancelled).to eq(["done"])
  end

  it "é idempotente: dois calls seguidos retornam Task sem exceção" do
    create_task("t", status: :running)
    command = Harness::Command.build(:cancel_task, { task_id: "t" })

    expect { 2.times { handler.call(command) } }.not_to raise_error
    expect(executor.cancelled).to eq(%w[t t])
  end

  it "aceita task_id com chave string (JSON do transporte)" do
    create_task("t", status: :running)

    task = handler.call(Harness::Command.build(:cancel_task, { "task_id" => "t" }))

    expect(task.id).to eq("t")
  end
end
