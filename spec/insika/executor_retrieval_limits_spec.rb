# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Executor retrieval admission and accounting" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:checkpoints) { Insika::CheckpointStore.new(store: backend) }
  let(:knowledge) { Insika::KnowledgeStore.new(store: backend) }
  let(:ledger) { Insika::UsageLedger.new(store: backend) }
  let(:budgets) { Insika::BudgetLedger.new(store: backend) }
  let(:events) { SpyEventStream.new }
  let(:rerank) { { provider: "cohere", model: "rerank-v3.5", candidate_limit: 2, timeout_seconds: 2 } }
  let(:profile) do
    Insika::AgentProfile.build(id: "a", model: "m", memory: true,
      knowledge: { retrieve: true, top_k: 1, rerank: rerank },
      memory_retrieval: { top_k: 1, rerank: rerank },
      limits: { chat_rate_limit: 2, agent_token_ceiling: 100 }, budget: { daily: 100, monthly: 1000 })
  end
  let(:llm) { double(rerank: Struct.new(:results).new([Struct.new(:index).new(0)])) }
  let(:limiter) { Insika::EdgeLimiter.new(ledger: ledger, budget_ledger: budgets, event_stream: events) }
  let(:middleware) { Insika::MiddlewareStack.new([limiter]) }
  let(:builder) do
    Insika::ContextBuilder.new(event_stream: events, providers: [
      Insika::Context::Providers::Knowledge.new(store: knowledge, llm: llm),
      Insika::Context::Providers::Memory.new(store: Insika::MemoryStore.new(store: backend), llm: llm)
    ])
  end
  let(:policy) { NullPolicyEngine.new }
  let(:executor) do
    Insika::Executor.new(context_builder: builder, policy_engine: policy,
      middleware: middleware, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "a" => profile }, session_store: sessions, task_store: tasks,
      checkpoint_store: checkpoints, event_stream: events)
  end
  let(:chat) { FakeChat.new }

  before do
    sessions.create(id: "s")
    sessions.append_messages("s", [{ "role" => "user", "content" => "prior turn" }])
    knowledge.write("a", "delivery", Insika::Knowledge::Concept.render(
      name: "delivery", description: "delivery", type: "fact", body: "private body",
      provenance: "observed", confidence: 0.6, sources: [], occurrences: 1,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601))
    Insika::MemoryStore.new(store: backend).put_fact(key: "delivery", value: "tomorrow", tenant: "chat:s")
    allow(executor).to receive(:create_chat).and_return(chat)
  end

  def run_turn(history: nil)
    task = tasks.create(id: "t", session_id: "s", command: Insika::Command.build(:send_message,
      { agent: "a", message: "delivery", history: history }).to_h)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
    tasks.find("t")
  end

  %w[chat tokens budget].each do |limit|
    it "blocks #{limit} before either paid retrieval provider" do
      case limit
      when "chat" then ledger.add("chat", "s", window: 60, by: 2)
      when "tokens" then ledger.add("tokens", "a", window: 86_400, by: 100)
      when "budget" then budgets.add(tenant: nil, agent: "a", by: 100)
      end
      expect(llm).not_to receive(:rerank)
      expect(executor).not_to receive(:create_chat)
      expect(run_turn.status).to eq(limit == "budget" ? :failed : :completed)
      expect(sessions.find("s").messages).to contain_exactly(include("role" => "user", "content" => "prior turn"))
      unless limit == "budget"
        expect(checkpoints.latest("t").messages.first).to include("content" => "prior turn")
      end
    end
  end

  it "counts admission once and supplies prepared context and the budget warning to plugins" do
    budgets.add(tenant: nil, agent: "a", by: 80)
    seen = []
    middleware << lambda { |state, &nxt|
      seen << state.context.system
      expect(state.allowed_tools).to eq([])
      nxt.call(state)
    }
    expect(run_turn.status).to eq(:completed)
    expect(llm).to have_received(:rerank).twice
    expect(ledger.count("chat", "s", window: 60)).to eq(1)
    expect(seen.size).to eq(1)
    expect(seen.first).to include("<knowledge>", "<memory>", "[budget:")
    expect(chat.instructions).to include("[budget:")
  end

  it "records each reported rerank attempt once even when policy then rejects the turn" do
    allow(builder).to receive(:call).and_wrap_original do |original, request|
      [[12, "failed"], [nil, "failed"], [5, "succeeded"]].each do |input, status|
        request.diagnostics.call(:llm_usage, { "operation" => "rerank", "request_id" => "paid-retries",
          "input_tokens" => input, "output_tokens" => nil, "cache_read_tokens" => nil,
          "cache_write_tokens" => nil, "cost" => nil, "status" => status })
      end
      original.call(request)
    end
    allow(policy).to receive(:decide).and_raise(Insika::PolicyDenied.new(policy: "test", reason: "deny"))
    expect(run_turn.status).to eq(:failed)
    expect(ledger.count("tokens", "a", window: 86_400)).to eq(17)
    expect(budgets.current(tenant: nil, agent: "a")).to include(daily: 17, monthly: 17)
    usage = events.events.find { |e| e.type == :llm_usage }
    expect(usage.data).to include("turn" => 1, "output_tokens" => nil, "cost" => nil)
    expect(usage.meta[:task_id]).to eq("t")
    expect(events.events.find { |e| e.type == :task_failed }.data[:usage]).to be_nil
  end

  context "with native RubyLLM rerank usage" do
    let(:llm) do
      RubyLLM.context { |config| config.cohere_api_key = "spec-rerank" }
    end

    it "adds both retrieval calls to spend while preserving chat totals and unknown fields" do
      requests = 0
      allow_any_instance_of(RubyLLM::Transport::Connection).to receive(:post).and_wrap_original do |original, *args, **kwargs, &block|
        original.receiver.connection.adapter :test do |stub|
          stub.post("/v2/rerank") do
            requests += 1
            [200, { "Content-Type" => "application/json" }, JSON.generate(
              results: [{ index: 0, relevance_score: 0.9 }], meta: { tokens: { input_tokens: 12 } })]
          end
        end
        original.call(*args, **kwargs, &block)
      end
      allow(chat).to receive(:ask).and_wrap_original do |original, *args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
        RubyLLM::Message.new(role: :assistant, content: "final", input_tokens: 5, output_tokens: 2)
      end
      expect(run_turn.status).to eq(:completed)
      expect(requests).to eq(2)
      expect(ledger.count("tokens", "a", window: 86_400)).to eq(31)
      expect(budgets.current(tenant: nil, agent: "a")).to include(daily: 31, monthly: 31)
      expect(events.events.find { |event| event.type == :task_completed }.data[:usage])
        .to include(input_tokens: 5, output_tokens: 2, total_tokens: 7)
      native = events.events.select { |event| event.type == :llm_usage }
      expect(native.size).to eq(2)
      native.each do |event|
        expect(event.meta[:task_id]).to eq("t")
        expect(event.data).to include("turn" => 1, "input_tokens" => 12, "output_tokens" => nil, "cost" => nil)
      end
    end
  end


  it "keeps explicit request history in an early refusal checkpoint" do
    ledger.add("tokens", "a", window: 86_400, by: 100)
    expect(run_turn(history: [{ "role" => "user", "content" => "explicit history" }]).status).to eq(:completed)
    expect(checkpoints.latest("t").messages.first).to include("content" => "explicit history")
  end

  context "with a custom middleware implementing only call(state)" do
    let(:middleware) { PassthroughMiddleware.new }

    it "preserves the middleware contract" do
      expect(run_turn.status).to eq(:completed)
      expect(llm).to have_received(:rerank).twice
    end
  end

  context "with lexical retrieval only" do
    let(:profile) do
      Insika::AgentProfile.build(id: "a", model: "m", memory: true, knowledge: { retrieve: true })
    end

    it "builds context before the existing middleware chain" do
      expect(builder).to receive(:call).ordered.and_call_original
      expect(limiter).to receive(:call).ordered.and_call_original
      expect(llm).not_to receive(:rerank)
      expect(run_turn.status).to eq(:completed)
    end
  end

end
