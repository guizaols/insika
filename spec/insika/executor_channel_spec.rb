# frozen_string_literal: true

require "spec_helper"
require "async"

# the terminal hook. A turn that came in through a Shape B channel
# writes its answer to the outbox and hands it over; every other turn does nothing,
# and "every other turn" includes ones on the SAME session, which is the part worth
# a test rather than a comment.
RSpec.describe "Insika::Executor channel delivery" do
  # Shape B channel: remembers what it was asked to send.
  class SpyChannel
    attr_reader :sent

    def initialize = @sent = []

    def deliver(payload, to:, delivery_id: nil)
      @sent << { payload: payload, to: to, delivery_id: delivery_id }
      200
    end
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:channel) { SpyChannel.new }
  let(:channels) { Insika::ChannelRegistry.new.tap { |r| r.register("relay", channel) } }
  let(:profile) { Insika::AgentProfile.build(id: "support", model: "gpt", base_prompt: "SUPPORT") }

  let(:delivery) do
    Insika::ChannelDelivery.new(channels: channels, outbox: outbox, session_store: session_store,
                                event_stream: event_stream, sleeper: ->(_s) {})
  end

  def executor(channel_delivery: delivery)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "support" => profile },
      session_store: session_store, task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, channel_delivery: channel_delivery
    )
  end

  # A turn on the relay session, tagged with whatever transport the caller says.
  def run_turn(transport:, answer: "seu pedido saiu hoje", session_id: "relay:551")
    session_store.find(session_id) ||
      session_store.create(id: session_id, vars: { "channel" => "relay", "external_id" => "551" })
    command = Insika::Command.build(:send_message, { agent: "support", message: "cadê meu pedido?",
                                                     session_id: session_id },
                                    transport: transport).to_h
    task = task_store.create(command: command, session_id: session_id)

    exec = executor
    allow(exec).to receive(:create_chat) { FakeChat.new.tap { |c| c.final_content = answer } }
    Sync { exec.spawn(task, profile: profile) }
    task
  end

  it "delivers the answer of a turn that came in through the channel" do
    task = run_turn(transport: :"channel:relay")

    expect(channel.sent.size).to eq(1)
    sent = channel.sent.first
    expect(sent[:to]).to eq("551")
    expect(sent[:payload]).to eq("session_id" => "relay:551", "task_id" => task.id,
                                 "content" => "seu pedido saiu hoje")
    expect(sent[:delivery_id]).to eq(outbox.find(sent[:delivery_id]).id)
  end

  it "marks the outbox record delivered and says so on the event stream" do
    run_turn(transport: :"channel:relay")

    record = outbox.find(channel.sent.first[:delivery_id])
    expect(record.status).to eq(:delivered)
    expect(event_stream.events.map(&:type)).to include(:channel_delivered)
  end

  # The discriminator is the TURN's transport, not the session's channel. A session
  # belongs to the relay forever, but a message an operator types into the Studio
  # playground against that same conversation must not reach the customer — human
  # handoff is not a product feature, and this would be a surprising way to get one.
  it "delivers NOTHING for a turn on the same session that arrived another way" do
    run_turn(transport: :http)

    expect(channel.sent).to be_empty
    expect(outbox.pending).to be_empty
  end

  it "delivers nothing for a channel that is not registered" do
    run_turn(transport: :"channel:slack")

    expect(channel.sent).to be_empty
    expect(outbox.pending).to be_empty
  end

  it "is inert when the deployment wires no channel delivery at all" do
    exec = executor(channel_delivery: nil)
    session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
    command = Insika::Command.build(:send_message, { agent: "support", message: "oi", session_id: "relay:551" },
                                    transport: :"channel:relay").to_h
    task = task_store.create(command: command, session_id: "relay:551")
    allow(exec).to receive(:create_chat) { FakeChat.new.tap { |c| c.final_content = "oi!" } }

    expect { Sync { exec.spawn(task, profile: profile) } }.not_to raise_error
    expect(task_store.find(task.id).status).to eq(:completed)
  end

  # The turn is committed and durable before any of this runs. A third party being
  # down is not a reason to fail a turn that already answered correctly.
  it "never re-fails a committed turn when the delivery blows up" do
    exploding = Class.new do
      def record(**) = raise(Insika::StoreError, "outbox unavailable")
    end.new
    exec = executor(channel_delivery: exploding)
    session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
    command = Insika::Command.build(:send_message, { agent: "support", message: "oi", session_id: "relay:551" },
                                    transport: :"channel:relay").to_h
    task = task_store.create(command: command, session_id: "relay:551")
    allow(exec).to receive(:create_chat) { FakeChat.new.tap { |c| c.final_content = "oi!" } }

    Sync { exec.spawn(task, profile: profile) }
    expect(task_store.find(task.id).status).to eq(:completed)
  end

  describe "recover_channel_deliveries (boot)" do
    it "re-drives a reply a dead process recorded and never claimed" do
      task = task_store.create(command: { "type" => "send_message" }, session_id: "relay:551")
      session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
      record = outbox.create(channel: "relay", to: "551", task_id: task.id, session_id: "relay:551",
                             payload: { "content" => "pronto" })

      expect(executor.recover_channel_deliveries).to eq(dispatched: [record.id])
      expect(channel.sent.size).to eq(1)
    end

    it "reports nothing when no channel delivery is wired" do
      expect(executor(channel_delivery: nil).recover_channel_deliveries).to eq(dispatched: [])
    end
  end
end
