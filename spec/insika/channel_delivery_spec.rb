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

  describe "record_balloons (at the turn's terminal)" do
    it "writes the answer, the recipient and the correlation" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      delivery = dispatcher.record_balloons(task: task, channel_id: "relay",
                                            content: "seu pedido saiu", progressive: false).first

      expect(delivery.status).to eq(:pending)
      expect(delivery.to).to eq("551")
      expect(delivery.payload).to eq("session_id" => "relay:551", "task_id" => "t-1",
                                     "content" => "seu pedido saiu")
    end

    it "records nothing for a Shape A channel (it already answered on its stream)" do
      channels.register("web", ShapeAChannelDouble.new)
      expect(dispatcher.record_balloons(task: task, channel_id: "web", content: "hi",
                                        progressive: false)).to eq([])
      expect(outbox.pending).to be_empty
    end

    it "records nothing for an unregistered channel" do
      expect(dispatcher.record_balloons(task: task, channel_id: "slack", content: "hi",
                                        progressive: false)).to eq([])
    end

    # a turn that died mid-message published nothing, and half a sentence was
    # never an answer. Delivering an empty body would be worse than delivering late.
    it "records nothing when there is no answer to send" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      expect(dispatcher.record_balloons(task: task, channel_id: "relay", content: "   ",
                                        progressive: false)).to eq([])
    end

    it "records nothing when we do not know who to send it to" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      blank = described_class.new(channels: channels, outbox: outbox, event_stream: events,
                                  session_store: ServerStoreDouble.new(OutboxSessionDouble.new("x", {})))
      expect(blank.record_balloons(task: OutboxTaskDouble.new("t-2", "x"), channel_id: "relay",
                                   content: "hi", progressive: false)).to eq([])
    end

    # A session created before the channel wrote its vars still has its address in
    # the id itself, which is what the namespacing of is for.
    it "falls back to the channel's own id parsing when vars are missing" do
      channels.register("relay", Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h"))
      varless = described_class.new(channels: channels, outbox: outbox, event_stream: events,
                                    session_store: ServerStoreDouble.new(OutboxSessionDouble.new("relay:551", {})))
      expect(varless.record_balloons(task: task, channel_id: "relay",
                                     content: "hi", progressive: false).first.to).to eq("551")
    end
  end

  describe "record in shadow mode" do
    # A task that carried the event_id the correlation key needs.
    def shadow_task
      t = OutboxTaskDouble.new("t-1", "x")
      t.define_singleton_method(:command) do
        { "payload" => { "agent" => "a", "message" => "oi", "event_id" => "wamid.1" } }
      end
      t
    end

    def shadow_dispatcher(shadow_pairs:)
      channel = Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h",
                                            shadow: true, http: nil)
      channels.register("relay", channel)
      dispatcher(shadow_pairs: shadow_pairs, criterion_sha: "sha256:frozen",
                 session_store: ServerStoreDouble.new(OutboxSessionDouble.new("x", {})))
    end

    # The same empty-recipient guard the delivery path has: a pair keyed on an
    # empty external_id can never meet the mirror's half (a different digest),
    # so it would sit :open forever. Fail-closed, nothing recorded.
    it "records nothing when the shadow pair has no recipient — fail-closed, :shadow_unpairable" do
      pairs = Insika::ShadowPairStore.new(store: backend)
      expect(shadow_dispatcher(shadow_pairs: pairs).record_balloons(task: shadow_task,
                                                                    channel_id: "relay",
                                                                    content: "ola", progressive: false))
        .to eq([])
      expect(pairs.each.to_a).to be_empty
      expect(events.emitted.map(&:type)).to include(:shadow_unpairable)
    end
  end

  describe "record_balloons " do
    it "records one row with today's payload when the channel is not progressive" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                        content: "A.\n\nB.", progressive: false)

      expect(rows.size).to eq(1)
      expect(rows.first.index).to eq(0)
      expect(rows.first.payload).to eq("session_id" => "relay:551", "task_id" => "t-1",
                                       "content" => "A.\n\nB.")
    end

    it "splits a progressive answer into N ordered rows with index/final" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                        content: "A.\n\nB.", progressive: true)

      expect(rows.size).to eq(2)
      expect(rows.map(&:index)).to eq([0, 1])
      expect(rows.map { |r| r.payload["final"] }).to eq([false, true])
      expect(rows.map { |r| r.payload["content"] }).to eq(["A.", "B."])
      expect(rows.first.payload).to include("index" => 0, "final" => false)
      expect(rows.last.payload).to include("index" => 1, "final" => true)
    end

    it "a progressive turn that splits to ONE balloon omits index/final — indistinguishable from today" do
      channels.register("relay", DeliveryChannelDouble.new(200))
      rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                        content: "oi", progressive: true)

      expect(rows.size).to eq(1)
      expect(rows.first.payload).not_to have_key("index")
      expect(rows.first.payload).not_to have_key("final")
    end

    describe "attachments (— evidence cards on the outbox payload)" do
      before { channels.register("relay", DeliveryChannelDouble.new(200)) }

      it "absent attachments = today's payload exactly (no key)" do
        rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                          content: "hi", progressive: false)
        expect(rows.first.payload).not_to have_key("attachments")
      end

      it "valid attachments land on the payload" do
        rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                          content: "hi", progressive: false,
                                          attachments: [{ "type" => "card", "url" => "https://cdn/x.png",
                                                          "caption" => "Tênis" }])
        expect(rows.first.payload["attachments"])
          .to eq([{ "type" => "card", "url" => "https://cdn/x.png", "caption" => "Tênis" }])
      end

      it "malformed attachments are dropped, never a turn failure" do
        rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                          content: "hi", progressive: false,
                                          attachments: [{ "type" => "card" }, "junk",
                                                        { "url" => "https://ok" }])
        expect(rows.first.payload["attachments"])
          .to eq([{ "type" => "", "url" => "https://ok", "caption" => nil }])
      end

      it "a progressive split rides the attachments on the LAST balloon only" do
        rows = dispatcher.record_balloons(task: task, channel_id: "relay",
                                          content: "A.\n\nB.", progressive: true,
                                          attachments: [{ "url" => "https://cdn/x.png" }])
        expect(rows.first.payload).not_to have_key("attachments")
        expect(rows.last.payload["attachments"].size).to eq(1)
      end
    end

    it "returns [] through the same cheap exits as record" do
      expect(dispatcher.record_balloons(task: task, channel_id: "slack",
                                        content: "hi", progressive: true)).to eq([])
      channels.register("web", ShapeAChannelDouble.new)
      expect(dispatcher.record_balloons(task: task, channel_id: "web",
                                        content: "hi", progressive: true)).to eq([])
      channels.register("relay", DeliveryChannelDouble.new(200))
      expect(dispatcher.record_balloons(task: task, channel_id: "relay",
                                        content: "   ", progressive: true)).to eq([])
    end

    it "records ONE shadow pair for the whole answer, never one per balloon" do
      shadow_task = OutboxTaskDouble.new("t-1", "x")
      shadow_task.define_singleton_method(:command) do
        { "payload" => { "agent" => "a", "message" => "oi", "event_id" => "wamid.1" } }
      end
      pairs = Insika::ShadowPairStore.new(store: backend)
      shadow = Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h",
                                           shadow: true, http: nil)
      channels.register("relay", shadow)
      d = dispatcher(shadow_pairs: pairs, criterion_sha: "sha256:frozen",
                     session_store: ServerStoreDouble.new(OutboxSessionDouble.new("x",
                                                                                 { "external_id" => "551" })))
      rows = d.record_balloons(task: shadow_task, channel_id: "relay",
                               content: "A.\n\nB.", progressive: true)

      expect(rows).to eq([])
      expect(pairs.each.to_a.size).to eq(1)
      expect(pairs.each.to_a.first.insika_reply).to eq("A.\n\nB.")
    end
  end

  describe "deliver" do
    let(:channel) { DeliveryChannelDouble.new(200) }

    before { channels.register("relay", channel) }

    it "claims, POSTs once and marks it delivered" do
      delivery = dispatcher.record_balloons(task: task, channel_id: "relay",
                                            content: "pronto", progressive: false).first

      expect(dispatcher.deliver(delivery.id)).to be(true)
      expect(channel.calls.size).to eq(1)
      expect(channel.calls.first[:delivery_id]).to eq(delivery.id)
      expect(outbox.find(delivery.id).status).to eq(:delivered)
    end

    # The claim, stated as a test: two callers (the terminal hook and the boot
    # sweep) may both reach the same record, and only one may reach the customer.
    it "is a no-op for the second caller — the recipient is touched once" do
      delivery = dispatcher.record_balloons(task: task, channel_id: "relay",
                                            content: "pronto", progressive: false).first
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
      d = own.record_balloons(task: task, channel_id: "relay",
                              content: "pronto", progressive: false).first
      registry.deregister_plugin("insika-relay")

      expect(own.deliver(d.id)).to be(false)
      record = outbox.find(d.id)
      expect(record.status).to eq(:failed)
      expect(record.last_error).to match(/not registered/)
    end

    it "announces the outcome on the event stream" do
      d = dispatcher.record_balloons(task: task, channel_id: "relay",
                                    content: "pronto", progressive: false).first
      dispatcher.deliver(d.id)

      event = events.emitted.last
      expect(event.type).to eq(:channel_delivered)
      expect(event.data).to include(channel: "relay", outbox_id: d.id, status: "delivered", attempts: 1)
      expect(event.meta[:task_id]).to eq("t-1")
    end

    it "a FAILED delivery also emits :delivery_failed (the WS6 alert face)" do
      failing = DeliveryChannelDouble.new(500)
      registry = Insika::ChannelRegistry.new
      registry.register("relay", failing)
      d = dispatcher(channels: registry).record_balloons(task: task, channel_id: "relay",
                                                         content: "pronto", progressive: false).first
      dispatcher(channels: registry).deliver(d.id)

      types = events.emitted.map(&:type)
      expect(types).to include(:channel_delivered, :delivery_failed)
      alert = events.emitted.find { |e| e.type == :delivery_failed }
      expect(alert.data).to include(channel: "relay", status: "failed")
    end

    # Records and delivers through a registry holding just this channel, so each
    # example scripts its own sequence of statuses.
    def deliver_through(channel)
      registry = Insika::ChannelRegistry.new
      registry.register("relay", channel)
      own = dispatcher(channels: registry)
      delivery = own.record_balloons(task: task, channel_id: "relay",
                                      content: "pronto", progressive: false).first
      { id: delivery.id, ok: own.deliver(delivery.id) }
    end
  end

  describe "sweep (boot)" do
    before { channels.register("relay", DeliveryChannelDouble.new(200)) }

    it "re-drives what a dead process recorded and never claimed" do
      d = dispatcher.record_balloons(task: task, channel_id: "relay",
                                    content: "pronto", progressive: false).first

      expect(dispatcher.sweep).to eq(dispatched: [d.id])
      expect(outbox.find(d.id).status).to eq(:delivered)
    end

    # The other half of at-most-once: a record left `delivering` belonged to a
    # process that may have POSTed before it died. Re-sending it is exactly the
    # duplicate the claim exists to prevent, so the sweep does not touch it.
    it "leaves a claimed record alone, even though its outcome is unknown" do
      d = dispatcher.record_balloons(task: task, channel_id: "relay",
                                    content: "pronto", progressive: false).first
      outbox.claim(d.id)

      expect(dispatcher.sweep).to eq(dispatched: [])
      expect(outbox.find(d.id).status).to eq(:delivering)
    end
  end
end
