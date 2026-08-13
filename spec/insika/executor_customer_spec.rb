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

    it "no customer -> tenant || session, byte-identical to before" do
      expect(build_executor.send(:memory_tenant, task("oi", tenant: "acme"))).to eq("acme")
      expect(build_executor.send(:memory_tenant, task("oi"))).to eq("s1")
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
end