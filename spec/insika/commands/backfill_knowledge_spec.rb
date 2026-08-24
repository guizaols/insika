# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# The recovery path: replays one agent's stored sessions through the same
# extractor a live turn's terminal hook uses. Writes nothing but the concepts.
RSpec.describe Insika::Commands::BackfillKnowledge do
  subject(:handler) do
    described_class.new(profiles: { "store-support" => profile }, knowledge_store: knowledge,
                        session_store: session_store, task_store: tasks,
                        settings_store: settings, event_stream: stream,
                        extractor_factory: extractor_factory)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:knowledge) { Insika::KnowledgeStore.new(store: backend) }
  let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  let(:knowledge_config) { { "extract" => true, "model" => "deepseek-v4-flash" } }
  let(:profile) { Insika::AgentProfile.build(id: "store-support", model: "m", knowledge: knowledge_config) }

  let(:raw_concepts) do
    [{ "name" => "cep-13-campinas", "description" => "d", "type" => "fact", "body" => "b" }]
  end
  let(:clean_drops) do
    { "schema" => 0, "unknown_key" => 0, "bad_type" => 0, "oversized" => 0, "duplicate" => 0, "capped" => 0 }
  end
  let(:fake_extractor) do
    dropped = clean_drops
    Class.new do
      attr_reader :calls, :model

      define_method(:initialize) { |concepts| @concepts = concepts; @model = "deepseek-v4-flash"; @calls = [] }
      define_method(:extract) do |prompt:, max_concepts: 10|
        @calls << prompt
        { concepts: @concepts, dropped: dropped.dup, cost: nil }
      end
    end.new(raw_concepts)
  end
  let(:extractor_factory) do
    Class.new do
      attr_reader :extractor

      def initialize(e) = (@extractor = e)
      def call(_config) = @extractor
    end.new(fake_extractor)
  end

  def cmd(payload) = Insika::Command.build(:backfill_knowledge, payload)

  def seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
    tasks.create(command: Insika::Command.build(:send_message, { "agent" => "store-support" }),
                session_id: session_id, id: "acme:task_#{SecureRandom.hex(4)}", at: at)
  end

  def seed_session(id: "acme:sess_1", messages: 3)
    session_store.create(id: id)
    messages.times { |i| session_store.append_messages(id, { "role" => "user", "content" => "msg #{i}" }) }
    session_store.find(id)
  end

  describe "the skip reasons" do
    it "disabled: no knowledge declaration" do
      handler = described_class.new(profiles: { "store-support" => Insika::AgentProfile.build(id: "store-support", model: "m") },
                                    knowledge_store: knowledge, session_store: session_store, task_store: tasks,
                                    event_stream: stream, extractor_factory: extractor_factory)
      expect(handler.call(cmd(agent: "store-support"))).to eq(backfilled: false, skipped: "disabled")
    end

    it "no_model: the extractor_factory returns nil" do
      seed_session
      seed_task
      nil_factory = Class.new { def call(_config) = nil }.new
      handler = described_class.new(profiles: { "store-support" => profile }, knowledge_store: knowledge,
                                    session_store: session_store, task_store: tasks,
                                    event_stream: stream, extractor_factory: nil_factory)
      expect(handler.call(cmd(agent: "store-support"))).to eq(backfilled: false, skipped: "no_model")
    end

    it "no_sessions: the agent has no eligible sessions" do
      expect(handler.call(cmd(agent: "store-support"))).to eq(backfilled: false, skipped: "no_sessions")
    end

    it "raises for an unconfigured agent" do
      expect { handler.call(cmd(agent: "ghost")) }.to raise_error(Insika::NotFoundError)
    end

    it "raises when agent is missing" do
      expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError, /agent is required/)
    end
  end

  describe "a successful backfill" do
    it "writes the extracted concepts, stamped with provenance/confidence/sources, and emits events" do
      seed_session
      seed_task

      result = handler.call(cmd(agent: "store-support"))

      expect(result).to eq(backfilled: true, sessions: 1, concepts: 1, dropped: clean_drops)
      stored = knowledge.get("store-support", "cep-13-campinas")
      expect(stored).to include("provenance: \"observed\"")
      expect(stored).to include("sess_1")
      expect(events.map(&:type)).to contain_exactly(:knowledge_learned, :knowledge_backfilled)
    end

    it "filters sessions by --since and by another agent's tasks" do
      seed_session(id: "acme:old", messages: 3)
      seed_task(session_id: "acme:old", at: "2026-01-01T00:00:00Z")
      seed_session(id: "acme:new", messages: 3)
      seed_task(session_id: "acme:new", at: "2026-08-20T00:00:00Z")

      result = handler.call(cmd(agent: "store-support", since: "2026-06-01T00:00:00Z"))
      expect(result[:sessions]).to eq(1)
      expect(fake_extractor.calls.size).to eq(1)
    end

    it "skips a session with fewer than the minimum messages" do
      seed_session(messages: 1)
      seed_task

      expect(handler.call(cmd(agent: "store-support"))).to eq(backfilled: false, skipped: "no_sessions")
    end
  end
end
