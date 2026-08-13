# frozen_string_literal: true

require "spec_helper"
require "async"

# WS4 end-to-end through the real Executor: a `routes` profile classifies the
# message with the cheap model before the ask; the route rides the turn
# (event + terminal), its cost lands in the usage, and a route can delegate to
# an existing agent (its answer becomes the parent's) or end the turn :stuck.
RSpec.describe "Insika::Executor + routing (WS4)" do
  # A fake @llm whose .chat returns a chat that answers the classifier's ask
  # with a scripted text + token counts (records the classifier chats).
  class RoutingLLMDouble
    attr_reader :classifier_chats

    def initialize(answer, tokens: {})
      @answer = answer
      @tokens = tokens
      @classifier_chats = []
    end

    def chat(model:, provider: nil, assume_model_exists: false)
      answer = @answer
      tokens = @tokens
      recorder = @classifier_chats
      chat = Object.new
      chat.define_singleton_method(:with_instructions) { |_p| self }
      chat.define_singleton_method(:ask) do |_message|
        response = Object.new
        response.define_singleton_method(:content) { answer }
        tokens.each { |k, v| response.define_singleton_method(k) { v } }
        response
      end
      recorder << { model: model, provider: provider }
      chat
    end
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }

  let(:routed_profile) do
    Insika::AgentProfile.build(
      id: "example-agent", model: "gpt", base_prompt: "SOUL",
      routes: { "shopping" => "the customer wants to browse products",
                "order" => { "description" => "asks about an existing order",
                             "delegate" => "order-agent" },
                "human" => { "description" => "the customer asks for a person",
                             "stuck" => true, "message" => "A person will help you." },
                "default" => "shopping", "model" => "deepseek-v4-flash" }
    )
  end
  let(:order_profile) { Insika::AgentProfile.build(id: "order-agent", model: "gpt", base_prompt: "ORDER") }

  def build_executor(llm, profiles: {})
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory, llm: llm
    )
  end

  def make_task(message, id:)
    command = Insika::Command.build(:send_message, { agent: "example-agent", message: message })
    task_store.create(command: command.to_h, session_id: "s1", id: id)
  end

  # The MAIN agent ask is stubbed (the classifier runs through the real @llm
  # factory; the agent's own ask is a FakeChat, like the other close-to-pipeline
  # specs).
  def run_turn(executor, task, chat, profile: routed_profile)
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  before { session_store.create(id: "s1") }

  it "the message is classified into a route; the route + its cost ride the turn", :aggregate_failures do
    llm = RoutingLLMDouble.new("shopping", tokens: { input_tokens: 50, output_tokens: 10 })
    executor = build_executor(llm, profiles: { "order-agent" => order_profile })
    chat = FakeChat.new
    run_turn(executor, make_task("quero ver um vestido", id: "r1"), chat)

    # the classifier was asked BEFORE the agent (a cheap model, not the agent's)
    expect(llm.classifier_chats.first[:model]).to eq("deepseek-v4-flash")
    expect(chat.asked).to eq("quero ver um vestido") # the plain route still runs the agent

    routed = event_stream.events.find { |e| e.type == :route_classified }
    expect(routed.data).to include(route: "shopping", agent: "example-agent",
                                   model: "deepseek-v4-flash")
    expect(routed.data[:usage]).to include(input_tokens: 50, output_tokens: 10, total_tokens: 60)

    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data).to include(route: "shopping")
    expect(completed.data[:usage]).to include(total_tokens: 60) # the routing cost IS in the trace
    expect(completed.data[:usage]).to include(model_source: :routing)
  end

  it "a prose/unknown classifier answer falls back to the DEFAULT route, deterministically" do
    llm = RoutingLLMDouble.new("I cannot tell")
    executor = build_executor(llm, profiles: { "order-agent" => order_profile })
    run_turn(executor, make_task("qualquer coisa", id: "r2"), FakeChat.new)

    routed = event_stream.events.find { |e| e.type == :route_classified }
    expect(routed.data[:route]).to eq("shopping") # default, never invented
  end

  it "a route that DELEGATES hands the turn to the agent and returns its answer to the parent" do
    llm = RoutingLLMDouble.new("order")
    executor = build_executor(llm, profiles: { "order-agent" => order_profile })
    # the child (order-agent) answers through the same stubbed chat
    chat = FakeChat.new
    chat.script = proc { emit_chunk("seu pedido foi enviado") }
    run_turn(executor, make_task("cadê meu pedido", id: "r3"), chat)

    started = event_stream.events.find { |e| e.type == :subagent_started }
    expect(started.data).to include(agent: "order-agent")

    # the child completed BEFORE the parent (the parent awaited it) — the
    # parent's terminal is the LAST task_completed.
    completed = event_stream.events.reverse.find { |e| e.type == :task_completed }
    expect(completed.data[:content]).to eq("seu pedido foi enviado")
    expect(completed.data[:route]).to eq("order")
    expect(task_store.find("r3").status).to eq(:completed)
  end

  it "a route marked STUCK ends the turn with the WS5 outcome and the route's lead-in" do
    llm = RoutingLLMDouble.new("human")
    executor = build_executor(llm, profiles: { "order-agent" => order_profile })
    chat = FakeChat.new
    run_turn(executor, make_task("quero falar com alguém", id: "r4"), chat)

    expect(chat.asked).to be_nil # no agent ask on a stuck route
    completed = event_stream.events.find { |e| e.type == :task_completed }
    expect(completed.data).to include(route: "human", outcome: :stuck,
                                      content: "A person will help you.")
    stuck = event_stream.events.find { |e| e.type == :turn_stuck }
    expect(stuck.data).to include(reason: "route:human", message: "A person will help you.")
  end

  # A -> B -> A: each turn reclassifies (a paid ask) and spawns another child.
  # The delegate path does NOT go through plan_subagent (a route has no
  # subagents allowlist), so the hardcoded depth of 1 meant the chain had no
  # floor at all. The depth now comes from the parent's turn context, +1.
  it "a route delegation cycle stops at the depth cap instead of looping forever" do
    ping = Insika::AgentProfile.build(
      id: "ping", model: "gpt",
      routes: { "hop" => { "description" => "hand it over", "delegate" => "pong" },
                "default" => "hop", "model" => "deepseek-v4-flash" }
    )
    pong = Insika::AgentProfile.build(
      id: "pong", model: "gpt",
      routes: { "hop" => { "description" => "hand it back", "delegate" => "ping" },
                "default" => "hop", "model" => "deepseek-v4-flash" }
    )
    llm = RoutingLLMDouble.new("hop")
    executor = build_executor(llm, profiles: { "ping" => ping, "pong" => pong })
    task = task_store.create(
      command: Insika::Command.build(:send_message, { agent: "ping", message: "oi" }).to_h,
      session_id: "s1", id: "loop-1"
    )
    run_turn(executor, task, FakeChat.new, profile: ping)

    stored = task_store.find("loop-1")
    expect(stored.status).to eq(:failed)
    expect(stored.executions.last.error).to include("class" => "Insika::RoutingError",
                                                    "message" => /exceeds cap #{Insika::SubagentGraph.depth_cap}/)
    # one spawn per level, and the cap is the ceiling — not one turn more
    spawned = event_stream.events.count { |e| e.type == :subagent_started }
    expect(spawned).to eq(Insika::SubagentGraph.depth_cap)
  end

  it "a missing delegate agent fails the turn configurally (never fabricates the reply)" do
    llm = RoutingLLMDouble.new("order")
    executor = build_executor(llm, profiles: {}) # order-agent NOT configured
    run_turn(executor, make_task("cadê meu pedido", id: "r5"), FakeChat.new)

    stored = task_store.find("r5")
    expect(stored.status).to eq(:failed)
    expect(stored.executions.last.error).to include("class" => "Insika::RoutingError",
                                                    "stage" => "routing",
                                                    "message" => /route delegate agent 'order-agent' not configured/)
  end
end