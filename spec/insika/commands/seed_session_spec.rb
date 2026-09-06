# frozen_string_literal: true

require "spec_helper"

# The snapshot an eval case starts from, written into the conversation before its
# first turn. Every kind lands in the scope the TURN will read, and a conversation
# that already has messages is refused — seeding it would be a test bug, not a merge.
RSpec.describe Insika::Commands::SeedSession do
  subject(:handler) do
    described_class.new(session_store: session_store, memory_store: memory_store, event_stream: event_stream)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:event_stream) { SeedRecordingStream.new }

  class SeedRecordingStream
    attr_reader :events

    def initialize = (@events = [])
    def emit(event) = @events << event
  end

  def seed(payload = {}, tenant: nil, **inline)
    payload = inline if payload.empty?
    handler.call(Insika::Command.build(:seed_session, payload, tenant: tenant))
  end

  let(:state) do
    { "evidence" => { "ids" => %w[SKU-1 SKU-2] },
      "memory" => { "facts" => { "size" => "38" }, "notes" => ["prefers dark chocolate"] },
      "history" => [{ "role" => "user", "content" => "quero um presente" },
                    { "role" => "assistant", "content" => "tenho três opções" }],
      "briefing" => { "fields" => { "cep" => "01311-000" } } }
  end

  it "creates the session when it does not exist and writes all four kinds of state" do
    session = seed(id: "eval-c1", state: state)

    expect(session.id).to eq("eval-c1")
    expect(session.evidence["ids"]).to eq(%w[SKU-1 SKU-2])
    expect(session.briefing["fields"]).to eq({ "cep" => "01311-000" })
    expect(session.messages.map { |m| m.slice("role", "content", "origin") }).to eq([
      { "role" => "user", "content" => "quero um presente", "origin" => "engine" },
      { "role" => "assistant", "content" => "tenho três opções", "origin" => "engine" }
    ])
    expect(session.messages).to all(include("at"))
    expect(event_stream.events.map(&:type)).to eq([:session_seeded])
  end

  # A snapshot can carry the cards a search would have returned, so a case can
  # grade a presentation without a lookup in the turn. A card's id counts as seen.
  it "seeds evidence cards with their ids (a presentation tool can show them)" do
    card = { "type" => "card", "url" => "https://cdn/p2", "caption" => "Kit", "id" => "p2" }
    session = seed(id: "eval-c2", state: { "evidence" => { "ids" => %w[p1], "cards" => [card, { "caption" => "no url" }] } })

    expect(session.evidence["ids"]).to eq(%w[p1 p2])
    expect(session.evidence["cards"]).to eq([card])
  end

  # No tenant, no customer -> the marked per-session cell, exactly where the
  # Executor reads memory for a plain turn on this session.
  it "writes memory into the session cell when there is no tenant and no customer" do
    seed(id: "eval-c1", state: state)

    scope = "#{Insika::MemoryStore::SESSION_TAG}:eval-c1"
    expect(memory_store.get_fact(tenant: scope, key: "size").value).to eq("38")
    expect(memory_store.get_fact(tenant: scope, key: "size").origin).to eq("operator")
    expect(memory_store.notes(tenant: scope).map(&:text)).to eq(["prefers dark chocolate"])
    expect(memory_store.get_fact(tenant: nil, key: "size")).to be_nil # never the shared default cell
  end

  it "writes memory into the tenant's cell (command meta) when there is no customer" do
    seed({ id: "loja-a:eval-c1", state: state }, tenant: "loja-a")

    expect(memory_store.get_fact(tenant: "loja-a", key: "size").value).to eq("38")
  end

  it "writes memory into the [tenant:]customer cell when a customer is given" do
    seed({ id: "loja-a:eval-c1", state: state, customer: "c-9" }, tenant: "loja-a")
    seed(id: "eval-c2", state: state, customer: "c-7")

    expect(memory_store.get_fact(tenant: "loja-a:c-9", key: "size").value).to eq("38")
    expect(memory_store.get_fact(tenant: "c-7", key: "size").value).to eq("38")
    expect(memory_store.get_fact(tenant: "loja-a", key: "size")).to be_nil
  end

  it "seeds into an existing EMPTY session without recreating it" do
    session_store.create(id: "eval-c1", vars: { "channel" => "responses" })
    session = seed(id: "eval-c1", state: { "evidence" => { "ids" => ["SKU-1"] } })

    expect(session.vars).to eq({ "channel" => "responses" })
    expect(session.evidence["ids"]).to eq(["SKU-1"])
  end

  it "refuses a session that already has messages (ConflictError -> 409)" do
    session_store.create(id: "used", vars: {})
    session_store.append_messages("used", { "role" => "user", "content" => "oi" })

    expect { seed(id: "used", state: state) }
      .to raise_error(Insika::ConflictError, /already has 1 message/)
    expect(session_store.find("used").evidence["ids"]).to eq([]) # nothing half-written
  end

  it "accepts a partial state — only the keys given are written" do
    session = seed(id: "eval-c1", state: { "briefing" => { "fields" => { "cep" => "01311-000" } } })

    expect(session.messages).to be_empty
    expect(session.evidence["ids"]).to eq([])
    expect(session.briefing["fields"]).to eq({ "cep" => "01311-000" })
  end

  it "refuses a malformed state (ValidationError -> 422)" do
    expect { seed(id: "x", state: { "history" => "not a list" }) }.to raise_error(Insika::ValidationError, /history/)
    expect { seed(id: "y", state: { "history" => [{ "role" => "system", "content" => "x" }] }) }
      .to raise_error(Insika::ValidationError, /role must be user or assistant/)
    expect { seed(id: "z", state: { "memory" => { "facts" => ["not a hash"] } }) }
      .to raise_error(Insika::ValidationError, /facts must be a Hash/)
    expect { seed(state: state) }.to raise_error(Insika::ValidationError, /id is required/)
  end
end
