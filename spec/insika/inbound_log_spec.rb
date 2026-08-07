# frozen_string_literal: true

require "spec_helper"

# RFC-0011 §6.4 — the retry window. Without it, one flaky ack costs a second LLM
# turn and sends the customer the same answer twice.
RSpec.describe Insika::InboundLog do
  let(:backend) { Insika::Stores::Memory.new }
  let(:now) { Time.utc(2026, 8, 7, 12, 0, 0) }
  let(:clock) { -> { @now } }
  let(:log) { described_class.new(store: backend, ttl: 60, clock: clock) }

  before { @now = now }

  it "returns nil for an id it has never seen" do
    expect(log.find("wamid.1")).to be_nil
  end

  it "gives back the task the id already produced" do
    log.record("wamid.1", "t-1")
    expect(log.find("wamid.1")).to eq("t-1")
  end

  it "forgets an id once the window closes, so the same id is honestly new" do
    log.record("wamid.1", "t-1")
    @now = now + 61
    expect(log.find("wamid.1")).to be_nil
  end

  it "deletes the expired entry as it reads it (no dead weight)" do
    log.record("wamid.1", "t-1")
    @now = now + 61
    log.find("wamid.1")
    expect(backend.list("inbound")).to be_empty
  end

  it "refreshes the window on a re-record" do
    log.record("wamid.1", "t-1")
    @now = now + 59
    log.record("wamid.1", "t-1")
    @now = now + 100
    expect(log.find("wamid.1")).to eq("t-1")
  end

  describe "sweep" do
    it "drops only what nobody came back for" do
      log.record("old", "t-1")
      @now = now + 61
      log.record("fresh", "t-2")

      expect(log.sweep).to eq(1)
      expect(log.find("fresh")).to eq("t-2")
    end
  end

  # Fail-safe, not fail-open: a record with no expiry is kept rather than treated
  # as expired. Dropping it would turn a storage oddity into a duplicated turn.
  it "keeps a record whose expiry is missing or unparseable" do
    backend.set("inbound", "inbound:weird", { "key" => "weird", "task_id" => "t-9", "expires_at" => "not a time" })
    expect(log.find("weird")).to eq("t-9")
  end
end
