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

  # The item frames now say MORE: `added` carries the call's arguments, `done`
  # carries how it ended (status + the gate that held a blocked call).
  it "fills each call's arguments, status and gate from the added/done item frames" do
    raw = stream(
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "search_products", arguments: { "q" => "chocolate" } })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "search_products", result: "…", status: "ok" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "add_to_cart", arguments: { "id" => "999" } })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "add_to_cart", result: "…", status: "blocked", gate: "provenance" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "shipping_quote", arguments: {} })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "shipping_quote", result: "…", status: "error" })),
      Insika::Server::Responses.frame_for(Ev.new(:task_completed, {}))
    )
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:tool_calls]).to eq([
      { "name" => "search_products", "arguments" => { "q" => "chocolate" }, "status" => "ok" },
      { "name" => "add_to_cart", "arguments" => { "id" => "999" }, "status" => "blocked", "gate" => "provenance" },
      { "name" => "shipping_quote", "arguments" => {}, "status" => "error" }
    ])
  end

  it "closes the FIRST still-open call of that name when two calls of one batch run concurrently" do
    raw = stream(
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "search_products", arguments: { "q" => "a" } })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "search_products", arguments: { "q" => "b" } })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "search_products", result: "…", status: "error" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "search_products", result: "…", status: "ok" }))
    )
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:tool_calls].map { |t| t["status"] }).to eq(%w[error ok])
  end

  it "an older stream (added frames only, no arguments) still reduces to names with status nil" do
    raw = 'event: response.output_item.added' \
          "\ndata: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"name\":\"shipping_quote\"}}\n\n"
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:tool_calls]).to eq([{ "name" => "shipping_quote", "status" => nil }])
  end

  # load_skill / load_knowledge end with a :tool_result but are never announced
  # as a :tool_call — the in-process transport does not count them, so neither
  # does the HTTP replay (`max_tool_calls: 1` must grade the same on both).
  it "a done frame with no added frame (a system tool) is not a tool call" do
    raw = Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "load_skill", result: "…", status: "ok" }))
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:tool_calls]).to eq([])
  end

  it "pairs added/done by call_id, so two same-named calls finishing out of order keep their own status" do
    raw = stream(
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "add_to_cart", arguments: { "id" => "A" }, call_id: "c1" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_call, { name: "add_to_cart", arguments: { "id" => "B" }, call_id: "c2" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "add_to_cart", result: "…", status: "blocked",
                                                                 gate: "provenance", call_id: "c2" })),
      Insika::Server::Responses.frame_for(Ev.new(:tool_result, { name: "add_to_cart", result: "…", status: "ok", call_id: "c1" }))
    )
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:tool_calls]).to eq([
      { "name" => "add_to_cart", "arguments" => { "id" => "A" }, "status" => "ok" },
      { "name" => "add_to_cart", "arguments" => { "id" => "B" }, "status" => "blocked", "gate" => "provenance" }
    ])
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

  it "collects each insika.ui frame as a shown component with its count" do
    raw = stream(
      Insika::Server::Responses.frame_for(Ev.new(:ui, { component: "product_cards", title: nil, items: [{ "id" => "A" }],
                                                        count: 1, dropped: [] })),
      Insika::Server::Responses.frame_for(Ev.new(:content, { delta: "olha" })),
      Insika::Server::Responses.frame_for(Ev.new(:task_completed, {}))
    )
    r = described_class.reduce(described_class.payloads(raw))
    expect(r[:ui]).to eq([{ "component" => "product_cards", "count" => 1 }])
    expect(r[:output_text]).to eq("olha")
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
# In-process seeding: the same `seed_session` command the HTTP route dispatches,
# on the graph's own bus.
RSpec.describe Insika::Evals::GraphTransport, "#seed" do
  SeedBusDouble = Struct.new(:dispatched) do
    def dispatch(command) = (dispatched << command) && { ok: true }
  end
  SeedGraphDouble = Struct.new(:bus, :event_stream)
  SeedRuntimeDouble = Struct.new(:graph) do
    def chat(*) = "ok"
  end

  it "dispatches :seed_session with the conv as the id and the case's state" do
    bus = SeedBusDouble.new([])
    t = described_class.new(runtime: SeedRuntimeDouble.new(SeedGraphDouble.new(bus, nil)))
    t.seed("sim-1", { "evidence" => { "ids" => ["SKU-1"] } })

    command = bus.dispatched.first
    expect(command.type).to eq(:seed_session)
    expect(command.payload).to eq(id: "sim-1", state: { "evidence" => { "ids" => ["SKU-1"] } })
    expect(command.meta[:transport]).to eq(:internal)
  end

  it "a runtime with no graph cannot seed, and says so" do
    bare = Class.new { def chat(*) = "ok" }.new
    expect { described_class.new(runtime: bare).seed("sim-1", { "evidence" => {} }) }
      .to raise_error(Insika::Error, /cannot seed state/)
  end
end

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
