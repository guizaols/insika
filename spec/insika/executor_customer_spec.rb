# frozen_string_literal: true

require "spec_helper"
require "async"

# WS8 phase 1: the optional `customer` on the command moves the engine's
# memory scope from (tenant | session) to the CUSTOMER cell — and the session
# is stamped once so forget_customer can find the customer's conversations.
RSpec.describe "Insika::Executor + customer memory scope (WS8)" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }

  def build_executor
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory
    )
  end

  def task(message, customer: nil, tenant: nil, id: nil)
    payload = { agent: "a", message: message }
    payload[:customer] = customer if customer
    @task_n = (@task_n || 0) + 1
    task_store.create(command: Insika::Command.build(:send_message, payload, tenant: tenant).to_h,
                      session_id: "s1", id: id || "t-#{@task_n}")
  end

  describe "the memory scope derivation" do
    it "a customer + tenant -> the (tenant, customer) cell" do
      expect(build_executor.send(:memory_tenant, task("oi", customer: "123", tenant: "acme")))
        .to eq("acme:123")
    end

    it "a customer WITHOUT tenant -> the bare customer cell (never _default)" do
      expect(build_executor.send(:memory_tenant, task("oi", customer: "123")))
        .to eq("123")
    end

    it "no customer -> the explicit tenant, else the MARKED session cell (RFC-0031)" do
      expect(build_executor.send(:memory_tenant, task("oi", tenant: "acme"))).to eq("acme")
      expect(build_executor.send(:memory_tenant, task("oi"))).to eq("chat:s1")
    end
  end

  it "a turn with a customer stamps the session once, so forget_customer can find it" do
    session_store.create(id: "s1")
    executor = build_executor
    chat = FakeChat.new
    allow(executor).to receive(:create_chat).and_return(chat)

    Sync do
      executor.spawn(task("oi", customer: "123"), profile: Insika::AgentProfile.build(id: "a", model: "m"))
      executor.instance_variable_get(:@running)["t-1"]&.wait
    end

    expect(session_store.find("s1").vars["customer"]).to eq("123")
    # the <request_context> tenant label is untouched — the merchant, not the shopper
    expect(task_store.find("t-1").status).to eq(:completed)
  end

  # RFC-0034 C5: the agent stamp rides the same write — the distillation
  # engine resolves each session's pack through it (RunDistillation step 4).
  it "stamps vars['agent'] next to vars['customer'] on the tagged session" do
    session_store.create(id: "s1")
    executor = build_executor
    chat = FakeChat.new
    allow(executor).to receive(:create_chat).and_return(chat)

    Sync do
      executor.spawn(task("oi", customer: "123"),
                     profile: Insika::AgentProfile.build(id: "a", model: "m"))
      executor.instance_variable_get(:@running)["t-1"]&.wait
    end

    expect(session_store.find("s1").vars["customer"]).to eq("123")
    expect(session_store.find("s1").vars["agent"]).to eq("a")
  end

  # RFC-0031 E1/E2/E3 — the acceptance gate, end-to-end through the REAL
  # Executor + REAL ContextBuilder + REAL Memory provider. The trace holds
  # counts only (RFC-0023), so the assertion reads the CONTEXT PACKAGE's memory
  # fragment — the same thing the model sees.
  describe "RFC-0031 experiments (E1–E3)" do
    let(:memory_store) { Insika::MemoryStore.new(store: backend) }
    let(:profile) { Insika::AgentProfile.build(id: "a", model: "m", memory: true) }

    # Real Builder wrapped to capture the assembled ContextPackage per turn.
    def build_experiment_executor
      captured = nil
      inner = Insika::ContextBuilder.new(
        providers: [Insika::Context::Providers::Memory.new(store: memory_store)],
        event_stream: event_stream
      )
      builder = Class.new do
        define_method(:call) { |request| captured = inner.call(request) }
      end.new
      executor = Insika::Executor.new(
        context_builder: builder, policy_engine: NullPolicyEngine.new,
        middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
        tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
        profiles: {}, session_store: session_store, task_store: task_store,
        checkpoint_store: checkpoint_store, event_stream: event_stream,
        memory_store: memory_store
      )
      [executor, -> { captured }]
    end

    def memory_fragment(pkg)
      pkg&.fragments&.find { |f| f.source == "Insika::Context::Providers::Memory" }
    end

    def run_turn(executor, customer:, tenant: nil)
      chat = FakeChat.new
      allow(executor).to receive(:create_chat).and_return(chat)
      @n = (@n || 0) + 1
      payload = { agent: "a", message: "oi" }
      payload[:customer] = customer if customer
      task_store.create(command: Insika::Command.build(:send_message, payload, tenant: tenant).to_h,
                        session_id: "s1", id: "t-#{@n}")
      Sync do
        executor.spawn(task_store.find("t-#{@n}"), profile: profile)
        executor.instance_variable_get(:@running)["t-#{@n}"]&.wait
      end
      chat
    end

    it "E1 — an operator edit is live: turn 1 reads the stored fact, the corrected value rides turn 2" do
      memory_store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      executor, capture = build_experiment_executor
      session_store.create(id: "s1")

      run_turn(executor, customer: "c-1", tenant: "acme")
      expect(memory_fragment(capture.call).content).to include('<fact key="size">M</fact>')

      # the operator corrects it via the SAME command the Studio dispatches
      Insika::Commands::MemoryPutFact.new(memory_store: memory_store, event_stream: event_stream)
        .call(Insika::Command.build(:memory_put_fact, { tenant: "acme", customer: "c-1",
                                                        key: "size", value: "L", operator: "studio" }))

      run_turn(executor, customer: "c-1", tenant: "acme")
      expect(memory_fragment(capture.call).content).to include('<fact key="size">L</fact>')
    end

    it "E2 — forget forgets: the cell is empty, the next turn has no memory fragment, export is empty, audit has the purge line" do
      memory_store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      memory_store.add_note(tenant: "acme", customer: "c-1", text: "prefere email")
      audit = Insika::MemoryAuditStore.new(store: backend)
      executor, capture = build_experiment_executor
      session_store.create(id: "s1")

      Insika::Commands::ForgetCustomer.new(
        memory_store: memory_store, session_store: session_store, audit_store: audit,
        event_stream: event_stream
      ).call(Insika::Command.build(:forget_customer, { tenant: "acme", customer: "c-1", operator: "studio" }))

      expect(memory_store.facts(tenant: "acme", customer: "c-1")).to be_empty
      expect(memory_store.notes(tenant: "acme", customer: "c-1")).to be_empty

      # the discard condition: the provider query returns nothing on the next turn
      run_turn(executor, customer: "c-1", tenant: "acme")
      expect(memory_fragment(capture.call)).to be_nil

      export = Insika::Commands::ExportCustomerMemory.new(memory_store: memory_store, event_stream: event_stream)
                .call(Insika::Command.build(:export_customer_memory, { tenant: "acme", customer: "c-1" }))
      expect(export["counts"]).to eq({ "facts" => 0, "notes" => 0 })

      entry = audit.for_cell("memory:acme:c-1").first
      expect(entry.action).to eq("purge")
      expect(entry.note).to include("memory_records: 2")
    end

    it "E3 — tenant isolation end-to-end: a fact under tenant A never reaches tenant B's fragment" do
      memory_store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      executor, capture = build_experiment_executor
      session_store.create(id: "s1")

      run_turn(executor, customer: "c-1", tenant: "globex")

      expect(memory_fragment(capture.call)).to be_nil
      expect(memory_store.facts(tenant: "globex", customer: "c-1")).to be_empty
    end

    # RFC-0034 E1 — the proposal round trip: distill a finished session, approve
    # the proposal, and the NEXT turn's context package carries the fact (the
    # Memory provider reads the same cell the approval wrote).
    it "E1 (RFC-0034) — approve a distilled proposal and the fact rides the next turn" do
      distill_profile = Insika::AgentProfile.build(
        id: "a", model: "m", memory: true,
        distill: { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 }
      )
      proposals = Insika::ProposalStore.new(store: backend)
      session_store.create(id: "acme:old", vars: { "customer" => "c-1", "agent" => "a" })
      4.times { |i| session_store.append_messages("acme:old", { "role" => "user", "content" => "m#{i}" }) }
      record = session_store.find("acme:old").to_h
      record["updated_at"] = (Time.now.utc - 86_400).iso8601
      backend.set("sessions", "session:acme:old", record)

      distiller = Class.new do
        def distill(**)
          { proposals: [{ "name" => "size", "value" => "M", "confidence" => 0.9, "turns" => [1] }],
            dropped: { "schema" => 0, "unknown_key" => 0, "oversized" => 0,
                       "bad_turns" => 0, "duplicate" => 0, "capped" => 0 },
            cost: nil }
        end
      end.new
      factory = Class.new { def initialize(d) = (@d = d); def call(_c) = @d }.new(distiller)
      Insika::Commands::RunDistillation.new(
        profiles: { "a" => distill_profile }, proposal_store: proposals,
        session_store: session_store, memory_store: memory_store,
        settings_store: nil, event_stream: event_stream, distiller_factory: factory
      ).call(Insika::Command.build(:run_distillation, { session_id: "acme:old" }))
      proposal = proposals.pending(limit: 100).first
      expect(proposal).not_to be_nil
      expect(proposal.evidence).to eq([1]) # the evidence index resolved at distill time

      Insika::Commands::ResolveProposal.new(proposal_store: proposals,
                                            memory_store: memory_store,
                                            event_stream: event_stream)
        .call(Insika::Command.build(:resolve_proposal, { proposal_id: proposal.id,
                                                         decision: "approved",
                                                         operator: "studio" }))
      expect(memory_store.get_fact(tenant: "acme", customer: "c-1", key: "size").value).to eq("M")

      executor, capture = build_experiment_executor
      session_store.create(id: "s1")
      run_turn(executor, customer: "c-1", tenant: "acme")
      expect(memory_fragment(capture.call).content).to include('<fact key="size">M</fact>')
    end
  end
end