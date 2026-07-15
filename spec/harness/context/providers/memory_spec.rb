# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Context::Providers::Memory do
  let(:backend) { Harness::Stores::Memory.new }
  let(:mem) { Harness::MemoryStore.new(store: backend) }

  def request(memory:, tenant: "acme")
    profile = Harness::AgentProfile.build(id: "a", model: "m", memory: memory)
    # o objeto real que os providers recebem tem :tenant (Struct do Executor);
    # aqui usamos o ContextRequest contrato (Data.define) que também o expõe.
    Harness::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: tenant, vars: {}, checkpoint: nil)
  end

  it "memory off (enabled_for? false) -> não produz" do
    provider = described_class.new(store: mem)
    expect(provider.enabled_for?(request(memory: nil).profile)).to be(false)
  end

  it "memory on: enabled_for? true" do
    provider = described_class.new(store: mem)
    expect(provider.enabled_for?(request(memory: true).profile)).to be(true)
  end

  it "store vazio -> nenhum fragmento" do
    expect(described_class.new(store: mem).call(request(memory: true))).to eq([])
  end

  it "fatos + notes -> 1 fragmento :system priority 75 não-pinned com <memory>" do
    mem.put_fact(tenant: "acme", key: "plano", value: "premium")
    mem.add_note(tenant: "acme", text: "prefere email", at: "2026-01-01T00:00:00Z")

    frags = described_class.new(store: mem).call(request(memory: true))
    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, 75, false])
    expect(f.content).to include("<memory>", %(<fact key="plano">premium</fact>), "<note>prefere email</note>")
  end

  it "repassa o tenant do request ao store (isolamento)" do
    mem.put_fact(tenant: "acme", key: "k", value: "v")
    # request de outro tenant não vê
    frags = described_class.new(store: mem).call(request(memory: true, tenant: "outro"))
    expect(frags).to eq([])
  end

  it "notes_limit é respeitado" do
    3.times { |i| mem.add_note(tenant: "acme", text: "n#{i}", at: "2026-01-0#{i + 1}T00:00:00Z") }
    frags = described_class.new(store: mem, notes_limit: 1).call(request(memory: true))
    expect(frags.first.content).to include("<note>n2</note>")
    expect(frags.first.content).not_to include("<note>n1</note>")
  end

  it "usa a constante Priority::MEMORY" do
    mem.put_fact(tenant: "acme", key: "k", value: "v")
    f = described_class.new(store: mem).call(request(memory: true)).first
    expect(f.priority).to eq(Harness::Context::Priority::MEMORY)
  end

  # D3: sem tenant explícito no Command, a memória do motor é POR-CHAT — escopo =
  # id da sessão. Simétrico ao write path (state.tenant no Executor).
  describe "escopo por-chat (D3)" do
    def request_session(session_id:, tenant: nil)
      profile = Harness::AgentProfile.build(id: "a", model: "m", memory: true)
      session = Struct.new(:id, :messages).new(session_id, [])
      Harness::ContextRequest.new(session: session, message: "oi", profile: profile,
                                  tenant: tenant, vars: {}, checkpoint: nil)
    end

    it "sem tenant explícito -> escopa pela sessão (=chat)" do
      mem.put_fact(tenant: "chat-42", key: "plano", value: "premium")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-42"))
      expect(frags.first.content).to include(%(<fact key="plano">premium</fact>))
    end

    it "chat A não vê a memória do chat B" do
      mem.put_fact(tenant: "chat-A", key: "k", value: "v")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-B"))
      expect(frags).to eq([])
    end

    it "tenant explícito do Command vence a sessão (override multi-merchant)" do
      mem.put_fact(tenant: "acme", key: "k", value: "v")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-42", tenant: "acme"))
      expect(frags.first.content).to include(%(<fact key="k">v</fact>))
    end
  end
end
