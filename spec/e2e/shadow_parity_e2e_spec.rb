# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0025 E2, as a spec: a scripted mirrored conversation of N exchanges — our
# turn runs end to end through a shadow channel, the mirror reports the reply
# the customer actually got — yields N complete pairs and an incomplete rate of
# 0. This is the fixture that makes the >20% discard condition measurable
# against a real staging run.
RSpec.describe "smoke E2E: shadow parity, mirrored exchanges" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:shadow_pairs) { Insika::ShadowPairStore.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:relay) do
    Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h",
                                shadow: true, http: nil)
  end
  let(:channels) { Insika::ChannelRegistry.new.tap { |r| r.register("relay", relay) } }
  let(:profiles) { { "support" => Insika::AgentProfile.build(id: "support", model: "fake", base_prompt: "S") } }

  let(:delivery) do
    Insika::ChannelDelivery.new(channels: channels, outbox: outbox, session_store: session_store,
                                event_stream: event_stream, shadow_pairs: shadow_pairs,
                                criterion_sha: "sha256:frozen")
  end

  def executor
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      channel_delivery: delivery
    )
  end

  def run_exchange(event_id:, answer:)
    command = Insika::Command.build(
      :send_message,
      { agent: "support", message: "queria saber do pedido",
        session_id: "relay:5511", event_id: event_id },
      transport: :"channel:relay"
    ).to_h
    task = task_store.create(command: command, session_id: "relay:5511")

    exec = executor
    chat = FakeChat.new.tap { |c| c.final_content = answer }
    allow(exec).to receive(:create_chat).and_return(chat)
    Sync { exec.spawn(task, profile: profiles["support"]) }
    task
  end

  it "N mirrored exchanges -> N complete pairs, zero outbox records, incomplete rate 0" do
    session_store.create(id: "relay:5511", vars: { "channel" => "relay", "external_id" => "5511" })
    mirror = Insika::Commands::RecordShadowReply.new(shadow_pairs: shadow_pairs,
                                                     event_stream: event_stream)

    3.times do |i|
      event_id = "wamid.HBg#{i}"
      run_exchange(event_id: event_id, answer: "seu pedido saiu hoje (#{i})")
      # the mirror reports what the customer ACTUALLY received
      mirror.call(Insika::Command.build(
                    :record_shadow_reply,
                    { channel: "relay", external_id: "5511", event_id: event_id,
                      reply: "me passa o número do pedido?" },
                    transport: :"channel:relay"
                  ))
    end

    pairs = shadow_pairs.each.to_a
    expect(pairs.length).to eq(3)
    expect(pairs.map(&:status)).to all(eq(:complete))
    expect(shadow_pairs.counts[:incomplete]).to eq(0)
    expect(outbox.pending).to be_empty
    expect(pairs).to all(satisfy { |p| p.criterion_sha == "sha256:frozen" })
    expect(pairs.first.inbound).to eq("queria saber do pedido")
    expect(pairs.first.insika_reply).to include("seu pedido saiu hoje")
    expect(pairs.first.incumbent_reply).to eq("me passa o número do pedido?")
  end
end
