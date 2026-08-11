# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::CreateSession do
  subject(:handler) do
    described_class.new(session_store: session_store, event_stream: event_stream)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:event_stream) { RecordingStream.new }

  # Minimal spy — the real event_stream class lands in.
  class RecordingStream
    attr_reader :events

    def initialize = (@events = [])
    def emit(event) = @events << event
  end

  it "creates the session with the payload vars and returns a Session" do
    session = handler.call(Insika::Command.build(:create_session, { vars: { "a" => 1 } }))

    expect(session).to be_a(Insika::SessionStore::Session)
    expect(session.vars).to eq({ "a" => 1 })
    expect(session_store.find(session.id).vars).to eq({ "a" => 1 })
  end

  it "accepts an empty payload (vars == {})" do
    session = handler.call(Insika::Command.build(:create_session, {}))

    expect(session.vars).to eq({})
  end

  it "raises ValidationError when vars is not a Hash" do
    expect { handler.call(Insika::Command.build(:create_session, { vars: "x" })) }
      .to raise_error(Insika::ValidationError)
  end

  it "emits an Event :session_created with session_id in data and meta" do
    session = handler.call(Insika::Command.build(:create_session, {}))

    expect(event_stream.events.size).to eq(1)
    event = event_stream.events.first
    expect(event.type).to eq(:session_created)
    expect(event.data[:session_id]).to eq(session.id)
    expect(event.meta[:session_id]).to eq(session.id)
  end

  it "accepts string keys in the payload (transport JSON)" do
    session = handler.call(Insika::Command.build(:create_session, { "vars" => { "b" => 2 } }))

    expect(session.vars).to eq({ "b" => 2 })
  end

  describe "per-chat model pin" do
    let(:slot) { Insika::ModelResolver::SESSION_SLOT }

    it "stashes model/provider into the reserved vars slot" do
      session = handler.call(Insika::Command.build(:create_session,
                                                    { "model" => "gpt-4o", "provider" => "openai", "vars" => { "a" => 1 } }))
      expect(session.vars[slot]).to eq({ "model" => "gpt-4o", "provider" => "openai" })
      expect(session.vars["a"]).to eq(1) # user vars preserved alongside the slot
    end

    it "accepts model without provider" do
      session = handler.call(Insika::Command.build(:create_session, { "model" => "deepseek-chat" }))
      expect(session.vars[slot]).to eq({ "model" => "deepseek-chat" })
    end

    it "no model/provider -> no slot (clean vars)" do
      session = handler.call(Insika::Command.build(:create_session, { "vars" => { "a" => 1 } }))
      expect(session.vars).to eq({ "a" => 1 })
    end

    it "rejects a non-string model" do
      expect { handler.call(Insika::Command.build(:create_session, { "model" => 42 })) }
        .to raise_error(Insika::ValidationError, /model must be a String/)
    end

    it "stashes the per-chat reasoning override (thinking) into the slot" do
      session = handler.call(Insika::Command.build(:create_session,
                                                    { "model" => "deepseek-v4-flash", "thinking" => "off" }))
      expect(session.vars[slot]).to eq({ "model" => "deepseek-v4-flash", "thinking" => "off" })
    end

    it "accepts thinking WITHOUT a model pin (reasoning-only override)" do
      session = handler.call(Insika::Command.build(:create_session, { "thinking" => "on" }))
      expect(session.vars[slot]).to eq({ "thinking" => "on" })
    end

    it "rejects a non-string thinking" do
      expect { handler.call(Insika::Command.build(:create_session, { "thinking" => 3 })) }
        .to raise_error(Insika::ValidationError, /thinking must be a String/)
    end
  end
end
