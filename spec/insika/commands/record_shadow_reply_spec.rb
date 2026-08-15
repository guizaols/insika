# frozen_string_literal: true

require "spec_helper"

# C4 — the incumbent's half, one command with two doors (Shape 1 rides the
# mirror call itself, Shape 2 is the follow-up route). Both produce the
# identical pair; a retry never rewrites evidence.
RSpec.describe Insika::Commands::RecordShadowReply do
  let(:backend) { Insika::Stores::Memory.new }
  let(:shadow_pairs) { Insika::ShadowPairStore.new(store: backend) }
  let(:events) { ServerEventStreamDouble.new }
  let(:command) { described_class.new(shadow_pairs: shadow_pairs, event_stream: events) }

  def payload(**over)
    { channel: "relay", external_id: "5511999998888", event_id: "wamid.HBg1",
      reply: "me passa o número do pedido?" }.merge(over)
  end

  def build(**over) = Insika::Command.build(:record_shadow_reply, payload(**over))

  it "records the incumbent half on the SAME digest our half computes" do
    result = command.call(build)
    pair = shadow_pairs.find(result[:pair_id])
    expect(result[:pair_id]).to eq(Insika::ShadowPairStore.key_for(channel: "relay",
                                                                   external_id: "5511999998888",
                                                                   event_id: "wamid.HBg1"))
    expect(pair.status).to eq(:open)
    expect(pair.incumbent_reply).to eq("me passa o número do pedido?")
  end

  it "completes a pair our half started" do
    ours = Insika::ShadowPairStore.key_for(channel: "relay", external_id: "5511999998888",
                                           event_id: "wamid.HBg1")
    shadow_pairs.record_ours(id: ours, channel: "relay", agent: "a",
                             session_id: "relay:5511999998888", task_id: "t",
                             event_id: "wamid.HBg1", inbound: "oi", reply: "ola",
                             criterion_sha: "sha256:x")
    result = command.call(build)
    expect(result[:status]).to eq("complete")
    expect(shadow_pairs.find(ours).status).to eq(:complete)
  end

  it "creates the pair when it does not exist yet — the mirror may legitimately arrive first" do
    result = command.call(build)
    expect(result[:status]).to eq("open")
  end

  it "is idempotent: a second reply for the same pair is ignored, first write wins" do
    command.call(build)
    retry_result = command.call(build(reply: "REWRITTEN BY A RETRY"))
    expect(retry_result[:status]).to eq("already_recorded")
    pair = shadow_pairs.find(retry_result[:pair_id])
    expect(pair.incumbent_reply).to eq("me passa o número do pedido?")
  end

  it "refuses a missing field" do
    expect { command.call(build(event_id: nil)) }.to raise_error(Insika::ValidationError, /event_id/)
    expect { command.call(build(external_id: " ")) }.to raise_error(Insika::ValidationError, /external_id/)
    expect { command.call(build(reply: nil)) }.to raise_error(Insika::ValidationError, /reply/)
  end

  it "emits metadata only — the customer's reply never reaches the stream" do
    command.call(build)
    emitted = events.emitted.find { |e| e.type == :shadow_reply_recorded }
    expect(emitted).not_to be_nil
    expect(JSON.generate(emitted.data)).not_to include("me passa o número")
  end
end
