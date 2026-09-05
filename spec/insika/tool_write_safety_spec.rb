# frozen_string_literal: true

require "spec_helper"
require "insika/tools/data_defined_tool"

RSpec.describe "data-tool write safety" do
  it "blocks an invented id, learns ids from a lookup, then preserves both additions in one real gem batch" do
    backend = Insika::Stores::Memory.new
    tools = Insika::ToolStore.new(config_store: Insika::ConfigStore.new(store: backend))
    tools.write({ name: "search", description: "Look up items", evidence: "items",
                  request: { url: "https://example.test/items" },
                  response: { extract: "evidence_envelope" } })
    tools.write({ name: "add_to_cart", description: "Add an item", requires_evidence: ["product_id"],
                  parameters: [{ name: "product_id", type: "string" }],
                  request: { method: "POST", url: "https://example.test/cart",
                             body: '{"id":"{{product_id}}"}' } })
    cart = []
    writes = []
    http = Object.new
    http.define_singleton_method(:request) do |**req|
      if req[:method] == "GET"
        { status: 200, body: JSON.generate(items: [{ id: "A", line: "First" }, { id: "B", line: "Second" }]) }
      else
        id = JSON.parse(req[:body]).fetch("id")
        writes << id
        before = cart.dup
        Async::Task.current.sleep(0.01)
        cart.replace(before + [id])
        { status: 200, body: JSON.generate(status: "added", id: id) }
      end
    end
    egress = Object.new
    def egress.violation(*) = nil
    events = SpyEventStream.new
    traces = Insika::ToolTraceStore.new(store: backend)
    registry = Insika::OverlayToolRegistry.new(base: Insika::ToolRegistry.new, tool_store: tools,
                                               http: http, egress: egress, event_stream: events)
    sessions = Insika::SessionStore.new(store: backend)
    sessions.create(id: "s")
    checkpoints = Insika::CheckpointStore.new(store: backend)
    state = Insika::TurnState.new(task: Struct.new(:id, :session_id).new("t", "s"), turn: 1,
                                  message: "Add both items",
                                  profile: Insika::AgentProfile.build(id: "shop", limits: { tool_concurrency: 4 }))
    state.evidence_ledger = Insika::EvidenceLedger.new(store: sessions, session_id: "s")
    assembly = Insika::ToolAssembly.new(tool_registry: registry, capability_registry: nil,
                                        event_stream: events, checkpoint_store: checkpoints, tool_trace_store: traces)
    search, write = assembly.wrap_tools([registry.resolve("search"), registry.resolve("add_to_cart")], state)

    Sync do
      expect(write.call({ "product_id" => "999999" })).to include("gate" => "provenance")
      expect(writes).to be_empty
      expect(search.call({})).to include("items")
      RubyLLM::ToolConcurrency.run(:fibers, { "a" => "A", "b" => "B" }) do |id|
        state.current_tool_call = Struct.new(:id).new("call-#{id}")
        expect(write.call({ "product_id" => id })).to include('"status":"added"')
      end
    end

    expect(cart).to eq(%w[A B])
    expect(writes).to eq(%w[A B])
    expect(checkpoints.side_effects("t", turn: 1)).to contain_exactly("call-A", "call-B")
    expect(events.events.count { |event| event.type == :tool_blocked }).to eq(1)
    expect(traces.for_session("s").count { |entry| entry["gate"] == "provenance" }).to eq(1)
  end
end
