# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Memory do
  let(:backend) { Insika::Stores::Memory.new }
  let(:mem) { Insika::MemoryStore.new(store: backend) }

  def request(memory:, tenant: "acme")
    profile = Insika::AgentProfile.build(id: "a", model: "m", memory: memory)
    # the real object providers receive has :tenant (the Executor's Struct);
    # here we use the ContextRequest contract (Data.define) which also exposes it.
    Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                tenant: tenant, vars: {}, checkpoint: nil)
  end

  it "memory off (enabled_for? false) -> produces nothing" do
    provider = described_class.new(store: mem)
    expect(provider.enabled_for?(request(memory: nil).profile)).to be(false)
  end

  it "memory on: enabled_for? true" do
    provider = described_class.new(store: mem)
    expect(provider.enabled_for?(request(memory: true).profile)).to be(true)
  end

  it "empty store -> no fragment" do
    expect(described_class.new(store: mem).call(request(memory: true))).to eq([])
  end

  it "facts + notes -> 1 :system priority 75 non-pinned fragment with <memory>" do
    mem.put_fact(tenant: "acme", key: "plano", value: "premium")
    mem.add_note(tenant: "acme", text: "prefere email", at: "2026-01-01T00:00:00Z")

    frags = described_class.new(store: mem).call(request(memory: true))
    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, 75, false])
    expect(f.content).to include("<memory>", %(<fact key="plano">premium</fact>), "<note>prefere email</note>")
  end

  it "passes the request tenant to the store (isolation)" do
    mem.put_fact(tenant: "acme", key: "k", value: "v")
    # a request from another tenant does not see it
    frags = described_class.new(store: mem).call(request(memory: true, tenant: "outro"))
    expect(frags).to eq([])
  end

  it "notes_limit is respected" do
    3.times { |i| mem.add_note(tenant: "acme", text: "n#{i}", at: "2026-01-0#{i + 1}T00:00:00Z") }
    frags = described_class.new(store: mem, notes_limit: 1).call(request(memory: true))
    expect(frags.first.content).to include("<note>n2</note>")
    expect(frags.first.content).not_to include("<note>n1</note>")
  end

  it "uses the Priority::MEMORY constant" do
    mem.put_fact(tenant: "acme", key: "k", value: "v")
    f = described_class.new(store: mem).call(request(memory: true)).first
    expect(f.priority).to eq(Insika::Context::Priority::MEMORY)
  end

  # without an explicit tenant in the Command, the engine memory is PER-CHAT — scope =
  # session id. Symmetric to the write path (state.tenant in the Executor).
  describe "per-chat scope" do
    def request_session(session_id:, tenant: nil)
      profile = Insika::AgentProfile.build(id: "a", model: "m", memory: true)
      session = Struct.new(:id, :messages).new(session_id, [])
      Insika::ContextRequest.new(session: session, message: "oi", profile: profile,
                                  tenant: tenant, vars: {}, checkpoint: nil)
    end

    it "no explicit tenant -> scopes by session (=chat)" do
      mem.put_fact(tenant: "chat-42", key: "plano", value: "premium")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-42"))
      expect(frags.first.content).to include(%(<fact key="plano">premium</fact>))
    end

    it "chat A does not see chat B's memory" do
      mem.put_fact(tenant: "chat-A", key: "k", value: "v")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-B"))
      expect(frags).to eq([])
    end

    it "explicit Command tenant wins over the session (multi-merchant override)" do
      mem.put_fact(tenant: "acme", key: "k", value: "v")
      frags = described_class.new(store: mem).call(request_session(session_id: "chat-42", tenant: "acme"))
      expect(frags.first.content).to include(%(<fact key="k">v</fact>))
    end
  end
end
