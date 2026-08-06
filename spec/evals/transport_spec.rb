# frozen_string_literal: true

require "spec_helper"
require_relative "../../server/responses"

# SSE reduction (RFC-0008 runner). Pure over the /v1/responses stream — the frames
# are built with the REAL producer (server/responses.rb) so the eval can't silently
# drift from the contract it depends on.
RSpec.describe Insika::Evals::Sse do
  # Minimal Event double matching what Responses.frame_for reads.
  Ev = Struct.new(:type, :data)

  def stream(*frames) = frames.join

  it "reduces a real Responses stream into text + tool names + usage" do
    raw = stream(
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "shipping_quote" })),
      Insika::Server::Responses.frame_for(Ev.new(:content, { delta: "o frete é " })),
      Insika::Server::Responses.frame_for(Ev.new(:content, { delta: "R$ 20" })),
      Insika::Server::Responses.frame_for(Ev.new(:task_completed, { usage: { model: "deepseek-chat", input_tokens: 5 } }))
    )
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:output_text]).to eq("o frete é R$ 20")
    expect(r[:tool_calls].map { |t| t["name"] }).to eq(["shipping_quote"])
    expect(r[:usage]).to include("input_tokens" => 5)
    expect(r[:error]).to be_nil
  end

  it "surfaces a response.failed as the turn error" do
    raw = Insika::Server::Responses.frame_for(Ev.new(:task_failed, { message: "boom" }))
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:error]).to eq("boom")
  end

  it "ignores [DONE] and event: lines" do
    r = described_class.payloads("event: x\ndata: [DONE]\n\n")
    expect(r).to be_empty
  end
end
