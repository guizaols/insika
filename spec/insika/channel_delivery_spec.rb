# frozen_string_literal: true

require "spec_helper"

# record, claim, retry. The claim is the load-bearing one: it is
# what makes delivery at-most-once across a crash, and it is why the boot sweep
# leaves a half-delivered record alone.
RSpec.describe Insika::ChannelDelivery do
  # A Shape B channel that answers with a scripted sequence of statuses (or raises).
  class DeliveryChannelDouble
    attr_reader :calls

    def initialize(*statuses)
      @statuses = statuses
      @calls = []
    end

    def deliver(payload, to:, delivery_id: nil)
      @calls << { payload: payload, to: to, delivery_id: delivery_id }
      status = @statuses[@calls.size - 1] || @statuses.last
      raise status if status.is_a?(StandardError)

      status
    end
  end

  # A Shape A channel: it answers on the request's own stream, so it has no
  # `deliver` and nothing must ever be written to the outbox for it.
  class ShapeAChannelDouble
    def id = "web"
  end

  OutboxSessionDouble = Struct.new(:id, :vars)
  OutboxTaskDouble = Struct.new(:id, :session_id)

  let(:backend) { Insika::Stores::Memory.new }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:channels) { Insika::ChannelRegistry.new }
  let(:events) { ServerEventStreamDouble.new }
  let(:session) { OutboxSessionDouble.new("relay:551", { "channel" => "relay", "external_id" => "551" }) }
  let(:sessions) { ServerStoreDouble.new(session) }
  let(:task) { OutboxTaskDouble.new("t-1", "relay:551") }

  def dispatcher(**over)
    described_class.new(**{ channels: channels, outbox: outbox, session_store: sessions,
                            event_stream: events, sleeper: ->(_s) {} }.merge(over))
  end

  describe "record (at the turn's terminal)" do
    it "writes the answer, the recipient and the correlation" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      delivery = dispatcher.record(task: task, channel_id: "relay", content: "seu pedido saiu")

      expect(delivery.status).to eq(:pending)
      expect(delivery.to).to eq("551")
      expect(delivery.payload).to eq("session_id" => "relay:551", "task_id" => "t-1",
                                     "content" => "seu pedido saiu")
    end

    it "records nothing for a Shape A channel (it already answered on its stream)" do
      channels.register("web", ShapeAChannelDouble.new)
      expect(dispatcher.record(task: task, channel_id: "web", content: "hi")).to be_nil
      expect(outbox.pending).to be_empty
    end

    it "records nothing for an unregistered channel" do
      expect(dispatcher.record(task: task, channel_id: "slack", content: "hi")).to be_nil
    end

    # a turn that died mid-message published nothing, and half a sentence was
    # never an answer. Delivering an empty body would be worse than delivering late.
    it "records nothing when there is no answer to send" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      expect(dispatcher.record(task: task, channel_id: "relay", content: "   ")).to be_nil
    end

    it "records nothing when we do not know who to send it to" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      blank = described_class.new(channels: channels, outbox: outbox, event_stream: events,
                                  session_store: ServerStoreDouble.new(OutboxSessionDouble.new("x", {})))
      expect(blank.record(task: OutboxTaskDouble.new("t-2", "x"), channel_id: "relay", content: "hi")).to be_nil
    end

    # A session created before the channel wrote its vars still has its address in
    # the id itself, which is what the namespacing of is for.
    it "falls back to the channel's own id parsing when vars are missing" do
      channels.register("relay", Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h"))
      varless = described_class.new(channels: channels, outbox: outbox, event_stream: events,
                                    session_store: ServerStoreDouble.new(OutboxSessionDouble.new("relay:551", {})))
      expect(varless.record(task: task, channel_id: "relay", content: "hi").to).to eq("551")
    end
  end

  describe "deliver" do
    let(:channel) { DeliveryChannelDouble.new(200) }

    before { channels.register("relay", channel) }

    it "claims, POSTs once and marks it delivered" do
      delivery = dispatcher.record(task: task, channel_id: "relay", content: "pronto")

      expect(dispatcher.deliver(delivery.id)).to be(true)
      expect(channel.calls.size).to eq(1)
      expect(channel.calls.first[:delivery_id]).to eq(delivery.id)
      expect(outbox.find(delivery.id).status).to eq(:delivered)
    end

    # The claim, stated as a test: two callers (the terminal hook and the boot
    # sweep) may both reach the same record, and only one may reach the customer.
    it "is a no-op for the second caller — the recipient is touched once" do
      delivery = dispatcher.record(task: task, channel_id: "relay", content: "pronto")
      dispatcher.deliver(delivery.id)

      expect(dispatcher.deliver(delivery.id)).to be(false)
      expect(channel.calls.size).to eq(1)
    end

    it "retries a failing recipient up to the cap, then gives up" do
      flaky = DeliveryChannelDouble.new(503, 503, 503)
      d = deliver_through(flaky)

      expect(d[:ok]).to be(false)
      expect(flaky.calls.size).to eq(3)
      record = outbox.find(d[:id])
      expect(record.status).to eq(:failed)
      expect(record.last_error).to eq("HTTP 503")
    end

    it "stops retrying the moment it lands" do
      recovering = DeliveryChannelDouble.new(503, 200, 200)

      expect(deliver_through(recovering)[:ok]).to be(true)
      expect(recovering.calls.size).to eq(2)
    end

    it "treats a refused connection like a bad status (bounded, not fatal)" do
      d = deliver_through(DeliveryChannelDouble.new(Insika::DeliveryError.new("egress blocked")))

      expect(d[:ok]).to be(false)
      expect(outbox.find(d[:id]).last_error).to eq("egress blocked")
    end

    # A plugin was rolled back or disabled between the turn and the dispatch. There
    # is no way to send this reply; the record goes terminal so the boot sweep does
    # not spin on it forever.
    it "fails the record when the channel is gone by dispatch time" do
      registry = Insika::ChannelRegistry.new
      registry.register("relay", DeliveryChannelDouble.new(200), plugin: "insika-relay")
      own = dispatcher(channels: registry)
      d = own.record(task: task, channel_id: "relay", content: "pronto")
      registry.deregister_plugin("insika-relay")

      expect(own.deliver(d.id)).to be(false)
      record = outbox.find(d.id)
      expect(record.status).to eq(:failed)
      expect(record.last_error).to match(/not registered/)
    end

    it "announces the outcome on the event stream" do
      d = dispatcher.record(task: task, channel_id: "relay", content: "pronto")
      dispatcher.deliver(d.id)

      event = events.emitted.last
      expect(event.type).to eq(:channel_delivered)
      expect(event.data).to include(channel: "relay", outbox_id: d.id, status: "delivered", attempts: 1)
      expect(event.meta[:task_id]).to eq("t-1")
    end

    # Records and delivers through a registry holding just this channel, so each
    # example scripts its own sequence of statuses.
    def deliver_through(channel)
      registry = Insika::ChannelRegistry.new
      registry.register("relay", channel)
      own = dispatcher(channels: registry)
      delivery = own.record(task: task, channel_id: "relay", content: "pronto")
      { id: delivery.id, ok: own.deliver(delivery.id) }
    end
  end

  describe "sweep (boot)" do
    before { channels.register("relay", DeliveryChannelDouble.new(200)) }

    it "re-drives what a dead process recorded and never claimed" do
      d = dispatcher.record(task: task, channel_id: "relay", content: "pronto")

      expect(dispatcher.sweep).to eq(dispatched: [d.id])
      expect(outbox.find(d.id).status).to eq(:delivered)
    end

    # The other half of at-most-once: a record left `delivering` belonged to a
    # process that may have POSTed before it died. Re-sending it is exactly the
    # duplicate the claim exists to prevent, so the sweep does not touch it.
    it "leaves a claimed record alone, even though its outcome is unknown" do
      d = dispatcher.record(task: task, channel_id: "relay", content: "pronto")
      outbox.claim(d.id)

      expect(dispatcher.sweep).to eq(dispatched: [])
      expect(outbox.find(d.id).status).to eq(:delivering)
    end
  end
end
