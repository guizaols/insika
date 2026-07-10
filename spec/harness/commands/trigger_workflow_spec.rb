# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::TriggerWorkflow do
  subject(:handler) do
    described_class.new(profiles: profiles, session_store: session_store,
                        task_store: task_store, executor: executor,
                        workflow_registry: workflow_registry)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt") }
  let(:profiles) { { "sales" => profile } }
  let(:workflow_registry) do
    Harness::WorkflowRegistry.new.tap { |r| r.register("flow", ->(i, **) { i }) }
  end
  let(:executor) do
    Class.new do
      attr_reader :spawned

      def initialize = (@spawned = [])
      def spawn_in_session(task, profile:, resume_from: nil) = @spawned << task.id
    end.new
  end

  def payload(**over)
    { workflow: "flow", agent: "sales", input: { a: 1 } }.merge(over)
  end

  def call(pl) = handler.call(Harness::Command.build(:trigger_workflow, pl))

  it "caminho válido: cria Task :queued com command persistido, spawna, retorna {task_id:}" do
    result = call(payload(session_id: nil))
    expect(result).to match({ task_id: kind_of(String) })
    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:queued)
    expect(task.command["type"]).to eq("trigger_workflow")
    expect(executor.spawned.size).to eq(1)
  end

  it "workflow ausente/vazio -> ValidationError, nenhuma Task" do
    [payload(workflow: ""), payload(workflow: nil)].each do |pl|
      expect { call(pl) }.to raise_error(Harness::ValidationError)
    end
    expect(task_store.each_id.to_a).to be_empty
  end

  it "agent inexistente -> NotFoundError" do
    expect { call(payload(agent: "nope")) }.to raise_error(Harness::NotFoundError)
  end

  it "input não-Hash -> ValidationError" do
    expect { call(payload(input: "x")) }.to raise_error(Harness::ValidationError)
  end

  it "session inexistente -> NotFoundError síncrono" do
    expect { call(payload(session_id: "ghost")) }.to raise_error(Harness::NotFoundError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "workflow fora do Registry -> NotFoundError, nenhuma Task" do
    expect { call(payload(workflow: "inexistente")) }.to raise_error(Harness::NotFoundError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "chave desconhecida no payload -> ValidationError (validação estrita)" do
    expect { call(payload.merge(foo: 1)) }.to raise_error(Harness::ValidationError, /desconhecida/)
  end

  it "input default {} quando ausente" do
    result = call({ workflow: "flow", agent: "sales" })
    expect(task_store.find(result[:task_id]).status).to eq(:queued)
  end
end
