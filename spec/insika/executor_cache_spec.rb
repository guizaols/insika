# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0030 C5 + E2 — the acceptance gate, end-to-end through the REAL Executor
# and the REAL ContextBuilder. Turn 1 then turn 2: the prefix fingerprint of
# the identity categories is byte-stable (E1's discard condition), a mutated
# volatile category names itself as the invalidation reason, and the provider-
# reported cached_tokens stamp the trace entry and the agent's cache series
# (CacheSeriesStore) after stage 8.
RSpec.describe "Insika::Executor — layered identity cache (RFC-0030 E2)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:context_trace_store) { Insika::ContextTraceStore.new(store: backend) }
  let(:cache_series_store) { Insika::CacheSeriesStore.new(store: backend) }

  # Scripted providers: an identity half (config-stable) and a volatile half
  # whose content the test mutates between turns. The real Builder stamps the
  # layers at production, exactly like the builtin providers would.
  def identity_provider(content: "você é a Bia")
    Class.new(Insika::ContextProvider) do
      define_method(:id) { "Insika::Context::Providers::Prompt" }
      define_method(:layer) { :identity }
      define_method(:call) do |_req|
        [Insika::ContextFragment.build(content: content, placement: :system,
                                       source: id, priority: 100, pinned: true,
                                       tokens: content.length)]
      end
    end.new
  end

  def volatile_provider(get_content:)
    Class.new(Insika::ContextProvider) do
      define_method(:id) { "Insika::Context::Providers::Memory" }
      define_method(:layer) { :volatile }
      define_method(:call) do |_req|
        content = get_content.call
        return [] if content.to_s.strip.empty? # like the real provider: no facts -> no fragment

        [Insika::ContextFragment.build(content: content, placement: :system,
                                       source: id, priority: 75, tokens: 100)]
      end
    end.new
  end

  let(:memory_holder) { { fact: "<memory>cliente: ana</memory>" } }
  let(:providers) do
    [identity_provider, volatile_provider(get_content: -> { memory_holder[:fact] })]
  end

  def build_executor(cache_series: true)
    Insika::Executor.new(
      context_builder: Insika::ContextBuilder.new(providers: providers, event_stream: event_stream),
      policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      context_trace_store: context_trace_store,
      cache_series_store: cache_series ? cache_series_store : nil
    )
  end

  let(:profile) { Insika::AgentProfile.build(id: "store", model: "gpt", base_prompt: "SOUL") }

  before { session_store.create(id: "s1") }

  def run_turn(executor, chat, task_id:)
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "store", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: task_id)
    Sync do
      executor.spawn(task_store.find(task_id), profile: profile)
      executor.instance_variable_get(:@running)[task_id]&.wait
    end
  end

  # A chat whose ask reports usage like a real provider: cached 8000 / input 10000.
  # A chat whose ask reports usage the way RubyLLM 1.16 actually does: the pilot's
  # ~22k cached identity is DISJOINT from the ~500 fresh input (cached_tokens is
  # never a subset of input_tokens). billed = 500 + 22000 + 0 = 22500.
  def token_chat
    FakeChat.new.tap do |chat|
      chat.define_singleton_method(:ask) do |message, &on_chunk|
        @asked = message
        on_chunk&.call(FakeChat::Response.new("final"))
        Object.new.tap do |o|
          o.define_singleton_method(:input_tokens) { 500 }
          o.define_singleton_method(:output_tokens) { 2_000 }
          o.define_singleton_method(:cached_tokens) { 22_000 }
          o.define_singleton_method(:cache_creation_tokens) { 0 }
          o.define_singleton_method(:model_id) { "gpt" }
        end
      end
    end
  end

  def chat(final: "final")
    FakeChat.new.tap { |c| c.final_content = final }
  end

  it "turn 1 then turn 2 (new message only): identity fingerprints equal, invalidation_reason nil" do
    run_turn(build_executor, chat, task_id: "t1")
    run_turn(build_executor, chat, task_id: "t2")

    entries = context_trace_store.for_session("s1")
    expect(entries.size).to eq(2)
    first, second = entries
    expect(first["fingerprints"]).to be_a(Hash)
    expect(second["fingerprints"]).to be_a(Hash)
    expect(second["fingerprints"]["prompt"]).to eq(first["fingerprints"]["prompt"])
    expect(second["fingerprints"]["prefix"]).to eq(first["fingerprints"]["prefix"])
    expect(first.dig("cache", "invalidation_reason")).to be_nil
    expect(second.dig("cache", "invalidation_reason")).to be_nil
  end

  it "E2's 'the reason is right': a mutated volatile category names itself" do
    run_turn(build_executor, chat, task_id: "t1")
    memory_holder[:fact] = "<memory>cliente: maria</memory>"
    run_turn(build_executor, chat, task_id: "t2")

    entries = context_trace_store.for_session("s1")
    first, second = entries
    expect(second["fingerprints"]["prompt"]).to eq(first["fingerprints"]["prompt"])
    expect(second["fingerprints"]["memory"]).not_to eq(first["fingerprints"]["memory"])
    expect(second.dig("cache", "invalidation_reason")).to eq("memory")
  end

  it "the trace categories carry the layer stamped by the Builder" do
    run_turn(build_executor, chat, task_id: "t1")
    cats = context_trace_store.for_session("s1").first["categories"]
    expect(cats["prompt"]["layer"]).to eq("identity")
    expect(cats["memory"]["layer"]).to eq("volatile")
  end

  it "a provider reporting cached_tokens stamps hit_pct on the trace and one entry on the series" do
    run_turn(build_executor, token_chat, task_id: "t1")

    # 22000 cached / 22500 billed (input 500 + cached 22000 + creation 0) -> 98.
    entry = context_trace_store.for_session("s1").first
    expect(entry.dig("cache", "hit_pct")).to eq(98)
    expect(entry.dig("cache", "cached_tokens")).to eq(22_000)
    expect(entry.dig("cache", "prompt_tokens")).to eq(22_500) # the BILLED prompt, not the fresh input

    series = cache_series_store.for_agent("store")
    expect(series.size).to eq(1)
    expect(series.first).to include("hit_pct" => 98, "cached_tokens" => 22_000,
                                    "prompt_tokens" => 22_500, "turn" => 1)
    expect(series.first["invalidation_reason"]).to be_nil
  end

  it "a FULL cache hit (fresh input 0) reads as 100%, never as '—'" do
    full_chat = FakeChat.new
    full_chat.define_singleton_method(:ask) do |message, &on_chunk|
      @asked = message
      on_chunk&.call(FakeChat::Response.new("final"))
      Object.new.tap do |o|
        o.define_singleton_method(:input_tokens) { 0 }
        o.define_singleton_method(:output_tokens) { 2_000 }
        o.define_singleton_method(:cached_tokens) { 22_000 }
        o.define_singleton_method(:cache_creation_tokens) { 0 }
        o.define_singleton_method(:model_id) { "gpt" }
      end
    end
    run_turn(build_executor, full_chat, task_id: "t1")

    expect(context_trace_store.for_session("s1").first.dig("cache", "hit_pct")).to eq(100)
  end

  it "E2 vanished category: a block that leaves names itself, not the cumulative prefix" do
    run_turn(build_executor, chat, task_id: "t1")
    memory_holder[:fact] = "" # memory provider now emits nothing -> category gone
    run_turn(build_executor, chat, task_id: "t2")

    entries = context_trace_store.for_session("s1")
    first, second = entries
    expect(second["fingerprints"]["prompt"]).to eq(first["fingerprints"]["prompt"])
    expect(second["fingerprints"]).not_to have_key("memory")
    expect(second.dig("cache", "invalidation_reason")).to eq("memory")
  end

  it "the series is decoupled: wired without a context trace store, it still records" do
    executor = Insika::Executor.new(
      context_builder: Insika::ContextBuilder.new(providers: providers, event_stream: event_stream),
      policy_engine: NullPolicyEngine.new, middleware: PassthroughMiddleware.new,
      hooks: NullHooks.new, tool_registry: FakeToolRegistry.new,
      skill_catalog: Insika::SkillCatalog.new([]), profiles: {},
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      cache_series_store: cache_series_store
    )
    run_turn(executor, token_chat, task_id: "t1")

    expect(context_trace_store.for_session("s1")).to eq([])
    series = cache_series_store.for_agent("store")
    expect(series.size).to eq(1)
    expect(series.first).to include("hit_pct" => 98, "cached_tokens" => 22_000,
                                    "prompt_tokens" => 22_500)
    expect(series.first["invalidation_reason"]).to be_nil
  end

  it "hit_pct is honest about a provider with no cache counters (nil, never 0)" do
    run_turn(build_executor, chat, task_id: "t1") # FakeChat::Response has no tokens
    entry = context_trace_store.for_session("s1").first
    expect(entry.dig("cache", "hit_pct")).to be_nil
    expect(cache_series_store.for_agent("store").first["hit_pct"]).to be_nil
  end

  it "no cache_series_store wired -> nothing recorded there, turn byte-identical" do
    run_turn(build_executor(cache_series: false), token_chat, task_id: "t1")
    expect(cache_series_store.for_agent("store")).to eq([])
    expect(task_store.find("t1").status).to eq(:completed)
  end

  it "no context_trace_store -> no fingerprints, no stamp, turn completes" do
    executor = Insika::Executor.new(
      context_builder: Insika::ContextBuilder.new(providers: providers, event_stream: event_stream),
      policy_engine: NullPolicyEngine.new, middleware: PassthroughMiddleware.new,
      hooks: NullHooks.new, tool_registry: FakeToolRegistry.new,
      skill_catalog: Insika::SkillCatalog.new([]), profiles: {},
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
    run_turn(executor, token_chat, task_id: "t1")
    expect(context_trace_store.for_session("s1")).to eq([])
    expect(task_store.find("t1").status).to eq(:completed)
  end
end
