# frozen_string_literal: true

require "spec_helper"

# the ONLY path that writes proposals — distill ONE session end to
# end: read the transcript and the memory baseline, ask the model, schema-drop,
# dedup against the ledger, write proposals, mark the session distilled.
RSpec.describe Insika::Commands::RunDistillation do
  subject(:handler) do
    described_class.new(profiles: profiles, proposal_store: proposals,
                        session_store: sessions, memory_store: memory,
                        settings_store: settings, event_stream: stream,
                        distiller_factory: distiller_factory)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:proposals) { Insika::ProposalStore.new(store: backend) }
  let(:memory) { Insika::MemoryStore.new(store: backend) }
  let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  let(:profiles) { { "store-support" => profile } }
  let(:distill_config) { nil } # absent -> disabled (the default profile)
  let(:profile) { Insika::AgentProfile.build(id: "store-support", model: "m", distill: distill_config) }

  let(:answer) { [{ "name" => "size", "value" => "M", "confidence" => 0.9, "turns" => [1, 3] }] }
  let(:dropped) { { "schema" => 0, "unknown_key" => 0, "oversized" => 0, "bad_turns" => 0, "duplicate" => 0, "capped" => 0 } }
  let(:fake_distiller) do
    Class.new do
      attr_reader :calls

      def initialize(proposals, dropped) = (@proposals = proposals; @dropped = dropped; @calls = [])
      def distill(prompt:, message_count:, max_proposals:)
        @calls << { prompt: prompt, message_count: message_count, max_proposals: max_proposals }
        { proposals: @proposals, dropped: @dropped, cost: nil }
      end
    end.new(answer, dropped)
  end
  let(:distiller_factory) do
    Class.new do
      attr_reader :distiller

      def initialize(d) = (@distiller = d)
      def call(_config) = @distiller
    end.new(fake_distiller)
  end

  def cmd(payload) = Insika::Command.build(:run_distillation, payload)

  # An idle, customer-tagged, agent-tagged session with enough messages.
  def seed_session(id: "acme:sess_1", customer: "c-1", agent: "store-support",
                   messages: 4, updated_at: "2026-08-10T00:00:00Z")
    sessions.create(id: id)
    sessions.update_vars(id, "customer" => customer, "agent" => agent)
    messages.times do |i|
      sessions.append_messages(id, { "role" => "user", "content" => "message #{i}" })
    end
    record = sessions.find(id).to_h.merge("updated_at" => updated_at)
    backend.set("sessions", "session:#{id}", record)
    sessions.find(id)
  end

  describe "the skip reasons" do
    # everything except the disabled pair needs an enabled declaration
    let(:distill_config) { { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 } }

    let(:no_declaration) do
      insika = Insika::AgentProfile.build(id: "store-support", model: "m")
      insika
    end

    def handler_for(profile)
      described_class.new(profiles: { "store-support" => profile },
                          proposal_store: proposals, session_store: sessions,
                          memory_store: memory, settings_store: settings,
                          event_stream: stream, distiller_factory: distiller_factory)
    end

    it "already — a session whose marker exists is not distilled again" do
      session = seed_session
      proposals.mark_distilled(session.id, agent: "store-support", proposals: 0, dropped: {})
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result).to include(distilled: false, skipped: "already")
      expect(events).to be_empty
    end

    it "untagged — a session without vars['customer'] has no landing zone (D6)" do
      session = seed_session(customer: nil)
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("untagged")
    end

    it "no_agent — a session without vars['agent'] has no pack" do
      session = seed_session(agent: nil)
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("no_agent")
    end

    it "disabled — a profile without a distill declaration" do
      session = seed_session
      result = handler_for(no_declaration).call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("disabled")
    end

    it "disabled — a declaration with enabled: false" do
      session = seed_session
      result = handler_for(Insika::AgentProfile.build(id: "store-support", model: "m",
                                                      distill: { "enabled" => false }))
                .call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("disabled")
    end

    it "too_fresh — the pack's own idle_hours threshold wins over the scan's bound (D4)" do
      session = seed_session(updated_at: (Time.now.utc - 3600).iso8601) # 1h old < 6h
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("too_fresh")
    end

    it "too_short — fewer messages than min_messages distills noise " do
      session = seed_session(messages: 2)
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("too_short")
    end

    it "no_model — a declared distiller with no resolvable model is inert, never guessed (D4)" do
      session = seed_session
      empty_factory = Class.new { def call(_config) = nil }.new
      h = described_class.new(profiles: profiles, proposal_store: proposals,
                              session_store: sessions, memory_store: memory,
                              settings_store: settings, event_stream: stream,
                              distiller_factory: empty_factory)
      result = h.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("no_model")
      expect(proposals.pending(limit: 100)).to be_empty
    end

    it "a nonexistent session -> NotFoundError (the worker skips a deleted session)" do
      expect { handler.call(cmd({ "session_id" => "nope" })) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe "a happy pass" do
    let(:distill_config) { { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 } }

    it "writes proposals with the memory baseline, stamps the marker, emits the event" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "L",
                      origin: "operator")
      session = seed_session

      result = handler.call(cmd({ "session_id" => session.id }))

      expect(result).to include(distilled: true, proposals: 1, deduped: 0)
      expect(result[:dropped]).to eq("schema" => 0, "unknown_key" => 0, "oversized" => 0,
                                     "bad_turns" => 0, "duplicate" => 0, "capped" => 0)
      expect(proposals.distilled?(session.id)).to be(true)

      proposal = proposals.pending(limit: 100).first
      expect(proposal.key).to eq("size")
      expect(proposal.value).to eq("M")
      expect(proposal.confidence).to eq(0.9)
      expect(proposal.evidence).to eq([1, 3])
      expect(proposal.tenant).to eq("acme")
      expect(proposal.customer).to eq("c-1")
      expect(proposal.scope).to eq("acme:c-1")
      expect(proposal.session_ref).to eq(session.id)
      # the baseline (D5): the target fact's existence + revision at distill time
      expect(proposal.expected_existed).to be(true)
      expect(proposal.expected_revision).to eq(memory.get_fact(tenant: "acme", customer: "c-1",
                                                               key: "size").updated_at)

      event = events.first
      expect(event.type).to eq(:distillation_completed)
      expect(event.data).to include(session_ref: session.id, agent: "store-support",
                                    proposals: 1, deduped: 0)
      expect(event.data[:dropped]).to be_a(Hash)
      # the event carries counts and ids only — never a value text (D7)
      expect(events.to_s).not_to include("M")
    end

    it "passes the pack prompt, the transcript and the customer's current facts to the ask" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "budget", value: "100", origin: "operator")
      session = seed_session(messages: 3)
      handler.call(cmd({ "session_id" => session.id }))

      call = distiller_factory.distiller.calls.first
      expect(call[:message_count]).to eq(3)
      expect(call[:prompt]).to include("message 0")
      expect(call[:prompt]).to include("budget")
    end

    # Blocker 1 — single-tenant: a bare session id (the pilot's shape) has no
    # tenant, so the proposal must land in the bare customer cell — the SAME
    # cell the Memory provider injects. A coerced "platform" tenant would
    # orphan every approved fact in a phantom cell.
    it "single-tenant: a bare session id stores tenant nil and the approval reaches the injected cell" do
      session = seed_session(id: "sess_1", updated_at: (Time.now.utc - 86_400).iso8601)
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:distilled]).to be(true)

      proposal = proposals.pending(limit: 100).first
      expect(proposal.tenant).to be_nil
      expect(proposal.customer).to eq("c-1")
      expect(proposal.scope).to eq("c-1")

      Insika::Commands::ResolveProposal.new(proposal_store: proposals,
                                            memory_store: memory,
                                            event_stream: stream)
        .call(Insika::Command.build(:resolve_proposal, { proposal_id: proposal.id,
                                                         decision: "approved" }))
      # the bare cell the provider injects — memory:<customer>, never
      # memory:platform:<customer>
      expect(memory.get_fact(tenant: nil, customer: "c-1", key: "size").value).to eq("M")
      expect(memory.get_fact(tenant: "platform", customer: "c-1", key: "size")).to be_nil
    end
  end

  describe "the dedup filters (the ledger)" do
    let(:distill_config) { { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 } }

    it "E2 unit half — a dismissed tuple from a PREVIOUS session never reappears" do
      old = seed_session(id: "acme:sess_old")
      handler.call(cmd({ "session_id" => old.id }))
      proposals.dismiss(id: proposals.pending(limit: 100).first.id)

      fresh = seed_session(id: "acme:sess_new", updated_at: (Time.now.utc - 86_400).iso8601)
      result = handler.call(cmd({ "session_id" => fresh.id }))
      expect(result[:deduped]).to eq(1)
      expect(proposals.pending(limit: 100)).to be_empty
    end

    it "a pending row on the key suppresses a second (no piling)" do
      session = seed_session
      handler.call(cmd({ "session_id" => session.id }))
      expect(proposals.pending(limit: 100).size).to eq(1)

      # the marker blocks the same session; a similar one is deduped by the ledger
      twin = seed_session(id: "acme:sess_twin", updated_at: (Time.now.utc - 86_400).iso8601)
      result = handler.call(cmd({ "session_id" => twin.id }))
      expect(result[:deduped]).to eq(1)
      expect(proposals.pending(limit: 100).size).to eq(1)
    end

    it "an already-applied distilled fact suppresses re-proposing it" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M",
                      origin: "distilled:acme:sess_old")
      session = seed_session
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:deduped]).to eq(1)
      expect(proposals.pending(limit: 100)).to be_empty
      expect(proposals.distilled?(session.id)).to be(true)
    end

    it "a different value for the same name is NOT deduped (a different tuple)" do
      memory.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M",
                      origin: "distilled:acme:sess_old")
      answer << { "name" => "size", "value" => "L" }
      session = seed_session
      result = handler.call(cmd({ "session_id" => session.id }))
      expect(result[:deduped]).to eq(1)
      expect(proposals.pending(limit: 100).map(&:value)).to eq(["L"])
    end
  end

  describe "the marker discipline (D2)" do
    let(:distill_config) { { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 } }

    it "a second call on the same session returns 'already' WITHOUT asking the model" do
      session = seed_session
      handler.call(cmd({ "session_id" => session.id }))
      raising = Class.new do
        def distill(*) = raise("the model was asked twice")
      end.new
      factory = Class.new { def initialize(d) = (@d = d); def call(_c) = @d }.new(raising)
      h = described_class.new(profiles: profiles, proposal_store: proposals,
                              session_store: sessions, memory_store: memory,
                              settings_store: settings, event_stream: stream,
                              distiller_factory: factory)
      result = h.call(cmd({ "session_id" => session.id }))
      expect(result[:skipped]).to eq("already")
    end

    it "a raising ask propagates and the marker is NOT written (re-scan, D2)" do
      session = seed_session
      raising = Class.new { def distill(*) = raise("provider down") }.new
      factory = Class.new { def initialize(d) = (@d = d); def call(_c) = @d }.new(raising)
      h = described_class.new(profiles: profiles, proposal_store: proposals,
                              session_store: sessions, memory_store: memory,
                              settings_store: settings, event_stream: stream,
                              distiller_factory: factory)
      expect { h.call(cmd({ "session_id" => session.id })) }.to raise_error("provider down")
      expect(proposals.distilled?(session.id)).to be(false)
    end

    it "the distiller's dropped counts land on the marker and the event" do
      dropped.replace("schema" => 1, "unknown_key" => 1, "oversized" => 1, "bad_turns" => 0,
                      "duplicate" => 1, "capped" => 0)
      answer.replace([{ "name" => "size", "value" => "M" }])
      session = seed_session
      handler.call(cmd({ "session_id" => session.id }))

      expect(proposals.pending(limit: 100).size).to eq(1)
      event = events.first
      expect(event.data[:proposals]).to eq(1)
      expect(event.data[:dropped]).to eq("schema" => 1, "unknown_key" => 1, "oversized" => 1,
                                         "bad_turns" => 0, "duplicate" => 1, "capped" => 0)
    end
  end
end
