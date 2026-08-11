# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Session do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  subject(:provider) { described_class.new(session_store: session_store) }

  def request(session: nil, checkpoint: nil, vars: {})
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    Insika::ContextRequest.new(session: session, message: "oi", profile: profile,
                                tenant: nil, vars: vars, checkpoint: checkpoint)
  end

  def checkpoint(messages)
    Insika::Checkpoint.new(task_id: "t", turn: 1, session_id: "s", agent_id: "a",
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

  describe "eviction units (R1)" do
    let(:cycle) do
      [{ "role" => "user", "content" => "pergunta" },
       { "role" => "assistant", "content" => "",
         "tool_calls" => [{ "id" => "c1", "name" => "search", "arguments" => { "q" => "x" } }] },
       { "role" => "tool", "tool_call_id" => "c1", "content" => "resultado" },
       { "role" => "assistant", "content" => "resposta final" }]
    end

    it "groups assistant(tool_calls)+tool_results into a SINGLE fragment (Array)" do
      frags = provider.call(request(vars: { history: cycle }))

      # 3 units: [user] · [assistant+tool] · [final assistant]
      expect(frags.size).to eq(3)
      unit = frags[1].content
      expect(unit).to be_an(Array)
      expect(unit.map { |m| m[:role].to_s }).to eq(%w[assistant tool])
    end

    it "the unit preserves tool_calls (on the assistant) and tool_call_id (on the tool)" do
      unit = provider.call(request(vars: { history: cycle }))[1].content

      expect(unit.first[:tool_calls]).to eq([{ "id" => "c1", "name" => "search", "arguments" => { "q" => "x" } }])
      expect(unit.last[:tool_call_id]).to eq("c1")
    end

    it "a plain message stays a single Hash fragment (compat)" do
      frags = provider.call(request(vars: { history: cycle }))

      expect(frags.first.content).to eq({ role: "user", content: "pergunta" })
      expect(frags.last.content).to eq({ role: "assistant", content: "resposta final" })
    end

    it "priority is per UNIT (recency counts cycles, not messages)" do
      expect(provider.call(request(vars: { history: cycle })).map(&:priority)).to eq([60, 61, 62])
    end

    # with parallel tool calls the `role: tool` messages are appended
    # in COMPLETION order, so a transcript can carry the results of c1/c2/c3 in any
    # order. The grouping is POSITIONAL — consecutive tool messages after an
    # assistant that has tool_calls — so it does not care, and this pins that: one
    # unit, all three results, still keyed by their own tool_call_id.
    it "tolerates tool results in completion order, not call order" do
      out_of_order = [
        { "role" => "assistant", "content" => "",
          "tool_calls" => [{ "id" => "c1", "name" => "slow", "arguments" => {} },
                           { "id" => "c2", "name" => "fast", "arguments" => {} },
                           { "id" => "c3", "name" => "mid", "arguments" => {} }] },
        { "role" => "tool", "tool_call_id" => "c2", "content" => "second finished first" },
        { "role" => "tool", "tool_call_id" => "c3", "content" => "third finished second" },
        { "role" => "tool", "tool_call_id" => "c1", "content" => "first finished last" },
        { "role" => "assistant", "content" => "resposta final" }
      ]

      frags = provider.call(request(vars: { history: out_of_order }))

      expect(frags.size).to eq(2) # [assistant + its 3 results] · [final assistant]
      unit = frags.first.content
      expect(unit.map { |m| m[:role].to_s }).to eq(%w[assistant tool tool tool])
      expect(unit.drop(1).map { |m| m[:tool_call_id] }).to eq(%w[c2 c3 c1])
    end
  end

  it "read failure with a requested session -> ContextError" do
    exploding = Class.new do
      def find(_id) = raise Insika::StoreError, "backend caiu"
    end.new
    prov = described_class.new(session_store: exploding)
    session = Insika::SessionStore::Session.new(id: "s1", messages: [], vars: {},
                                                 memory_refs: [], created_at: "t", updated_at: "t")

    expect { prov.call(request(session: session)) }.to raise_error(Insika::ContextError)
  end
end
