# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/insika/server/responses"

# SSE reduction (runner). Pure over the /v1/responses stream — the frames
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

# GraphTransport: the in-process seam — the DSL runtime's chat, wrapped as a
# Transport so a simulated conversation exercises the local agent the way a
# customer would reach it, without a server.
RSpec.describe Insika::Evals::GraphTransport do
  class EvalGraphFakeRuntime
    attr_reader :seen

    def initialize(&script)
      @script = script
      @seen = []
    end

    def chat(message, session_id:, agent:)
      @seen << { message: message, session_id: session_id, agent: agent }
      @script.call(message)
    end
  end

  it "maps a runtime turn to a TurnOutcome, keying the conversation by conv" do
    rt = EvalGraphFakeRuntime.new { "hello from the graph" }
    t = described_class.new(runtime: rt)
    out = t.turn(agent: "loja", conv: "sim-1", message: "oi")
    expect(out.result.output_text).to eq("hello from the graph")
    expect(out.result.error).to be_nil
    expect(rt.seen.first).to eq(message: "oi", session_id: "sim-1", agent: "loja")
  end

  it "records a raised turn as a TurnOutcome error" do
    rt = EvalGraphFakeRuntime.new { raise Insika::Error, "turn failed" }
    out = described_class.new(runtime: rt).turn(agent: "loja", conv: "sim-1", message: "oi")
    expect(out.result.error).to eq("turn failed")
  end

  # Finding-fixed: the in-process transport must not be blind to tool activity.
  # A simulated conversation's transcript records the same tool names an HTTP
  # replay would, captured from the graph's :tool_call events.
  it "captures tool calls from the event stream, matching the HTTP shape" do
    stream = Insika::EventStream.new
    rt = EvalGraphFakeRuntime.new do |_message|
      stream.emit(Insika::Event.new(type: :tool_call, data: { name: "search_products", arguments: {} }))
      "ok"
    end
    out = described_class.new(runtime: rt, event_stream: stream).turn(agent: "loja", conv: "sim-1", message: "oi")
    expect(out.result.tool_calls).to eq([{ "name" => "search_products", "status" => nil }])
  end

  it "does not pick up non-tool events from the stream" do
    stream = Insika::EventStream.new
    rt = EvalGraphFakeRuntime.new do |_message|
      stream.emit(Insika::Event.new(type: :thinking, data: { delta: "..." }))
      "ok"
    end
    out = described_class.new(runtime: rt, event_stream: stream).turn(agent: "loja", conv: "sim-1", message: "oi")
    expect(out.result.tool_calls).to eq([])
  end
end

# A2ATransport: the same Simulator drives a REMOTE A2A agent through the outbound
# client — a thin wrapper, nothing else.
RSpec.describe Insika::Evals::A2ATransport do
  class EvalA2AFakeClient
    attr_reader :seen

    def initialize(&script)
      @script = script
      @seen = []
    end

    def call(url, text, context_id: nil)
      @seen << { url: url, text: text, context_id: context_id }
      @script.call
    end
  end

  it "sends the message with the conv as the A2A context id" do
    client = EvalA2AFakeClient.new { { text: "remote answer", state: "completed", id: "t1" } }
    t = described_class.new(client: client, url: "https://a2a.example.com")
    out = t.turn(agent: "remote", conv: "sim-1", message: "oi")
    expect(out.result.output_text).to eq("remote answer")
    expect(out.result.error).to be_nil
    expect(client.seen.first).to eq(url: "https://a2a.example.com", text: "oi", context_id: "sim-1")
  end

  it "surfaces a remote error as the turn error" do
    client = EvalA2AFakeClient.new { { error: "remote failed", state: "failed", id: nil } }
    out = described_class.new(client: client, url: "https://a2a.example.com")
               .turn(agent: "remote", conv: "sim-1", message: "oi")
    expect(out.result.error).to eq("remote failed")
  end
end
