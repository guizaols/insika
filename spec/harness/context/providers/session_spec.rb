# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Context::Providers::Session do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  subject(:provider) { described_class.new(session_store: session_store) }

  def request(session: nil, checkpoint: nil, vars: {})
    profile = Harness::AgentProfile.build(id: "a", model: "m")
    Harness::ContextRequest.new(session: session, message: "oi", profile: profile,
                                tenant: nil, vars: vars, checkpoint: checkpoint)
  end

  def checkpoint(messages)
    Harness::Checkpoint.new(task_id: "t", turn: 1, session_id: "s", agent_id: "a",
                            messages: messages, completed_side_effects: [], created_at: nil)
  end

  it "fonte checkpoint: fragmentos vêm do checkpoint; store não é consultado" do
    expect(session_store).not_to receive(:find)
    cp = checkpoint([{ "role" => "user", "content" => "do checkpoint" }])

    frags = provider.call(request(checkpoint: cp))

    expect(frags.map { |f| f.content[:content] }).to eq(["do checkpoint"])
  end

  it "fonte history explícito (vars[:history]): sem checkpoint, store não consultado" do
    expect(session_store).not_to receive(:find)
    frags = provider.call(request(vars: { history: [{ role: :user, content: "explícito" }] }))

    expect(frags.map { |f| f.content[:content] }).to eq(["explícito"])
  end

  it "fonte session_id: lê do SessionStore" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { role: :user, content: "da sessão" })

    frags = provider.call(request(session: session_store.find("s1")))

    expect(frags.map { |f| f.content[:content] }).to eq(["da sessão"])
  end

  it "nenhuma fonte -> []" do
    expect(provider.call(request)).to eq([])
  end

  it "precedência: checkpoint vence sobre sessão" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { role: :user, content: "da sessão" })
    cp = checkpoint([{ "role" => "user", "content" => "do checkpoint" }])

    frags = provider.call(request(session: session_store.find("s1"), checkpoint: cp))

    expect(frags.map { |f| f.content[:content] }).to eq(["do checkpoint"])
  end

  it "escalonamento: 3 mensagens -> priorities 60, 61, 62 (ordem cronológica)" do
    msgs = 3.times.map { |i| { role: "user", content: "m#{i}" } }
    frags = provider.call(request(vars: { history: msgs }))

    expect(frags.map(&:priority)).to eq([60, 61, 62])
    expect(frags.map { |f| f.content[:content] }).to eq(%w[m0 m1 m2])
  end

  it "teto 79: 25 mensagens -> nenhuma > 79; skills (80) e identidade (100) nunca superadas" do
    msgs = 25.times.map { |i| { role: "user", content: "m#{i}" } }
    frags = provider.call(request(vars: { history: msgs }))

    expect(frags.map(&:priority).max).to eq(79)
    expect(frags.last(5).map(&:priority)).to all(eq(79))
  end

  it "shape do content: chaves string do store viram {role:, content:}" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { "role" => "assistant", "content" => "oi" })

    frag = provider.call(request(session: session_store.find("s1"))).first

    expect(frag.content).to eq({ role: "assistant", content: "oi" })
  end

  it "falha de leitura com sessão pedida -> ContextError" do
    exploding = Class.new do
      def find(_id) = raise Harness::StoreError, "backend caiu"
    end.new
    prov = described_class.new(session_store: exploding)
    session = Harness::SessionStore::Session.new(id: "s1", messages: [], vars: {},
                                                 memory_refs: [], created_at: "t", updated_at: "t")

    expect { prov.call(request(session: session)) }.to raise_error(Harness::ContextError)
  end
end
