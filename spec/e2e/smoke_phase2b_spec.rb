# frozen_string_literal: true

require "spec_helper"
require "async"
# The Executor loads them lazily in create_chat; here create_chat is stubbed, so
# we require them explicitly (same discipline as executor_chat_spec).
require "insika/tools/load_skill"
require "insika/tools/tool_search"

# E2E smoke for: CommandBus + SendMessage + Executor + mocked
# RubyLLM (FakeChat via create_chat stub). REAL components: CapabilityRegistry,
# ToolRegistry, Policy::Engine+ToolAllowlist, ToolCatalog, AgentProfile — only the
# `chat` is a double. No crash/reboot dimension (doesn't have one), so
# in-process, no subprocess (unlike's smoke_resume).
RSpec.describe "smoke E2E: capability resolution + tool search",:smoke do
  # A tool raw enough for Registry/ToolEnvelope/ResolvedTool (respond_to? only).
  class FakeCapTool
    def initialize(name) = (@name = name)
    def name = @name
    def description = "fake #{@name}"
    def parameters = {} # a real RubyLLM tool always responds to this (used by tool_search#describe)
    def call(_args = {}) = "executed:#{@name}"
  end

  let(:backend)          { Insika::Stores::Memory.new }
  let(:session_store)    { Insika::SessionStore.new(store: backend) }
  let(:task_store)       { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }

  let(:tool_registry)       { Insika::ToolRegistry.new }
  let(:capability_registry) { Insika::CapabilityRegistry.new }
  let(:tool_catalog)        { Insika::ToolCatalog.new(tool_registry: tool_registry) }

  let(:policy_registry) do
    Insika::PolicyRegistry.new.tap { |r| r.register(:tool_allowlist, Insika::Policy::Builtin::ToolAllowlist) }
  end
  let(:policy_engine) { Insika::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream) }

  let(:profiles) do
    {
      "cap_top" => Insika::AgentProfile.build(
        id: "cap_top", model: "fake", policies: [:tool_allowlist], capabilities: [:browse]
      ),
      "cap_deny_top" => Insika::AgentProfile.build(
        id: "cap_deny_top", model: "fake", policies: [:tool_allowlist],
        capabilities: [:browse], tools_deny: ["browser_b"]
      ),
      "cap_ambiguous" => Insika::AgentProfile.build(
        id: "cap_ambiguous", model: "fake", policies: [:tool_allowlist], capabilities: [:ambiguous_cap]
      ),
      "deferred_ok" => Insika::AgentProfile.build(
        id: "deferred_ok", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email], tools_deferred: ["send_email"]
      ),
      "deferred_nil" => Insika::AgentProfile.build(
        id: "deferred_nil", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email] # tools_deferred: nil (default) — parity
      )
    }
  end

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: policy_engine,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: tool_registry, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      capability_registry: capability_registry, tool_catalog: tool_catalog
    )
  end

  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:send_message,
                 Insika::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end

  before do
    %w[browser_a browser_b browser_c impl_x impl_y eager_tool send_email].each do |n|
      tool_registry.register(n) { FakeCapTool.new(n) }
    end

    # :browse — a=10/p1, b=50/p2, c=100/p3 but UNAVAILABLE. With the filter, "b" wins.
    capability_registry.register(:browse, impl_name: "browser_a", kind: :tool, plugin: "p1", priority: 10)
    capability_registry.register(:browse, impl_name: "browser_b", kind: :tool, plugin: "p2", priority: 50)
    capability_registry.register(:browse, impl_name: "browser_c", kind: :tool, plugin: "p3", priority: 100,
                                          available: -> { false })

    # :ambiguous_cap — 2 providers from the SAME plugin, same priority (L4 -> Ambiguous).
    capability_registry.register(:ambiguous_cap, impl_name: "impl_x", kind: :tool, plugin: "pA", priority: 50)
    capability_registry.register(:ambiguous_cap, impl_name: "impl_y", kind: :tool, plugin: "pA", priority: 50)
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # One-shot (no session_id) doesn't go through the SessionActor — straight to spawn.
  def run_turn(agent:, chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = bus.dispatch(Insika::Command.build(:send_message, { agent: agent, message: "oi" }))
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end

  it "resolves to the highest available priority; discards unavailable; emits :capability_resolved (stable name)" do
    task, chat = run_turn(agent: "cap_top")
    expect(task.status).to eq(:completed)

    resolved = event_stream.events.find { |e| e.type == :capability_resolved }
    expect(resolved.data[:capability]).to eq(:browse)
    expect(resolved.data[:chosen]).to eq("browser_b") # "b" (50) beats "a" (10)
    expect(resolved.data[:candidates].map { |c| c[:impl_name] }).to contain_exactly("browser_a", "browser_b")

    tool = chat.tools.find { |t| t.respond_to?(:name) && t.name.to_s == "browse" }
    expect(tool).not_to be_nil                 # STABLE name exposed to the model
    expect(tool.impl_name).to eq("browser_b")  # real impl behind it (Envelope delegates)
  end

  it "tools_deny filters by impl_name WITHIN resolution (not just afterwards)" do
    task, = run_turn(agent: "cap_deny_top") # tools_deny: ["browser_b"]
    expect(task.status).to eq(:completed)
    resolved = event_stream.events.select { |e| e.type == :capability_resolved }.last
    expect(resolved.data[:chosen]).to eq("browser_a") # "b" denied -> next eligible
  end

  it "same-plugin tie -> CapabilityAmbiguous; turn fails at :capability; no :capability_resolved" do
    task, = run_turn(agent: "cap_ambiguous")
    expect(task.status).to eq(:failed)
    expect(task.executions.last.error["class"]).to eq("Insika::CapabilityAmbiguous")
    expect(task.executions.last.error["stage"]).to eq("capability")
    expect(event_stream.types).to include(:task_failed)
    expect(event_stream.types).not_to include(:error) # R2b: no legacy twin
    expect(event_stream.events.select { |e| e.type == :capability_resolved }).to be_empty
  end

  it "deferred out of the initial prompt; tool_search promotes; callable in the same turn; emits :tool_search" do
    initial_names = nil
    promoted_result = nil
    chat = FakeChat.new
    chat.script = proc do
      initial_names = tools.map { |t| t.name.to_s }
      ts = tools.find { |t| t.name.to_s == "tool_search" }
      ts.execute(query: "send email")
      promoted = tools.find { |t| t.name.to_s == "send_email" }
      promoted_result = promoted&.call({})
    end

    task, = run_turn(agent: "deferred_ok", chat: chat)
    expect(task.status).to eq(:completed)

    expect(initial_names).to include("eager_tool", "tool_search")
    expect(initial_names).not_to include("send_email") # deferred: out of the initial prompt
    expect(promoted_result).to eq("executed:send_email") # promoted + callable IN THE SAME turn

    ev = event_stream.events.find { |e| e.type == :tool_search }
    expect(ev.data[:query]).to eq("send email")
    expect(ev.data[:matched]).to include("send_email")
  end

  it "tools_deferred nil -> parity (all eager, no system tool_search)" do
    seen_names = nil
    chat = FakeChat.new
    chat.script = proc { seen_names = tools.map { |t| t.name.to_s } }

    task, = run_turn(agent: "deferred_nil", chat: chat)
    expect(task.status).to eq(:completed)

    expect(seen_names).to include("eager_tool", "send_email")
    expect(seen_names).not_to include("tool_search")
  end
end
