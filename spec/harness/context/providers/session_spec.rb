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

  it "checkpoint source: fragments come from the checkpoint; store is not queried" do
    expect(session_store).not_to receive(:find)
    cp = checkpoint([{ "role" => "user", "content" => "do checkpoint" }])

    frags = provider.call(request(checkpoint: cp))

    expect(frags.map { |f| f.content[:content] }).to eq(["do checkpoint"])
  end

  it "explicit history source (vars[:history]): without checkpoint, store not queried" do
    expect(session_store).not_to receive(:find)
    frags = provider.call(request(vars: { history: [{ role: :user, content: "explícito" }] }))

    expect(frags.map { |f| f.content[:content] }).to eq(["explícito"])
  end

  it "session_id source: reads from the SessionStore" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { role: :user, content: "from session" })

    frags = provider.call(request(session: session_store.find("s1")))

    expect(frags.map { |f| f.content[:content] }).to eq(["from session"])
  end

  it "no source -> []" do
    expect(provider.call(request)).to eq([])
  end

  it "precedence: checkpoint wins over session" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { role: :user, content: "from session" })
    cp = checkpoint([{ "role" => "user", "content" => "do checkpoint" }])

    frags = provider.call(request(session: session_store.find("s1"), checkpoint: cp))

    expect(frags.map { |f| f.content[:content] }).to eq(["do checkpoint"])
  end

  it "ramp-up: 3 messages -> priorities 60, 61, 62 (chronological order)" do
    msgs = 3.times.map { |i| { role: "user", content: "m#{i}" } }
    frags = provider.call(request(vars: { history: msgs }))

    expect(frags.map(&:priority)).to eq([60, 61, 62])
    expect(frags.map { |f| f.content[:content] }).to eq(%w[m0 m1 m2])
  end

  it "ceiling 79: 25 messages -> none > 79; skills (80) and identity (100) never surpassed" do
    msgs = 25.times.map { |i| { role: "user", content: "m#{i}" } }
    frags = provider.call(request(vars: { history: msgs }))

    expect(frags.map(&:priority).max).to eq(79)
    expect(frags.last(5).map(&:priority)).to all(eq(79))
  end

  it "content shape: the store's string keys become {role:, content:}" do
    session_store.create(id: "s1")
    session_store.append_messages("s1", { "role" => "assistant", "content" => "oi" })

    frag = provider.call(request(session: session_store.find("s1"))).first

    expect(frag.content).to eq({ role: "assistant", content: "oi" })
  end

  it "read failure with a requested session -> ContextError" do
    exploding = Class.new do
      def find(_id) = raise Harness::StoreError, "backend caiu"
    end.new
    prov = described_class.new(session_store: exploding)
    session = Harness::SessionStore::Session.new(id: "s1", messages: [], vars: {},
                                                 memory_refs: [], created_at: "t", updated_at: "t")

    expect { prov.call(request(session: session)) }.to raise_error(Harness::ContextError)
  end
end
