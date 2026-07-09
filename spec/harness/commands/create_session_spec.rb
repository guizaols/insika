# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Commands::CreateSession do
  subject(:handler) do
    described_class.new(session_store: session_store, event_stream: event_stream)
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:event_stream) { RecordingStream.new }

  # Spy mínimo — a classe real de event_stream chega na task 10.
  class RecordingStream
    attr_reader :events

    def initialize = (@events = [])
    def emit(event) = @events << event
  end

  it "cria a sessão com as vars do payload e retorna Session" do
    session = handler.call(Harness::Command.build(:create_session, { vars: { "a" => 1 } }))

    expect(session).to be_a(Harness::SessionStore::Session)
    expect(session.vars).to eq({ "a" => 1 })
    expect(session_store.find(session.id).vars).to eq({ "a" => 1 })
  end

  it "aceita payload vazio (vars == {})" do
    session = handler.call(Harness::Command.build(:create_session, {}))

    expect(session.vars).to eq({})
  end

  it "levanta ValidationError quando vars não é Hash" do
    expect { handler.call(Harness::Command.build(:create_session, { vars: "x" })) }
      .to raise_error(Harness::ValidationError)
  end

  it "emite um Event :session_created com session_id em data e meta" do
    session = handler.call(Harness::Command.build(:create_session, {}))

    expect(event_stream.events.size).to eq(1)
    event = event_stream.events.first
    expect(event.type).to eq(:session_created)
    expect(event.data[:session_id]).to eq(session.id)
    expect(event.meta[:session_id]).to eq(session.id)
  end

  it "aceita chaves string no payload (JSON do transporte)" do
    session = handler.call(Harness::Command.build(:create_session, { "vars" => { "b" => 2 } }))

    expect(session.vars).to eq({ "b" => 2 })
  end
end
