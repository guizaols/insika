# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/condition"

RSpec.describe "Harness::Executor pipeline (estágios 2-9)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  def build_executor(**over)
    defaults = {
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    }
    Harness::Executor.new(**defaults.merge(over))
  end

  def make_task(session_id: "s1", message: "oi", history: nil)
    payload = { agent: "sales", message: message }
    payload[:history] = history if history
    command = Harness::Command.build(:send_message, payload)
    task_store.create(command: command.to_h, session_id: session_id, id: "t")
  end

  # Roda o turno até o fim (o fiber completa síncrono com FakeChat não-suspenso).
  def run_turn(executor, task, fake_chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(fake_chat)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  describe "caminho feliz com sessão" do
    it "emite os estágios em ordem e persiste (estágio 8 na ordem L4)" do
      session_store.create(id: "s1")
      executor = build_executor
      order = []
      allow(checkpoint_store).to receive(:save).and_wrap_original { |m, *a| order << :checkpoint; m.call(*a) }
      allow(session_store).to receive(:append_messages).and_wrap_original { |m, *a| order << :session; m.call(*a) }
      allow(task_store).to receive(:transition).and_wrap_original do |m, id, **kw|
        order << [:transition, kw[:to]]; m.call(id, **kw)
      end

      run_turn(executor, make_task)

      # ordem do estágio 8: checkpoint -> session -> transition(:completed)
      expect(order).to eq([[:transition, :running], :checkpoint, :session, [:transition, :completed]])
      # eventos do turno
      expect(event_stream.types).to eq(
        %i[task_started content checkpoint_created done task_completed]
      )
      # estado final
      task = task_store.find("t")
      expect(task.status).to eq(:completed)
      expect(task.executions.last.outcome).to eq("completed")
      # checkpoint do turno 2 com transcript + agent_id
      cp = checkpoint_store.latest("t")
      expect(cp.turn).to eq(2)
      expect(cp.agent_id).to eq("sales")
      expect(cp.messages.map { |m| m["role"] }).to eq(%w[user assistant])
      # sessão recebeu as 2 mensagens novas
      expect(session_store.find("s1").messages.map { |m| m["content"] }).to eq(["oi", "final"])
    end
  end

  describe "one-shot (sem sessão)" do
    it "não toca a sessão mas grava checkpoint" do
      executor = build_executor
      expect(session_store).not_to receive(:append_messages)

      run_turn(executor, make_task(session_id: nil))

      expect(task_store.find("t").status).to eq(:completed)
      expect(checkpoint_store.latest("t").turn).to eq(2)
    end
  end

  describe "hooks around" do
    it "envolve prompt (estágio 2) e agent (estágio 6), nessa ordem" do
      session_store.create(id: "s1")
      hooks = NullHooks.new
      executor = build_executor(hooks: hooks)

      run_turn(executor, make_task)

      expect(hooks.pairs).to eq(%i[prompt agent])
    end
  end

  describe "PolicyDenied no estágio 3" do
    it "emite :policy_denied + :task_failed + :error e nunca constrói o chat" do
      session_store.create(id: "s1")
      executor = build_executor(policy_engine: DenyAllPolicyEngine.new)
      expect(executor).not_to receive(:create_chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      expect(event_stream.types).to include(:policy_denied, :task_failed, :error)
      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error).to include("stage" => "policy")
    end
  end

  describe "middleware halt" do
    it "falha o turno com halt_reason e nunca constrói o chat" do
      session_store.create(id: "s1")
      executor = build_executor(middleware: HaltingMiddleware.new)
      expect(executor).not_to receive(:create_chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["message"]).to include("rate limit")
    end
  end

  describe "captura única" do
    it "ContextError -> task :failed com stage :context, fiber não vaza" do
      session_store.create(id: "s1")
      executor = build_executor(context_builder: RaisingContextBuilder.new)

      expect do
        Sync do
          executor.spawn(make_task, profile: profile)
          executor.instance_variable_get(:@running)["t"]&.wait
        end
      end.not_to raise_error

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("context")
      expect(event_stream.types).to include(:task_failed, :error)
    end

    it "StoreError no estágio 8 -> :failed stage :persistence + :error" do
      session_store.create(id: "s1")
      executor = build_executor
      allow(checkpoint_store).to receive(:save).and_raise(Harness::StoreError, "disco cheio")

      run_turn(executor, make_task)

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("persistence")
      expect(event_stream.types).to include(:error)
    end
  end

  describe "turn timeout (D4, via with_timeout)" do
    it "estoura -> :failed com stage :turn" do
      session_store.create(id: "s1")
      fast = Harness::AgentProfile.build(id: "sales", model: "gpt", limits: { turn_timeout: 0.05 })
      executor = build_executor
      slow_chat = FakeChat.new
      slow_chat.script = proc { Async::Task.current.sleep(1) } # cede o fiber além do timeout
      allow(executor).to receive(:create_chat).and_return(slow_chat)

      Sync do
        executor.spawn(make_task, profile: fast)
        executor.instance_variable_get(:@running)["t"]&.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error["stage"]).to eq("turn")
    end
  end

  describe "tool timeout e side-effect (ToolEnvelope)" do
    # profile do state com timeouts curtos (Data é frozen: construir, não stubar)
    let(:fast_profile) do
      Harness::AgentProfile.build(id: "s", model: "m", limits: { tool_timeout: 0.05 })
    end
    let(:state) do
      Harness::TurnState.new(task: task_store.create(command: { "type" => "x" }, id: "t"),
                             profile: fast_profile, turn: 1, message: "oi")
    end

    it "tool que estoura devolve {error:} ao modelo (turno segue)" do
      slow_tool = Class.new do
        def name = "lookup"
        def call(_args)
          Async::Task.current.sleep(1)
          "nunca"
        end
      end.new
      executor = build_executor
      wrapped = executor.send(:wrap_tools, [slow_tool], state)

      result = Sync { wrapped.first.call({}) }

      expect(result).to eq({ error: "TimeoutError: tool excedeu 0.05s" })
    end

    it "registra side-effect com o tool_call_id corrente ANTES do resultado voltar" do
      fast_tool = Class.new do
        def name = "charge"
        def call(_args) = "ok"
      end.new
      executor = build_executor(tool_registry: FakeToolRegistry.new(side_effect_names: ["charge"]))
      state.current_tool_call = FakeChat::ToolCall.new("charge", {}, "call_42")
      wrapped = executor.send(:wrap_tools, [fast_tool], state)

      Sync { wrapped.first.call({}) }

      expect(checkpoint_store.side_effects("t", turn: 1)).to eq(["call_42"])
    end
  end

  describe "cancel na fronteira" do
    it "-> :cancelled; checkpoint anterior intacto; nenhum evento após :task_cancelled" do
      session_store.create(id: "s1")
      executor = build_executor
      gate = Async::Condition.new
      chat = FakeChat.new
      chat.script = proc { gate.wait } # cede o fiber no estágio 6
      allow(executor).to receive(:create_chat).and_return(chat)

      Sync do
        executor.spawn(make_task, profile: profile)
        actor = executor.instance_variable_get(:@running)["t"]
        executor.cancel("t") # posta :cancel enquanto o ask espera
        gate.signal # ask retorna; próximo drain (estágio 8) vê o cancel
        actor.wait
      end

      task = task_store.find("t")
      expect(task.status).to eq(:cancelled)
      # nenhum checkpoint gravado (cancel antes do estágio 8)
      expect(checkpoint_store.latest("t")).to be_nil
      # :task_cancelled é o penúltimo; só :error (compat) vem depois
      expect(event_stream.types.last(2)).to eq(%i[task_cancelled error])
    end
  end
end
