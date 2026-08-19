# frozen_string_literal: true

require "spec_helper"

# ExportCustomerMemory — the LGPD access right. Returns the FULL
# content in its return value (the Studio turns it into a JSON download); the
# emitted event carries counts only, so the event stream stays content-free.
RSpec.describe Insika::Commands::ExportCustomerMemory do
  let(:store) { Insika::MemoryStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

  def run(payload) = handler.call(Insika::Command.build(:export_customer_memory, payload))

  it "returns facts + notes + counts; expired facts excluded" do
    store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M",
                   expires_at: "2099-01-01T00:00:00Z")
    store.put_fact(tenant: "acme", customer: "c-1", key: "expired", value: "x",
                   expires_at: "2020-01-01T00:00:00Z")
    store.add_note(tenant: "acme", customer: "c-1", text: "prefere email")

    result = run("tenant" => "acme", "customer" => "c-1")

    expect(result["customer"]).to eq("c-1")
    expect(result["tenant"]).to eq("acme")
    expect(result["exported_at"]).to be_a(String)
    expect(result["facts"].map { |f| f["key"] }).to eq(["size"])
    expect(result["facts"].first["origin"]).to eq("engine")
    expect(result["notes"].map { |n| n["text"] }).to eq(["prefere email"])
    expect(result["counts"]).to eq({ "facts" => 1, "notes" => 1 })
  end

  it "missing customer -> ValidationError (the export must name a person)" do
    expect { run("tenant" => "acme") }.to raise_error(Insika::ValidationError, /customer/)
  end

  it "empty cell -> empty export (E2's 'export returns empty' half)" do
    result = run("tenant" => "acme", "customer" => "nobody")
    expect(result["facts"]).to eq([])
    expect(result["notes"]).to eq([])
    expect(result["counts"]).to eq({ "facts" => 0, "notes" => 0 })
  end

  it "the emitted event carries counts, NEVER content" do
    store.put_fact(tenant: "acme", customer: "c-1", key: "cpf", value: "123.456.789-00")

    run("tenant" => "acme", "customer" => "c-1")

    expect(events.map(&:type)).to eq([:customer_memory_exported])
    data = events.first.data
    expect(data[:counts]).to eq({ facts: 1, notes: 0 })
    expect(data[:facts]).to be_nil
    expect(data.inspect).not_to include("123.456.789-00")
  end
end