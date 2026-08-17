# frozen_string_literal: true

require "spec_helper"

# C3 — a shadow turn's answer lands in the pair store instead of the outbox,
# at the one terminal that already exists. E1 is stated as a spec, not an
# aspiration: zero outbox writes, zero `deliver` calls, exactly one pair.
RSpec.describe "ChannelDelivery shadow suppression" do
  # A channel that RAISES if anything ever asks it to deliver — the E1 net.
  class ShadowSpyChannel
    attr_reader :id, :delivered

    def initialize(id: "relay", shadow: true)
      @id = id
      @shadow = shadow
      @delivered = []
    end

    def shadow? = @shadow
    def deliver(*_args) = raise Insika::DeliveryError, "relay 'relay' is in shadow mode and must never deliver"
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:shadow_pairs) { Insika::ShadowPairStore.new(store: backend) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:event_stream) { ServerEventStreamDouble.new }
  let(:channels) do
    registry = Insika::ChannelRegistry.new
    registry.register("relay", ShadowSpyChannel.new)
    registry
  end

  def delivery(shadow_pairs: nil, criterion_sha: nil, channels: self.channels)
    Insika::ChannelDelivery.new(
      channels: channels, outbox: outbox, session_store: session_store,
      event_stream: event_stream, shadow_pairs: shadow_pairs, criterion_sha: criterion_sha,
      max_attempts: 1, backoff: [], sleeper: ->(_) {}
    )
  end

  # A persisted Task's command is a string-keyed Hash (TaskStore's shape).
  def task(command_payload: { "agent" => "agent-store-ocean-drop", "message" => "queria saber do pedido",
                             "event_id" => "wamid.HBg1" }, session_id: "relay:5511999998888")
    Struct.new(:id, :command, :session_id).new(
      "t-1", { "type" => "send_message", "payload" => command_payload,
               "meta" => { "transport" => "channel:relay" } }, session_id
    )
  end

  before do
    session_store.create(id: "relay:5511999998888",
                         vars: { "channel" => "relay", "external_id" => "5511999998888" })
  end

  it "E1 — a shadow turn writes exactly one pair and ZERO outbox records; deliver is never called" do
    result = delivery(shadow_pairs: shadow_pairs, criterion_sha: "sha256:abc")
                 .record_balloons(task: task, channel_id: "relay", content: "já confiro pra você",
                                  progressive: false)

    expect(result).to eq([]) # nothing to dispatch
    expect(outbox.pending).to be_empty
    pairs = shadow_pairs.each.to_a
    expect(pairs.length).to eq(1)
    pair = pairs.first
    expect(pair.insika_reply).to eq("já confiro pra você")
    expect(pair.inbound).to eq("queria saber do pedido")
    expect(pair.agent).to eq("agent-store-ocean-drop")
    expect(pair.session_id).to eq("relay:5511999998888")
    expect(pair.task_id).to eq("t-1")
    expect(pair.event_id).to eq("wamid.HBg1")
    expect(pair.criterion_sha).to eq("sha256:abc")
    expect(pair.status).to eq(:open) # the incumbent's half has not landed yet
  end

  it "correlates with the incumbent's half through the SAME digest" do
    delivery(shadow_pairs: shadow_pairs, criterion_sha: "sha256:abc")
      .record_balloons(task: task, channel_id: "relay", content: "já confiro pra você",
                       progressive: false)
    shadow_pairs.record_incumbent(
      id: Insika::ShadowPairStore.key_for(channel: "relay", external_id: "5511999998888",
                                          event_id: "wamid.HBg1"),
      channel: "relay", event_id: "wamid.HBg1",
      external_id: "5511999998888", reply: "me passa o número?"
    )
    expect(shadow_pairs.each.to_a.first.status).to eq(:complete)
  end

  it "a silent turn (empty content) still produces a pair — :silent once both halves land, never invisible" do
    delivery(shadow_pairs: shadow_pairs, criterion_sha: "sha256:abc")
      .record_balloons(task: task, channel_id: "relay", content: "", progressive: false)

    pair = shadow_pairs.each.to_a.first
    expect(pair).not_to be_nil
    expect(pair.insika_reply).to eq("")
    shadow_pairs.record_incumbent(
      id: pair.id, channel: "relay", event_id: "wamid.HBg1",
      external_id: "5511999998888", reply: "me passa o número?"
    )
    expect(shadow_pairs.find(pair.id).status).to eq(:silent)
    expect(outbox.pending).to be_empty
  end

  it "emits :shadow_recorded with metadata only — never the customer's text" do
    delivery(shadow_pairs: shadow_pairs, criterion_sha: "sha256:abc")
      .record_balloons(task: task, channel_id: "relay", content: "já confiro pra você",
                       progressive: false)

    recorded = event_stream.emitted.find { |e| e.type == :shadow_recorded }
    expect(recorded).not_to be_nil
    expect(recorded.data).to include(channel: "relay", agent: "agent-store-ocean-drop")
    expect(JSON.generate(recorded.data)).not_to include("queria saber do pedido")
  end

  it "a turn without event_id is unpairable: no pair, no outbox, one event" do
    delivery(shadow_pairs: shadow_pairs, criterion_sha: "sha256:abc")
      .record_balloons(task: task(command_payload: { "agent" => "a", "message" => "oi" }),
                       channel_id: "relay", content: "ola", progressive: false)

    expect(shadow_pairs.each.to_a).to be_empty
    expect(outbox.pending).to be_empty
    expect(event_stream.emitted.map(&:type)).to include(:shadow_unpairable)
  end

  it "E1's second lock — a hand-planted pending outbox record for a shadow channel fails loudly and never reaches the recipient" do
    planted = outbox.create(channel: "relay", to: "5511999998888", task_id: "t-1",
                            session_id: "relay:5511999998888", payload: { "content" => "x" })
    expect(delivery.deliver(planted.id)).to be(false)
    expect(outbox.find(planted.id).status).to eq(:failed)
    expect(outbox.find(planted.id).last_error).to include("shadow mode")
  end

  it "a non-shadow channel is byte-for-byte unchanged — the outbox path still runs" do
    normal = Insika::ChannelRegistry.new
    normal.register("relay", ShadowSpyChannel.new(shadow: false).tap do |c|
      c.define_singleton_method(:deliver) { |*| 202 }
    end)
    result = delivery(channels: normal).record_balloons(task: task, channel_id: "relay",
                                                        content: "ola", progressive: false)
    expect(result.size).to eq(1)
    expect(outbox.pending.length).to eq(1)
  end

  it "without a pair store wired, a shadow channel still delivers nothing (fail-closed, parity)" do
    result = delivery.record_balloons(task: task, channel_id: "relay",
                                      content: "ola", progressive: false)
    expect(result).to eq([])
    expect(outbox.pending).to be_empty
  end
end
