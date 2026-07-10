# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"
require "fileutils"
require "sqlite3"

# Critério de conclusão da Etapa C (doc 00 §6) em nível de integração: um turno
# interrompido por "crash" sobrevive num arquivo SQLite, e um "reboot" (objetos
# novos, MESMO arquivo) retoma do checkpoint via Recovery -> ResumeTask,
# completando sem reexecutar a tool não-idempotente já concluída.
#
# kill -9 não roda rescue: o estado pós-crash é montado DIRETO nos stores
# (task :running, Execution aberta, checkpoint do turno, side-effect na chave
# avulsa, sem fiber vivo) — simular via exceção passaria pela captura única e
# marcaria :failed, que não é o cenário. O E2E com processo real é a task 26.
RSpec.describe "Integração: kill -> restart -> resume" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:db_path) { File.join(@dir, "harness.db") }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }
  # tool side-effect compartilhada: prova que NÃO é reexecutada no resume.
  let(:tool) do
    Class.new do
      attr_reader :calls

      def initialize = (@calls = 0)
      def name = "enviar_pedido"
      def call(_args) = (@calls += 1) && "enviado"
    end.new
  end

  def wiring(store)
    session_store = Harness::SessionStore.new(store: store)
    task_store = Harness::TaskStore.new(store: store)
    checkpoint_store = Harness::CheckpointStore.new(store: store)
    event_stream = Harness::EventStream.new
    executor = Harness::Executor.new(
      context_builder: FakeContextBuilder.new,
      policy_engine: NullPolicyEngine.new(allowed_tools: [tool]),
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new(side_effect_names: ["enviar_pedido"]),
      skill_catalog: Harness::SkillCatalog.new([]), profiles: { "sales" => profile },
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
    { session_store: session_store, task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, executor: executor }
  end

  it "retoma o turno interrompido, completa e NÃO reexecuta a tool já concluída" do
    # ── Ato 1: o crash (estado montado direto no arquivo) ───────────────────
    store_a = Harness::Stores::SQLite.new(path: db_path)
    a = wiring(store_a)
    a[:session_store].create(id: "s1")
    command = Harness::Command.build(:send_message,
                                     { agent: "sales", message: "faz o pedido", session_id: "s1" })
    a[:task_store].create(command: command.to_h, session_id: "s1", id: "t")
    a[:task_store].begin_execution("t")          # attempt 1 fica ABERTA (fiber morto)
    a[:task_store].transition("t", to: :running)
    a[:checkpoint_store].save(Harness::Checkpoint.new(
                                task_id: "t", turn: 1, session_id: "s1", agent_id: "sales",
                                messages: [], completed_side_effects: [], created_at: nil
                              ))
    a[:checkpoint_store].record_side_effect("t", turn: 1, tool_call_id: "call_pedido")
    store_a.close # "kill"

    # ── Ato 2: o reboot (objetos novos, MESMO arquivo) ──────────────────────
    store_b = Harness::Stores::SQLite.new(path: db_path)
    b = wiring(store_b)
    handler = Harness::Commands::ResumeTask.new(
      profiles: { "sales" => profile }, task_store: b[:task_store],
      checkpoint_store: b[:checkpoint_store], executor: b[:executor]
    )
    bus = Harness::CommandBus.new(event_stream: b[:event_stream])
    bus.register(:resume_task, handler)

    # modelo re-pede a MESMA tool call (mesmo id) e depois responde final.
    fake = FakeChat.new
    fake.final_content = "pedido confirmado"
    fake.script = proc do
      fire_tool_call(name: "enviar_pedido", arguments: {}, id: "call_pedido")
      result = @tools.first.call({})
      fire_tool_result(result)
    end
    allow(b[:executor]).to receive(:create_chat).and_return(fake)

    summary = nil
    events = []
    Sync do |parent|
      sub = b[:event_stream].subscribe
      consumer = parent.async { sub.each { |e| events << e } }
      summary = Harness::Recovery.new(task_store: b[:task_store],
                                      checkpoint_store: b[:checkpoint_store],
                                      command_bus: bus).run
      # a task tem session_id -> a retomada é SERIALIZADA no SessionActor (P2-03),
      # spawnada assíncrona; poll até terminal e para o loop da sessão.
      100.times do
        t = b[:task_store].find("t")
        break if t && %w[completed failed cancelled].include?(t.status.to_s)

        parent.sleep(0.005)
      end
      b[:executor].stop_session_actors
      sub.close
      consumer.wait
    end
    store_b.close

    # ── Verificação (arquivo reaberto: durabilidade real) ───────────────────
    store_c = Harness::Stores::SQLite.new(path: db_path)
    c = wiring(store_c)

    expect(summary[:resumed]).to include("t")
    task = c[:task_store].find("t")
    expect(task.status).to eq(:completed)
    # nova Execution: attempt 1 (interrompido) preservado + attempt 2 (completo)
    expect(task.executions.size).to eq(2)
    expect(task.executions.first.outcome).to eq("interrupted")
    expect(task.executions.last.outcome).to eq("completed")
    # a tool NÃO foi reexecutada; o :tool_result carregou o marcador
    expect(tool.calls).to eq(0)
    result_event = events.find { |e| e.type == :tool_result }
    expect(result_event.data[:result]).to include("already_executed")
    expect(events.map(&:type)).to include(:done, :task_completed)
    # checkpoint avançou (turno 1 -> 2) e o prune manteve o último
    expect(c[:checkpoint_store].latest("t").turn).to eq(2)
    # sessão íntegra: as mensagens do turno aparecem UMA vez (crash foi antes do 8)
    expect(c[:session_store].find("s1").messages.map { |m| m["content"] })
      .to eq(["faz o pedido", "pedido confirmado"])

    store_c.close
  end
end
