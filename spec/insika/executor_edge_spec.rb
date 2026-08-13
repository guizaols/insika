# frozen_string_literal: true

require "spec_helper"
require "async"

# End-to-end EdgeLimiter behavior through the real Executor pipeline (
# the blocked turn completes gracefully with ZERO LLM calls AND stays out
# of the session history (a flood must not bloat the session / poison the context).
RSpec.describe "Insika::Executor + EdgeLimiter" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:ledger) { Insika::UsageLedger.new(store: Insika::Stores::Memory.new) }
  let(:profile) do
    Insika::AgentProfile.build(id: "example-agent", model: "gpt", base_prompt: "SOUL",
                                limits: { chat_rate_limit: 1 })
  end

  def build_executor
    edge = Insika::EdgeLimiter.new(ledger: ledger)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([edge, guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory
    )
  end

  def make_task(message, id:)
    command = Insika::Command.build(:send_message, { agent: "example-agent", message: message })
    task_store.create(command: command.to_h, session_id: "s1", id: id)
  end

  def run_turn(executor, task, fake_chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(fake_chat)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  before { session_store.create(id: "s1") }

  it "blocks the turn past the limit with zero LLM calls and keeps it OUT of the session" do
    executor = build_executor
    run_turn(executor, make_task("oi", id: "t1"))
    after_first = session_store.find("s1").messages.size
    expect(after_first).to be > 0 # the admitted turn persisted normally

    chat = FakeChat.new
    run_turn(executor, make_task("oi de novo", id: "t2"), fake_chat: chat)

    expect(chat.asked).to be_nil # the LLM was never touched
    expect(task_store.find("t2").status).to eq(:completed) # graceful, not a failure

    blocked = event_stream.events.find { |e| e.type == :guardrail_blocked }
    expect(blocked.data).to include(category: "rate_limit", source: "edge")

    # the flood exchange did NOT enter the session history (audit = the event)
    expect(session_store.find("s1").messages.size).to eq(after_first)
  end

  describe "WS2 calendar budgets" do
    let(:budget_ledger) { Insika::BudgetLedger.new(store: Insika::Stores::Memory.new) }

    def budget_profile(budget)
      Insika::AgentProfile.build(id: "example-agent", model: "gpt", base_prompt: "SOUL",
                                  budget: budget)
    end

    def budget_executor(prof)
      edge = Insika::EdgeLimiter.new(ledger: ledger, budget_ledger: budget_ledger,
                                     event_stream: event_stream)
      Insika::Executor.new(
        context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
        middleware: Insika::MiddlewareStack.new([edge, guardrails.input_guardrail]),
        hooks: Insika::Hooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
        profiles: {}, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, event_stream: event_stream,
        content_filter_factory: guardrails.content_filter_factory
      )
    end

    def make_tenant_task(message, id:, tenant: nil)
      command = Insika::Command.build(:send_message,
                                      { agent: "example-agent", message: message }, tenant: tenant)
      task_store.create(command: command.to_h, session_id: "s1", id: id)
    end

    def run_with(executor, task, prof, chat: FakeChat.new)
      allow(executor).to receive(:create_chat).and_return(chat)
      Sync do
        executor.spawn(task, profile: prof)
        executor.instance_variable_get(:@running)[task.id]&.wait
      end
    end

    def warnings = event_stream.events.count { |e| e.type == :budget_warning }

    it "HARD: exhausting the daily budget mid-day -> typed BudgetExceeded, zero LLM, ONE alert" do
      executor = budget_executor(budget_profile("daily" => 1_000, "soft" => false))

      # the day accumulates to the alert_at crossing (80%) -> the ONE event
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 800)
      chat = FakeChat.new
      run_with(executor, make_tenant_task("oi", id: "b1"), budget_profile("daily" => 1_000, "soft" => false),
               chat: chat)
      expect(chat.asked).not_to be_nil # 800 < 1000: the turn runs
      expect(warnings).to eq(1)

      # later the same day the cap is reached
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 200)
      run_with(executor, make_tenant_task("oi", id: "b2"), budget_profile("daily" => 1_000, "soft" => false),
               chat: FakeChat.new)

      stored = task_store.find("b2")
      expect(stored.status).to eq(:failed)
      error = stored.executions.last.error
      expect(error).to include("class" => "Insika::BudgetExceeded",
                               "stage" => "budget", # the executor's single capture classifies it
                               "kind" => "budget_exceeded", "retryable" => true)
      expect(error["retry_after"]).to be_between(0, 86_400) # seconds until the window rolls
      expect(task_store.find("b1").status).to eq(:completed) # earlier turns are untouched
      expect(warnings).to eq(1) # hard breach never re-emits: exactly one alert along the way
    end

    it "SOFT: over the cap the turn runs, warns once per window and injects the context note" do
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 1_000)
      executor = budget_executor(budget_profile("daily" => 1_000, "soft" => true))

      chat = FakeChat.new
      run_with(executor, make_tenant_task("oi", id: "c1"), budget_profile("daily" => 1_000, "soft" => true),
               chat: chat)

      expect(task_store.find("c1").status).to eq(:completed) # ran, with zero LLM refusal
      expect(chat.asked).not_to be_nil
      expect(warnings).to eq(1)
      expect(chat.instructions).to include("[budget: agent 'example-agent'")

      # a second past-cap turn keeps running but does NOT re-emit the event
      chat2 = FakeChat.new
      run_with(executor, make_tenant_task("oi", id: "c2"), budget_profile("daily" => 1_000, "soft" => true),
               chat: chat2)
      expect(task_store.find("c2").status).to eq(:completed)
      expect(warnings).to eq(1)
    end

    it "SOFT: the 80% alert and the REAL cap crossing are two events — the cap is never swallowed by alert_at (WS2)" do
      executor = budget_executor(budget_profile("daily" => 1_000, "soft" => true))

      # the 80% crossing warns once, level "alert_at"
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 800)
      run_with(executor, make_tenant_task("oi", id: "f1"), budget_profile("daily" => 1_000, "soft" => true))
      expect(warnings).to eq(1)
      first = event_stream.events.find { |e| e.type == :budget_warning }
      expect(first.data).to include(level: "alert_at", spent: 800)

      # the cap crossing is a DISTINCT event (its own marker), even though the
      # alert_at one already fired this window
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 500) # now 1300 > 1000
      run_with(executor, make_tenant_task("oi", id: "f2"), budget_profile("daily" => 1_000, "soft" => true))
      expect(warnings).to eq(2)
      second = event_stream.events.select { |e| e.type == :budget_warning }.last
      expect(second.data).to include(level: "cap", spent: 1300)

      # a third past-cap turn stays silent (the cap marker is set)
      run_with(executor, make_tenant_task("oi", id: "f3"), budget_profile("daily" => 1_000, "soft" => true))
      expect(warnings).to eq(2)
    end

    it "records the BILLED spend (cached tokens included — the A4 rule) on both windows" do
      executor = budget_executor(budget_profile("daily" => 5_000))
      token_chat = FakeChat.new
      token_chat.define_singleton_method(:ask) do |message, &on_chunk|
        @asked = message
        on_chunk&.call(FakeChat::Response.new("final"))
        resp = Object.new.tap do |o|
          o.define_singleton_method(:input_tokens) { 300 }
          o.define_singleton_method(:output_tokens) { 200 }
          o.define_singleton_method(:cached_tokens) { 500 }
          o.define_singleton_method(:cache_creation_tokens) { 0 }
        end
        resp
      end

      run_with(executor, make_tenant_task("oi", id: "e1"), budget_profile("daily" => 5_000),
               chat: token_chat)

      expect(budget_ledger.current(tenant: nil, agent: "example-agent"))
        .to eq(daily: 1_000, monthly: 1_000) # 300+200 total + 500 cached
    end

    # A tenant-scoped /v1/events subscription is fail-closed on meta[:tenant]:
    # a warning that carries the tenant only in its PAYLOAD is invisible to the
    # very tenant whose budget it is about.
    it "budget_warning carries the tenant on the META (the tenant's own stream sees it)" do
      prof = budget_profile("daily" => 1_000, "soft" => true)
      executor = budget_executor(prof)
      budget_ledger.add(tenant: "loja-a", agent: "example-agent", by: 900)

      run_with(executor, make_tenant_task("oi", id: "g1", tenant: "loja-a"), prof)

      warning = event_stream.events.find { |e| e.type == :budget_warning }
      expect(warning.meta).to include(tenant: "loja-a")
      expect(Insika::EventStream::Subscription.new(tenant: "loja-a").matches?(warning)).to be(true)
      expect(Insika::EventStream::Subscription.new(tenant: "loja-b").matches?(warning)).to be(false)
    end

    it "a platform turn (no tenant) leaves the meta byte-identical to before" do
      prof = budget_profile("daily" => 1_000, "soft" => true)
      executor = budget_executor(prof)
      budget_ledger.add(tenant: nil, agent: "example-agent", by: 900)

      run_with(executor, make_tenant_task("oi", id: "g2"), prof)

      warning = event_stream.events.find { |e| e.type == :budget_warning }
      expect(warning.meta.key?(:tenant)).to be(false)
    end

    it "the window is per (tenant, agent): one tenant's exhaustion does not touch the other" do
      budget_ledger.add(tenant: "loja-a", agent: "example-agent", by: 1_000) # A's cell spent
      prof = budget_profile("daily" => 1_000) # soft absent = HARD
      executor = budget_executor(prof)

      # tenant B runs freely...
      chat = FakeChat.new
      run_with(executor, make_tenant_task("oi", id: "d1", tenant: "loja-b"), prof, chat: chat)
      expect(task_store.find("d1").status).to eq(:completed)
      expect(chat.asked).not_to be_nil

      # ...while tenant A is at the wall
      run_with(executor, make_tenant_task("oi", id: "d2", tenant: "loja-a"), prof)
      expect(task_store.find("d2").status).to eq(:failed)
      expect(task_store.find("d2").executions.last.error["class"]).to eq("Insika::BudgetExceeded")
    end
  end
end
