# frozen_string_literal: true

require "spec_helper"
require "async"

# Integração dos pares de hook restantes (:task, :agent, :tool) no Executor
# (task 19). Colaboradores fake; chat roteirizado via FakeChat.
RSpec.describe "Harness::Executor + hooks (:task/:agent/:tool)" do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:hooks) { Harness::Hooks.new }
  let(:profile) { Harness::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  def build_executor(tool_registry: FakeToolRegistry.new)
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: hooks,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  def make_task
    command = Harness::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: nil, id: "t")
  end

  def run(executor, chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(make_task, profile: profile)
      executor.instance_variable_get(:@running)["t"]&.wait
    end
  end

  it "ordem dos wrappers: before na ida (task->agent), after na volta (agent->task)" do
    order = []
    hooks.register(:task, before: ->(s) { order << "task:before"; s }, after: ->(r) { order << "task:after"; r })
    hooks.register(:agent, before: ->(s) { order << "agent:before"; s }, after: ->(r) { order << "agent:after"; r })

    run(build_executor)

    expect(order).to eq(["task:before", "agent:before", "agent:after", "task:after"])
  end

  it "before_task reescreve state.message; o chat recebe a mensagem alterada" do
    hooks.register(:task, before: lambda { |st|
      st.message = "REESCRITO"
      st
    })
    chat = FakeChat.new
    run(build_executor, chat: chat)

    expect(chat.asked).to eq("REESCRITO")
  end

  it "before_agent reescreve a mensagem enviada ao chat.ask" do
    # :agent recebe o TurnState como subject (task 12); before_agent muta message
    hooks.register(:agent, before: lambda { |st|
      st.message = "DO_AGENT"
      st
    })
    chat = FakeChat.new
    run(build_executor, chat: chat)

    expect(chat.asked).to eq("DO_AGENT")
  end

  it "L6: after_agent que levanta NÃO reexecuta o chat.ask; task :failed" do
    asks = 0
    chat = FakeChat.new
    chat.script = proc { asks += 1; emit_chunk("x") }
    hooks.register(:agent, after: ->(_r) { raise "after_agent caiu" })

    run(build_executor, chat: chat)

    expect(asks).to eq(1) # ask rodou uma vez, não reexecutou
    expect(task_store.find("t").status).to eq(:failed)
    expect(event_stream.types).to include(:task_failed, :error)
  end

  it "before_task que levanta: task :failed, chat nunca construído" do
    hooks.register(:task, before: ->(_s) { raise "before_task caiu" })
    executor = build_executor
    expect(executor).not_to receive(:create_chat)

    Sync do
      executor.spawn(make_task, profile: profile)
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    expect(task_store.find("t").status).to eq(:failed)
  end

  it "par :tool: before/after_tool rodam nos callbacks; eventos preservados" do
    seen = []
    hooks.register(:tool, before: ->(tc) { seen << [:before, tc.name]; tc })
    hooks.register(:tool, after: ->(r) { seen << [:after, r.to_s]; r })
    chat = FakeChat.new
    chat.script = proc do
      fire_tool_call(name: "lookup", arguments: {})
      fire_tool_result("resultado")
    end
    executor = build_executor

    run(executor, chat: chat)

    expect(seen).to include([:before, "lookup"], [:after, "resultado"])
    expect(event_stream.types).to include(:tool_call, :tool_result)
  end

  it "after_agent substitui a response; :done carrega o content substituído" do
    hooks.register(:agent, after: ->(_r) { FakeChat::Response.new("SUBSTITUÍDO") })

    run(build_executor)

    done = event_stream.events.find { |e| e.type == :done }
    expect(done.data[:content]).to eq("SUBSTITUÍDO")
  end

  it "contador de tool calls zera por turno (duas tasks de 2 calls, limite 3)" do
    profile3 = Harness::AgentProfile.build(id: "sales", model: "gpt", limits: { max_tool_calls: 3 })
    executor = build_executor

    %w[t1 t2].each do |id|
      chat = FakeChat.new
      chat.script = proc { 2.times { |i| fire_tool_call(name: "x#{i}") } }
      allow(executor).to receive(:create_chat).and_return(chat)
      command = Harness::Command.build(:send_message, { agent: "sales", message: "oi" })
      task_store.create(command: command.to_h, id: id)
      Sync do
        executor.spawn(task_store.find(id), profile: profile3)
        executor.instance_variable_get(:@running)[id]&.wait
      end
      # 2 calls < limite 3; se o contador acumulasse entre turnos, t2 estouraria
      expect(task_store.find(id).status).to eq(:completed)
    end
  end

  it "tool_limit: 51ª tool call com max_tool_calls 50 -> TimeoutError(stage :tool_limit) -> :failed" do
    fast_profile = Harness::AgentProfile.build(id: "sales", model: "gpt", limits: { max_tool_calls: 2 })
    chat = FakeChat.new
    chat.script = proc { 3.times { |i| fire_tool_call(name: "t#{i}") } }
    executor = build_executor

    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(make_task, profile: fast_profile)
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    task = task_store.find("t")
    expect(task.status).to eq(:failed)
    expect(task.executions.last.error["stage"]).to eq("tool_limit")
  end
end
