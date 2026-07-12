# frozen_string_literal: true

require "spec_helper"

# Fase 4 D2 (critério da Etapa A): o runtime consome profiles DINÂMICOS.
# Um profile criado em runtime no ConfigStore é resolvido por um Command de
# turno via StoredProfileSource — sem Hash congelado, sem restart.
RSpec.describe "Integração: turno com StoredProfileSource (Fase 4 D2)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:config_store) { Harness::ConfigStore.new(store: backend) }
  let(:profiles) { Harness::StoredProfileSource.new(config_store: config_store) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:session_store) { Harness::SessionStore.new(store: backend) }

  # Executor dublê: só registra o profile que o Command resolveu e passou ao spawn.
  let(:executor) do
    Class.new do
      attr_reader :spawned
      def spawn_in_session(task, profile:, resume_from: nil) = (@spawned = profile; task.id)
    end.new
  end

  let(:handler) do
    Harness::Commands::SendMessage.new(
      profiles: profiles, session_store: session_store, task_store: task_store, executor: executor
    )
  end

  it "resolve um profile recém-criado no ConfigStore (dinâmico, sem Hash congelado)" do
    # nenhum agente ainda -> NotFoundError
    expect do
      handler.call(Harness::Command.build(:send_message, { agent: "bia", message: "oi" }))
    end.to raise_error(Harness::NotFoundError)

    # cria o agente em RUNTIME (o que o Studio fará via :create_agent)
    profiles.put(Harness::AgentProfile.build(id: "bia", model: "deepseek-chat", provider: :deepseek))

    res = handler.call(Harness::Command.build(:send_message, { agent: "bia", message: "oi" }))
    expect(res[:task_id]).to be_a(String)
    expect(executor.spawned.id).to eq("bia")
    expect(executor.spawned.provider).to eq(:deepseek) # round-trip preservado no caminho real
  end
end
