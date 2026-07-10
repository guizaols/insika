# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/condition"

# Suspensão :paused no Executor (P2 task 2). Pausar exige captar :pause numa
# fronteira ANTES do estágio 6 — um context builder com gate suspende o turno no
# estágio 2, permitindo postar :pause antes da fronteira que o consome.
RSpec.describe "Harness::Executor — suspensão :paused" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  # Context builder que bloqueia no estágio 2 até `gate.signal`, depois delega.
  class GatingContextBuilder
    def initialize(gate)
      @gate = gate
      @inner = FakeContextBuilder.new
    end

    def call(request)
      @gate.wait
      @inner.call(request)
    end
  end

  def build_executor(context_builder:)
    Harness::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  def make_task
    session_store.create(id: "s1")
    command = Harness::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: "t")
  end

  def actor_of(executor) = executor.instance_variable_get(:@running)["t"]

  it "suspende em :paused na fronteira e retoma no :resume até concluir" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do |top|
      executor.spawn(make_task, profile: profile) # roda até o gate do estágio 2 (suspende)
      actor = actor_of(executor)
      actor.post(:pause)                            # :pause na mailbox antes da fronteira
      gate.signal                                   # estágio 2 retorna -> fronteira vê :pause
      top.sleep(0.02)
      expect(task_store.find("t").status).to eq(:paused)
      expect(event_stream.types).to include(:task_paused)

      actor.post(:resume)
      actor.wait
      expect(task_store.find("t").status).to eq(:completed)
      expect(event_stream.types).to include(:task_resumed)
      # ordem: paused vem antes de resumed, resumed antes de done
      types = event_stream.types
      expect(types.index(:task_paused)).to be < types.index(:task_resumed)
      expect(types.index(:task_resumed)).to be < types.index(:done)
    end
  end

  it ":cancel durante :paused -> :cancelled (transição válida)" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do |top|
      executor.spawn(make_task, profile: profile)
      actor = actor_of(executor)
      actor.post(:pause)
      gate.signal
      top.sleep(0.02)
      expect(task_store.find("t").status).to eq(:paused)

      actor.post(:cancel) # cancela enquanto pausado
      actor.wait
      expect(task_store.find("t").status).to eq(:cancelled)
      expect(event_stream.types).to include(:task_cancelled)
    end
  end

  it "sem :pause o fluxo é idêntico à Fase 1 (nenhum :task_paused)" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do
      executor.spawn(make_task, profile: profile)
      gate.signal # nenhuma pausa postada
      actor_of(executor).wait
      expect(task_store.find("t").status).to eq(:completed)
      expect(event_stream.types).not_to include(:task_paused)
    end
  end
end
