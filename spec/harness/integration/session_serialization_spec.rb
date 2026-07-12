# frozen_string_literal: true

require "spec_helper"
require "async"

# P2-03 (critério da Etapa C): dois send_message concorrentes na MESMA sessão
# são SERIALIZADOS pelo SessionActor — o transcript fica consistente (FIFO, sem
# o clobber de read-modify-write que ocorreria com dois fibers no mesmo
# session_id). Sessões distintas seguem concorrentes.
RSpec.describe "Integração: serialização de turnos por sessão (P2-03)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { Harness::EventStream.new }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  let(:executor) do
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: { "sales" => profile }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end
  let(:bus) { Harness::CommandBus.new }
  let(:handler) do
    Harness::Commands::SendMessage.new(profiles: { "sales" => profile },
                                       session_store: session_store, task_store: task_store,
                                       executor: executor)
  end

  before do
    bus.register(:send_message, handler)
    # cada turno responde "ok:<mensagem>" (distingue os turnos no transcript)
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
    bus.dispatch(Harness::Command.build(:send_message, { agent: "sales", message: message, session_id: session_id }))
  end

  it "dois turnos concorrentes na MESMA sessão: transcript FIFO, sem clobber" do
    session_store.create(id: "s1")

    Sync do |parent|
      executor.supervised = true # SessionActor só serializa em modo serving
      r1 = dispatch("a", session_id: "s1")
      r2 = dispatch("b", session_id: "s1")
      expect(r1[:task_id]).not_to eq(r2[:task_id]) # dois turnos distintos, 202 imediato p/ ambos
      wait_terminal(parent, r1[:task_id], r2[:task_id])
      executor.stop_session_actors
      executor.instance_variable_get(:@supervisor)&.stop
    end

    contents = session_store.find("s1").messages.map { |m| m["content"] }
    # 4 mensagens, na ORDEM de chegada — nada perdido/entrelaçado
    expect(contents).to eq(["a", "ok:a", "b", "ok:b"])
  end

  it "sessões DISTINTAS não bloqueiam uma à outra (concorrência preservada)" do
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
