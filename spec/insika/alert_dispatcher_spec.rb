# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::AlertDispatcher do
  let(:backend) { Insika::Stores::Memory.new }
  let(:event_stream) { Insika::EventStream.new }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:channels) { Insika::ChannelRegistry.new }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:http) { double("http") }
  let(:profile) do
    Insika::AgentProfile.build(id: "bia", model: "m",
                               alerts: { "webhook" => "https://ops.example.com/alerts" })
  end
  let(:profiles) { Insika::StaticProfileSource.new({ "bia" => profile }) }
  subject(:dispatcher) do
    described_class.new(event_stream: event_stream, outbox: outbox, channels: channels,
                        profiles: profiles, task_store: task_store, http: http)
  end

  def event(type, data, task_id: "t-1", session_id: "s-1")
    Insika::Event.new(type: type, data: data,
                      meta: { task_id: task_id, session_id: session_id, at: "t" })
  end

  it "a budget_warning with the agent writes ONE outbox row for the webhook and registers it" do
    dispatcher.handle(event(:budget_warning, { agent: "bia", window: "daily", spent: 900, cap: 1000 }))

    pending = outbox.pending
    expect(pending.size).to eq(1)
    row = pending.first
    expect(row.channel).to eq("webhook:#{Digest::SHA1.hexdigest('https://ops.example.com/alerts')[0, 8]}")
    expect(row.to).to eq("https://ops.example.com/alerts")
    expect(row.payload).to include("type" => "budget_warning", "agent" => "bia")
    expect(row.payload["data"]).to include("window" => "daily", "spent" => 900)
    expect(channels.find(row.channel)).to be_a(Insika::Channels::Webhook)
  end

  it "a breaker_open with the agent is answered the same way" do
    dispatcher.handle(event(:breaker_open, { agent: "bia", ref: "deepseek/deepseek-v4-flash" }))

    expect(outbox.pending.size).to eq(1)
    expect(outbox.pending.first.payload["type"]).to eq("breaker_open")
  end

  it "a delivery_failed resolves the agent from its task's command" do
    command = Insika::Command.build(:send_message, { agent: "bia", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s-1", id: "t-9")

    dispatcher.handle(event(:delivery_failed, { channel: "relay", status: "failed" }, task_id: "t-9"))

    expect(outbox.pending.size).to eq(1)
    expect(outbox.pending.first.payload["agent"]).to eq("bia")
  end

  it "a webhook's OWN delivery failing is NOT re-alerted (loop guard)" do
    dispatcher.handle(event(:delivery_failed, { channel: "webhook:abc12345", status: "failed" }))
    expect(outbox.pending).to be_empty
  end

  it "registers every profile-configured webhook at construction (no alert event needed)" do
    described_class.new(event_stream: event_stream, outbox: outbox, channels: channels,
                        profiles: profiles, task_store: task_store, http: http)
    channel_id = "webhook:#{Digest::SHA1.hexdigest('https://ops.example.com/alerts')[0, 8]}"
    expect(channels.find(channel_id)).to be_a(Insika::Channels::Webhook)
  end

  it "so the boot sweep delivers a crashed process's pending webhook alert (not mark-failed terminal)" do
    url = "https://8.8.8.8/alerts" # egress-clean, so the delivery actually POSTs
    webhook_profile = Insika::AgentProfile.build(id: "bia", model: "m", alerts: { "webhook" => url })
    sources = Insika::StaticProfileSource.new({ "bia" => webhook_profile })

    # a RESTART: the fresh dispatcher re-registers the webhook from profile
    # config BEFORE the boot recovery's channel sweep looks for its outbox rows.
    described_class.new(event_stream: event_stream, outbox: outbox, channels: channels,
                        profiles: sources, task_store: task_store, http: http)
    channel_id = "webhook:#{Digest::SHA1.hexdigest(url)[0, 8]}"
    expect(channels.find(channel_id)).to be_a(Insika::Channels::Webhook)

    # what the crashed process left, sitting pending in the outbox
    delivery = outbox.create(channel: channel_id, to: url, task_id: "t-1", session_id: "s-1",
                             payload: { "type" => "budget_warning", "agent" => "bia" })
    allow(http).to receive(:request).and_return(status: 200, body: "ok")

    delivery_service = Insika::ChannelDelivery.new(channels: channels, outbox: outbox,
                                                   session_store: nil, sleeper: ->(_s) {})
    expect(delivery_service.sweep[:dispatched]).to eq([delivery.id])
    expect(outbox.find(delivery.id).status).to eq(:delivered)
  end

  it "an agent without alerts config answers nothing" do
    plain = Insika::AgentProfile.build(id: "silent", model: "m")
    profiles = Insika::StaticProfileSource.new({ "silent" => plain })
    dispatcher = described_class.new(event_stream: event_stream, outbox: outbox, channels: channels,
                                     profiles: profiles, task_store: task_store, http: http)

    dispatcher.handle(event(:budget_warning, { agent: "silent" }))

    expect(outbox.pending).to be_empty
  end

  it "non-alert events are ignored (the dispatcher is not a recorder of everything)" do
    dispatcher.handle(event(:content, { delta: "oi" }))
    expect(outbox.pending).to be_empty
  end

  it "never raises: a store/registry failure cannot break the turn" do
    broken = Insika::OutboxStore.new(store: Insika::Stores::Memory.new)
    allow(broken).to receive(:create).and_raise(Insika::StoreError, "db caiu")
    dispatcher = described_class.new(event_stream: event_stream, outbox: broken,
                                     channels: channels, profiles: profiles,
                                     task_store: task_store, http: http)

    expect { dispatcher.handle(event(:budget_warning, { agent: "bia" })) }.not_to raise_error
  end
end