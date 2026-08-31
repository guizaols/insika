# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0044 — in-session compaction end-to-end, the P28 acceptance gate: a
# long session's turn triggers the post-turn compaction (real SummarizerFactory
# over an injected fake LLM), the boundary persists, and the NEXT turn's model
# sees ONE <conversation_summary> message + the verbatim tail — a fact stated
# at "turn 3" survives, and the turn never hits a ContextError.
RSpec.describe "Insika::Executor — in-session compaction end-to-end" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:context_trace_store) { Insika::ContextTraceStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:settings_store) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "fake", base_prompt: "SOUL") }
  let(:profiles) { { "sales" => profile } }

  # The REAL SummarizerFactory path (ruby_llm_ask over the injected llm seam):
  # chat -> with_temperature(0) -> ask(prompt) -> a content-bearing answer.
  # The fake "summarizes" by echoing the fact the acceptance requires to survive.
  class FakeSummarizerLLM
    Answer = Struct.new(:content)
    attr_reader :prompts, :chats

    def initialize(summary)
      @summary = summary
      @prompts = []
      @chats = []
    end

    def chat(model:, provider:, assume_model_exists:)
      @chats << { model: model, provider: provider, assume: assume_model_exists }
      self
    end

    def with_temperature(_t) = self

    def ask(prompt)
      @prompts << prompt
      Answer.new(@summary)
    end
  end

  let(:llm) { FakeSummarizerLLM.new("Resumo: cliente informou o CEP 30140-071 no início da conversa.") }

  let(:context_builder) do
    providers = [
      Insika::Context::Providers::Prompt.new(base: "", catalog: nil),
      Insika::Context::Providers::Session.new(session_store: session_store)
    ]
    Insika::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: Insika::Hooks.new)
  end

  let(:executor) do
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      settings_store: settings_store, context_trace_store: context_trace_store,
      llm: llm
    )
  end

  before do
    settings_store.update("utility_model" => "deepseek/deepseek-v4-flash",
                          "compaction" => { "enabled" => true, "keep_last" => 10, "compact_after" => 20 })
    session_store.create(id: "s1")
    # the "60-turn session": a long transcript, with the acceptance fact at turn 3.
    60.times do |i|
      content = i == 4 ? "meu CEP é 30140-071" : "mensagem #{i}"
      session_store.append_messages("s1", { role: i.even? ? :user : :assistant, content: content })
    end
  end

  def run_turn(task_id:)
    chat = FakeChat.new
    chat.final_content = "ok"
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: task_id)
    Sync do
      executor.spawn(task_store.find(task_id), profile: profile)
      executor.instance_variable_get(:@running)[task_id]&.wait
    end
    [task_store.find(task_id), chat]
  end

  it "turn 1 compacts post-turn: boundary persisted, event emitted, prompt carries the fact" do
    task, = run_turn(task_id: "t1")
    expect(task.status).to eq(:completed)

    # 62 messages after the turn (60 + user/assistant), keep_last 10 -> upto 52.
    state = session_store.find("s1").compaction
    expect(state).to include("upto" => 52, "runs" => 1, "model" => "deepseek/deepseek-v4-flash")
    expect(state["summary"]).to include("CEP 30140-071")

    # the summarize prompt carried the turn-3 fact and the engine preserve rules.
    expect(llm.prompts.first).to include("meu CEP é 30140-071")
    expect(llm.chats.first).to eq({ model: "deepseek-v4-flash", provider: "deepseek", assume: true })

    ev = event_stream.events.find { |e| e.type == :context_compacted }
    expect(ev.data).to include(agent: "sales", from: 0, upto: 52, messages: 52, runs: 1)
    expect(ev.data.values.join).not_to include("CEP") # counts and ids only
  end

  it "turn 2 reads the boundary: ONE summary message + the verbatim tail, fact intact, no ContextError" do
    run_turn(task_id: "t1")
    _task, chat = run_turn(task_id: "t2")

    seeded = chat.messages.map { |m| m[:content].to_s }
    summaries = seeded.grep(/<conversation_summary>/)
    expect(summaries.size).to eq(1)
    expect(summaries.first).to include("CEP 30140-071") # the turn-3 fact survives
    expect(seeded.first).to include("<conversation_summary>") # rendered FIRST
    expect(seeded).not_to include("mensagem 0") # the old prefix is gone…
    expect(seeded).to include("mensagem 59")    # …the tail is verbatim

    # the trace carries the compaction state + the summary as its own category.
    entry = context_trace_store.for_session("s1").last
    expect(entry["compaction"]).to eq("upto" => 52, "runs" => 1)
    expect(entry["categories"]).to have_key("compaction")
  end

  it "the boundary is STABLE: turn 2 below the threshold re-compacts nothing" do
    run_turn(task_id: "t1")
    run_turn(task_id: "t2")
    expect(session_store.find("s1").compaction["runs"]).to eq(1)
    expect(event_stream.events.count { |e| e.type == :context_compacted }).to eq(1)
  end

  it "a summarizer failure changes nothing (best-effort): no state, no event, turn still completed" do
    allow(llm).to receive(:ask).and_raise(StandardError, "provider down")
    task, = run_turn(task_id: "t1")
    expect(task.status).to eq(:completed)
    expect(session_store.find("s1").compaction).to be_nil
    expect(event_stream.events.map(&:type)).not_to include(:context_compacted)
  end

  it "disabled (the default elsewhere) = parity: nothing runs, nothing persists" do
    settings_store.update("compaction" => { "enabled" => false })
    run_turn(task_id: "t1")
    expect(session_store.find("s1").compaction).to be_nil
    expect(llm.prompts).to be_empty
  end
end
