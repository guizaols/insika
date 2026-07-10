# frozen_string_literal: true

require "spec_helper"
require "async"

# Wiring REAL: CommandBus + handler SendMessage + Executor + stores de domínio
# sobre Memory + EventStream real. Chat roteirizado (FakeChat) via stub de
# create_chat — roda SEM a gem (doc 03 §7).
RSpec.describe "Integração: fluxo SendMessage Command->Response" do
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

  let(:bus) { Harness::CommandBus.new(event_stream: event_stream) }
  let(:handler) do
    Harness::Commands::SendMessage.new(profiles: { "sales" => profile },
                                       session_store: session_store, task_store: task_store,
                                       executor: executor)
  end

  # FakeChat roteirizado: 2 chunks + 1 tool call + resposta final.
  let(:scripted_chat) do
    chat = FakeChat.new
    chat.final_content = "resposta final"
    chat.script = proc do
      emit_chunk("Oi")
      emit_chunk(" tudo bem")
      fire_tool_call(name: "lookup", arguments: { "q" => "x" })
      fire_tool_result("resultado")
    end
    chat
  end

  before do
    bus.register(:send_message, handler)
    allow(executor).to receive(:create_chat).and_return(scripted_chat)
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # Turno com session_id é SERIALIZADO pelo SessionActor (P2-03): o turno é
  # spawnado ASSÍNCRONO pelo loop da sessão, então não dá para esperar em
  # @running logo após o dispatch. Faz poll até o estado terminal e para os
  # SessionActors (o loop bloqueia p/ sempre) para o Sync sair.
  def dispatch_and_wait(payload)
    result = nil
    collected = []
    Sync do |parent|
      sub = event_stream.subscribe
      consumer = parent.async { sub.each { |e| collected << e } }
      result = bus.dispatch(Harness::Command.build(:send_message, payload))
      wait_terminal(parent, result[:task_id])
      executor.stop_session_actors
      sub.close
      consumer.wait
    end
    [result, collected]
  end

  def wait_terminal(parent, task_id)
    100.times do
      t = task_store.find(task_id)
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.005)
    end
  end

  it "emite a sequência canônica de eventos (doc 03 §7)" do
    session_store.create(id: "s1")
    _result, events = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    expect(events.map(&:type)).to eq(
      %i[task_started content content tool_call tool_result checkpoint_created done task_completed]
    )
  end

  it "seq monotônico e meta.task_id/session_id corretos em todos" do
    session_store.create(id: "s1")
    result, events = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    seqs = events.map { |e| e.meta[:seq] }
    expect(seqs).to eq(seqs.sort)
    expect(seqs.uniq.size).to eq(seqs.size) # estritamente crescente
    expect(events.map { |e| e.meta[:task_id] }.uniq).to eq([result[:task_id]])
    expect(events.map { |e| e.meta[:session_id] }.uniq).to eq(["s1"])
  end

  it "estado final: task :completed, Execution fechada, checkpoint turn 2, transcript na sessão" do
    session_store.create(id: "s1")
    result, = dispatch_and_wait(agent: "sales", message: "oi", session_id: "s1")

    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:completed)
    expect(task.executions.last.outcome).to eq("completed")
    expect(checkpoint_store.latest(result[:task_id]).turn).to eq(2)
    expect(session_store.find("s1").messages.map { |m| m["content"] }).to eq(["oi", "resposta final"])
  end

  it "responde {task_id:} imediato (antes do :done)" do
    session_store.create(id: "s1")
    # a resposta é síncrona mesmo com o turno enfileirado no SessionActor (P2-03).
    Sync do
      result = bus.dispatch(Harness::Command.build(:send_message,
                                                   { agent: "sales", message: "oi", session_id: "s1" }))
      expect(result).to match({ task_id: kind_of(String) })
    ensure
      executor.stop_session_actors # encerra o loop da sessão p/ o Sync sair
    end
  end

  it "paridade history-only: mesmo fluxo, sessão intocada" do
    _result, events = dispatch_and_wait(
      agent: "sales", message: "oi", history: [{ role: "user", content: "anterior" }]
    )

    expect(events.map(&:type)).to include(:task_started, :done, :task_completed)
    expect(session_store.each_id.to_a).to be_empty # nenhuma sessão criada/tocada
  end
end
