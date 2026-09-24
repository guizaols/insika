# frozen_string_literal: true

require "spec_helper"
require "insika/tools/present"

# The presentation tool: the model picks ids, the engine keeps the ones the ledger
# saw, joins the hoarded cards, caps, records the selection, emits :ui, and tells
# the model what it dropped and why. Deterministic, no HTTP.
RSpec.describe Insika::Tools::Present do
  let(:event_stream) { SpyEventStream.new }
  let(:definition) do
    Insika::ToolDefinition.build(
      name: "present_products", description: "Show product cards",
      parameters: [{ name: "product_ids", type: "array:string" }, { name: "title", type: "string", required: false }],
      presentation: { component: "product_cards", ids: "product_ids", max: 2 }
    )
  end

  def card(id) = { "type" => "card", "url" => "https://cdn/#{id}", "caption" => "Produto #{id}", "id" => id }

  def state(known: %w[A B C D], cards: %w[A B C])
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    task = Struct.new(:id, :session_id).new("t1", "s1")
    st = Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
    st.evidence_ledger = Insika::EvidenceLedger.new.record(known)
    st.evidence_attachments.concat(cards.map { |id| card(id) })
    st
  end

  def tool(st)
    described_class.new(definition: definition, event_stream: event_stream).tap { |t| t.turn_state = st }
  end

  it "exposes the definition's name/description/schema like a data tool" do
    t = tool(state)
    expect(t.name).to eq("present_products")
    expect(t.description).to eq("Show product cards")
    expect(t.parameters_schema["properties"].keys).to eq(%w[product_ids title])
    expect(t.parameters_schema["properties"].keys).to eq(%w[product_ids title])
  end

  it "shows the known ids that have a card, in the model's order, deduped" do
    st = state
    out = tool(st).execute(product_ids: %w[B A B], title: "Pra pele seca")

    expect(out).to eq("shown" => %w[B A], "dropped" => [])
    expect(st.presentations).to eq([{ "component" => "product_cards", "title" => "Pra pele seca",
                                      "items" => [card("B"), card("A")] }])
  end

  it "drops with a reason: unknown (not in the ledger), no_card (known, nothing hoarded), max (over the cap)" do
    out = tool(state).execute(product_ids: %w[Z A D B C])

    expect(out["shown"]).to eq(%w[A B])
    expect(out["dropped"]).to eq([{ "id" => "Z", "reason" => "unknown" },
                                  { "id" => "D", "reason" => "no_card" },
                                  { "id" => "C", "reason" => "max" }])
    expect(out).not_to have_key("instruction")
  end

  it "emits :ui with the cards, the count and what was dropped, correlated to the task" do
    tool(state).execute(product_ids: %w[A Z])

    ev = event_stream.events.find { |e| e.type == :ui }
    expect(ev.data).to eq(component: "product_cards", title: nil, items: [card("A")], count: 1,
                          dropped: [{ "id" => "Z", "reason" => "unknown" }])
    expect(ev.meta).to eq(task_id: "t1", session_id: "s1")
  end

  it "everything dropped -> the one instruction, and an EMPTY presentation recorded (nothing rides)" do
    st = state
    out = tool(st).execute(product_ids: ["999999"])

    expect(out["shown"]).to eq([])
    expect(out["instruction"]).to eq(described_class::NOTHING_SHOWN)
    expect(st.presentations.first["items"]).to eq([])
  end

  it "no ledger on the state -> every id is unknown (a check that cannot verify does not pass)" do
    st = state
    st.evidence_ledger = nil
    out = tool(st).execute(product_ids: %w[A])
    expect(out["dropped"]).to eq([{ "id" => "A", "reason" => "unknown" }])
  end

  # "me mostra o segundo" a turn later: nothing hoarded THIS turn, the card is on
  # the session ledger (flushed with the ids by the search that returned it).
  it "shows a card the session ledger kept from an earlier turn" do
    sessions = Insika::SessionStore.new(store: Insika::Stores::Memory.new)
    sessions.create(id: "s1")
    sessions.append_evidence("s1", ids: %w[A], ungrounded: 0, cards: [card("A")])
    st = state(known: [], cards: [])
    st.evidence_ledger = Insika::EvidenceLedger.new(store: sessions, session_id: "s1")

    out = tool(st).execute(product_ids: %w[A B])
    expect(out["shown"]).to eq(%w[A])
    expect(out["dropped"]).to eq([{ "id" => "B", "reason" => "unknown" }])
    expect(st.presentations.first["items"]).to eq([card("A")])
  end

  it "never raises: a state with nothing on it is an error the model can read" do
    t = described_class.new(definition: definition, event_stream: nil)
    expect(t.execute(product_ids: %w[A])["dropped"]).to eq([{ "id" => "A", "reason" => "unknown" }])
  end

  # The seam: ToolAssembly deposits the turn state into a tool that asks for it,
  # the same way data tools receive `turn_context`.
  it "receives the turn state from ToolAssembly before the envelope" do
    st = state
    st.turn_context = { chat_id: "c1" }
    entry = Insika::Registry::Entry.new(name: "present_products", plugin: "data-tools", metadata: {},
                                        factory: -> { described_class.new(definition: definition) })
    assembly = Insika::ToolAssembly.new(tool_registry: FakeToolRegistry.new, capability_registry: nil,
                                        event_stream: event_stream, checkpoint_store: nil, tool_trace_store: nil)
    instance = assembly.assemble_tool_instances([entry], st).first
    expect(instance).to be_a(described_class)
    expect(instance.execute(product_ids: %w[A])["shown"]).to eq(%w[A])
  end
end
