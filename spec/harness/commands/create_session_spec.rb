# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::CreateSession do
  subject(:handler) do
    described_class.new(session_store: session_store, event_stream: event_stream)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:event_stream) { RecordingStream.new }

  # Minimal spy — the real event_stream class lands in task 10.
  class RecordingStream
    attr_reader :events

    def initialize = (@events = [])
    def emit(event) = @events << event
  end

  it "creates the session with the payload vars and returns a Session" do
    session = handler.call(Harness::Command.build(:create_session, { vars: { "a" => 1 } }))

    expect(session).to be_a(Harness::SessionStore::Session)
    expect(session.vars).to eq({ "a" => 1 })
    expect(session_store.find(session.id).vars).to eq({ "a" => 1 })
  end

  it "accepts an empty payload (vars == {})" do
    session = handler.call(Harness::Command.build(:create_session, {}))

    expect(session.vars).to eq({})
  end

  it "raises ValidationError when vars is not a Hash" do
    expect { handler.call(Harness::Command.build(:create_session, { vars: "x" })) }
      .to raise_error(Harness::ValidationError)
  end

  it "emits an Event :session_created with session_id in data and meta" do
    session = handler.call(Harness::Command.build(:create_session, {}))

    expect(event_stream.events.size).to eq(1)
    event = event_stream.events.first
    expect(event.type).to eq(:session_created)
    expect(event.data[:session_id]).to eq(session.id)
    expect(event.meta[:session_id]).to eq(session.id)
  end

  it "accepts string keys in the payload (transport JSON)" do
    session = handler.call(Harness::Command.build(:create_session, { "vars" => { "b" => 2 } }))

    expect(session.vars).to eq({ "b" => 2 })
  end
end
