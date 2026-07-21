# frozen_string_literal: true

require "spec_helper"
require "async"

# Integration of the remaining hook pairs (:task, :agent, :tool) in the Executor
# (task 19). Fake collaborators; chat scripted via FakeChat.
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

  it "wrapper order: before on the way in (task->agent), after on the way back (agent->task)" do
    order = []
    hooks.register(:task, before: ->(s) { order << "task:before"; s }, after: ->(r) { order << "task:after"; r })
    hooks.register(:agent, before: ->(s) { order << "agent:before"; s }, after: ->(r) { order << "agent:after"; r })

    run(build_executor)

    expect(order).to eq(["task:before", "agent:before", "agent:after", "task:after"])
  end

  it "before_task rewrites state.message; the chat receives the altered message" do
    hooks.register(:task, before: lambda { |st|
      st.message = "REESCRITO"
      st
    })
    chat = FakeChat.new
    run(build_executor, chat: chat)

    expect(chat.asked).to eq("REESCRITO")
  end

  it "before_agent rewrites the message sent to chat.ask" do
    # :agent receives the TurnState as subject (task 12); before_agent mutates message
    hooks.register(:agent, before: lambda { |st|
      st.message = "DO_AGENT"
      st
    })
    chat = FakeChat.new
    run(build_executor, chat: chat)

    expect(chat.asked).to eq("DO_AGENT")
  end

  it "L6: after_agent that raises does NOT re-run chat.ask; task :failed" do
    asks = 0
    chat = FakeChat.new
    chat.script = proc { asks += 1; emit_chunk("x") }
    hooks.register(:agent, after: ->(_r) { raise "after_agent caiu" })

    run(build_executor, chat: chat)

    expect(asks).to eq(1) # ask ran once, did not re-run
    expect(task_store.find("t").status).to eq(:failed)
    expect(event_stream.types).to include(:task_failed)
    expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
  end

  it "before_task that raises: task :failed, chat never built" do
    hooks.register(:task, before: ->(_s) { raise "before_task caiu" })
    executor = build_executor
    expect(executor).not_to receive(:create_chat)

    Sync do
      executor.spawn(make_task, profile: profile)
      executor.instance_variable_get(:@running)["t"]&.wait
    end

    expect(task_store.find("t").status).to eq(:failed)
  end

  it "the :tool pair: before/after_tool run in the callbacks; events preserved" do
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

  it "after_agent replaces the response; :task_completed carries the substituted content" do
    hooks.register(:agent, after: ->(_r) { FakeChat::Response.new("SUBSTITUÍDO") })

    run(build_executor)

    done = event_stream.events.find { |e| e.type == :task_completed }
    expect(done.data[:content]).to eq("SUBSTITUÍDO")
  end

  it "tool call counter resets per turn (two tasks of 2 calls, limit 3)" do
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
      # 2 calls < limit 3; if the counter accumulated between turns, t2 would overflow
      expect(task_store.find(id).status).to eq(:completed)
    end
  end

  it "tool_limit: 51st tool call with max_tool_calls 50 -> TimeoutError(stage :tool_limit) -> :failed" do
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
