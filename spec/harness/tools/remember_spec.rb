# frozen_string_literal: true

require "spec_helper"
require "harness/tools/remember" # the Executor loads it lazily; explicit in the test

RSpec.describe Harness::Tools::Remember do
  let(:backend) { Harness::Stores::Memory.new }
  let(:mem) { Harness::MemoryStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }
  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:state) do
    profile = Harness::AgentProfile.build(id: "a", model: "m", memory: true)
    Harness::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
  end

  def tool(tenant: "acme")
    described_class.new(mem, tenant, event_stream: event_stream, state: state)
  end

  it "def name = 'remember' (not the one derived from the class)" do
    expect(tool.name).to eq("remember")
  end

  it "with key: stores a fact (upsert) and emits :memory_written kind fact" do
    result = tool.execute(value: "premium", key: "plano")
    expect(result).to eq({ remembered: "fact", key: "plano" })
    expect(mem.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
    ev = events.last
    expect(ev.type).to eq(:memory_written)
    expect(ev.data).to eq({ kind: "fact", key: "plano" })
    expect(ev.meta).to eq({ task_id: "t1", session_id: "s1" })
  end

  it "without key: stores a note and emits :memory_written kind note" do
    result = tool.execute(value: "prefere email")
    expect(result[:remembered]).to eq("note")
    expect(mem.notes(tenant: "acme").first.text).to eq("prefere email")
    expect(events.last.data[:kind]).to eq("note")
    expect(events.last.data[:key]).to eq(result[:id]) # key = the note's id
  end

  it "a key with only spaces is treated as a note" do
    tool.execute(value: "x", key: "   ")
    expect(mem.notes(tenant: "acme").size).to eq(1)
    expect(mem.facts(tenant: "acme")).to eq([])
  end

  it "writes to the received tenant (isolation)" do
    tool(tenant: "acme").execute(value: "v", key: "k")
    expect(mem.get_fact(tenant: "outro", key: "k")).to be_nil
  end
end
