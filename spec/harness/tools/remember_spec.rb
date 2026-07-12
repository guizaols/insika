# frozen_string_literal: true

require "spec_helper"
require "harness/tools/remember" # o Executor o carrega lazy; explícito no teste

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

  it "def name = 'remember' (não o derivado da classe)" do
    expect(tool.name).to eq("remember")
  end

  it "com key: grava um fato (upsert) e emite :memory_written kind fact" do
    result = tool.execute(value: "premium", key: "plano")
    expect(result).to eq({ remembered: "fact", key: "plano" })
    expect(mem.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
    ev = events.last
    expect(ev.type).to eq(:memory_written)
    expect(ev.data).to eq({ kind: "fact", key: "plano" })
    expect(ev.meta).to eq({ task_id: "t1", session_id: "s1" })
  end

  it "sem key: grava uma note e emite :memory_written kind note" do
    result = tool.execute(value: "prefere email")
    expect(result[:remembered]).to eq("note")
    expect(mem.notes(tenant: "acme").first.text).to eq("prefere email")
    expect(events.last.data[:kind]).to eq("note")
    expect(events.last.data[:key]).to eq(result[:id]) # key = id da note
  end

  it "key só com espaços é tratada como note" do
    tool.execute(value: "x", key: "   ")
    expect(mem.notes(tenant: "acme").size).to eq(1)
    expect(mem.facts(tenant: "acme")).to eq([])
  end

  it "grava no tenant recebido (isolamento)" do
    tool(tenant: "acme").execute(value: "v", key: "k")
    expect(mem.get_fact(tenant: "outro", key: "k")).to be_nil
  end
end
