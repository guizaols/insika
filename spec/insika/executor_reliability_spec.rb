# frozen_string_literal: true

require "spec_helper"
require "async"

# WS3 end-to-end through the real Executor: provider down -> the fallback
# model answers and the turn's USAGE is attributed to it; a tripped circuit
# fail-fasts the turn in ms with the typed error + retry_after.
RSpec.describe "Insika::Executor + Reliability (WS3)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:circuit_state) { Insika::CircuitState.new(store: Insika::Stores::Memory.new) }

  # The WS3 coordinator under test: real breaker, no real backoff sleeps.
  let(:reliability) do
    Insika::Reliability.new(circuit_store: circuit_state, event_stream: event_stream,
                            sleeper: ->(_s) { nil })
  end

  let(:profile) do
    Insika::AgentProfile.build(
      id: "example-agent", model: "deepseek-v4-flash",
      reliability: { "retries" => 0, "backoff" => "exponential",
                     "fallback" => ["openai/gpt-4o-mini"],
                     "circuit_breaker" => { "after" => 10, "within" => 60, "cooldown" => 300 } }
    )
  end

  PRIMARY = "deepseek/deepseek-v4-flash"

  def build_executor
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory,
      reliability: reliability
    )
  end

  def make_task(message, id:, tenant: nil)
    command = Insika::Command.build(:send_message, { agent: "example-agent", message: message },
                                    tenant: tenant)
    task_store.create(command: command.to_h, session_id: "s1", id: id)
  end

  def run_turn(executor, task, chat, profile: self.profile)
    allow(executor).to receive(:create_chat) do |_profile, st|
      st.model_selection = Insika::ModelSelection.new(model: "deepseek-v4-flash",
                                                      provider: :deepseek, source: :agent)
      chat
    end
    # the fallback attempt's chat (the coordinator rotates through a rebuilt chat)
    allow(executor).to receive(:build_chat) { |_sel, _params| fallback_chat }
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  let(:primary_chat) { FakeChat.new }
  let(:fallback_chat) { FakeChat.new }

  before { session_store.create(id: "s1") }

  def spy_error_chat(chat)
    chat.define_singleton_method(:ask) { |_message, &_blk| raise RubyLLM::ServerError.new("down") }
  end

  it "provider down -> the fallback model answers and the usage is attributed to IT" do
    executor = build_executor
    spy_error_chat(primary_chat)
    fallback_chat.define_singleton_method(:ask) do |message, &on_chunk|
      @asked = message
      on_chunk&.call(FakeChat::Response.new("final"))
      resp = Object.new.tap do |o|
        o.define_singleton_method(:input_tokens) { 10 }
        o.define_singleton_method(:output_tokens) { 5 }
        o.define_singleton_method(:cached_tokens) { 0 }
        o.define_singleton_method(:cache_creation_tokens) { 0 }
      end
      resp
    end

    run_turn(executor, make_task("oi", id: "r1"), primary_chat)

    expect(task_store.find("r1").status).to eq(:completed)
    expect(fallback_chat.asked).to eq("oi") # the fallback really answered
    completed = event_stream.events.find { |e| e.type == :task_completed }
    # "contabilizado no trace": the turn's usage names the FALLBACK model.
    expect(completed.data[:usage]).to include(model: "gpt-4o-mini", model_source: :fallback)
  end

  it "10 failures in 60s -> the circuit OPEN fail-fasts the NEXT turn with retry_after" do
    10.times do
      circuit_state.record_failure(tenant: nil, ref: PRIMARY, after: 10, within: 60)
    end
    executor = build_executor
    chat = FakeChat.new

    run_turn(executor, make_task("oi", id: "r2"), chat)

    stored = task_store.find("r2")
    expect(stored.status).to eq(:failed)
    error = stored.executions.last.error
    expect(error).to include("class" => "Insika::CircuitOpenError",
                             "stage" => "reliability",
                             "kind" => "circuit_open", "retryable" => true)
    expect(error["retry_after"]).to eq(300)
    # the provider was never touched
    task_started = task_store.find("r2")
    expect(task_started.executions.last.error["class"]).to eq("Insika::CircuitOpenError")
  end

  # A fallback ref that names the PRIMARY's own model, spelled without the
  # provider, is the same physical model — it must be DEDUPED, never re-asked
  # as if it were a second chance (WS3).
  it "a bare-model fallback equal to the primary is deduped, not tried again" do
    dedupe_profile = Insika::AgentProfile.build(
      id: "example-agent", model: "deepseek-v4-flash",
      reliability: { "retries" => 0, "backoff" => "exponential",
                     "fallback" => ["deepseek-v4-flash"], # == the primary
                     "circuit_breaker" => { "after" => 10, "within" => 60, "cooldown" => 300 } }
    )
    executor = build_executor
    spy_error_chat(primary_chat) # the primary is down

    run_turn(executor, make_task("oi", id: "r6"), primary_chat, profile: dedupe_profile)

    # the chain dropped the duplicate node: the turn failed instead of re-asking
    # the same dead model as its own fallback
    expect(task_store.find("r6").status).to eq(:failed)
    expect(fallback_chat.asked).to be_nil
  end

  it "a NON-reliability profile keeps the plain single-ask path (parity)" do
    plain = Insika::AgentProfile.build(id: "example-agent", model: "deepseek-v4-flash")
    executor = Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory,
      reliability: reliability
    )
    chat = FakeChat.new
    allow(executor).to receive(:create_chat) do |_profile, st|
      st.model_selection = Insika::ModelSelection.new(model: "deepseek-v4-flash",
                                                      provider: :deepseek, source: :agent)
      chat
    end

    Sync do
      executor.spawn(make_task("oi", id: "r3"), profile: plain)
      executor.instance_variable_get(:@running)["r3"]&.wait
    end

    expect(task_store.find("r3").status).to eq(:completed)
    expect(chat.asked).to eq("oi") # EXACTLY one ask, no coordinator in the path
  end

  it "with INSIKA_TURN_TIMING the first content chunk emits the live :ttft (WS6)" do
    ENV["INSIKA_TURN_TIMING"] = "1"
    executor = build_executor
    chat = FakeChat.new

    run_turn(executor, make_task("oi", id: "r4"), chat)

    ttft = event_stream.events.find { |e| e.type == :ttft }
    expect(ttft).not_to be_nil
    expect(ttft.data[:ttft_ms]).to be >= 0
  ensure
    ENV.delete("INSIKA_TURN_TIMING")
  end

  # The old code re-emitted :ttft on EVERY content chunk (a probe showed 3
  # chunks = 3 insika.ttft frames); the fixture passed because it streams one
  # chunk. A multi-chunk response must still emit exactly one TTFB signal.
  it "emits EXACTLY ONE :ttft per turn, even across many content chunks (WS6)" do
    ENV["INSIKA_TURN_TIMING"] = "1"
    executor = build_executor
    chat = FakeChat.new
    chat.script = proc { 3.times { |i| emit_chunk("chunk #{i} ") } }

    run_turn(executor, make_task("oi", id: "r5"), chat)

    ttfts = event_stream.events.select { |e| e.type == :ttft }
    expect(ttfts.size).to eq(1)
    expect(ttfts.first.data[:ttft_ms]).to be >= 0
  ensure
    ENV.delete("INSIKA_TURN_TIMING")
  end
end