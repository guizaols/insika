# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/app"

# Phase 0 contract regression (doc 07 §7): POST /agent/messages still
# byte-compatível — mesma sequência de tipos de evento (:content* -> :done),
# headers idênticos e traduzindo para o Command :send_message.
RSpec.describe "POST /agent/messages (contrato legado Fase 0)" do
  def event(type, data = {}, task_id: "t-1")
    Harness::Event.new(type: type, data: data, meta: { task_id: task_id })
  end

  def build_app(bus:, event_stream:)
    Harness::Server::App.new(
      command_bus: bus, event_stream: event_stream,
      session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
      catalogs: {}, registries: {}, config: {}
    )
  end

  def call(app, body)
    app.call(Rack::MockRequest.env_for("/agent/messages", method: "POST", input: body))
  end

  # Drains an SSEBody body (Rack 3 streaming body) inside a reactor and
  # devolve os frames escritos no stream.
  def drain_sse(body)
    fs = SSEStreamDouble.new
    Sync { body.call(fs) }
    fs.chunks
  end

  # Extrai os tipos de evento das linhas `data: {...}` (ignora heartbeats).
  def event_types(chunks)
    chunks.filter_map do |chunk|
      next unless chunk.start_with?("data: ")

      JSON.parse(chunk.delete_prefix("data: ").strip)["type"]
    end
  end

  it "mantém a sequência de tipos da Fase 0 (:content* -> :done)" do
    events = [event(:content, { delta: "a" }), event(:content, { delta: "b" }),
              event(:done, { content: "ab" })]
    bus = ServerBusDouble.new { { task_id: "t-1" } }
    app = build_app(bus: bus, event_stream: ServerEventStreamDouble.new(events))

    _status, _headers, body = call(app, '{"agent":"sales","message":"oi"}')

    expect(event_types(drain_sse(body))).to eq(%w[content content done])
  end

  it "applies the 'sales' agent default when missing" do
    bus = ServerBusDouble.new { { task_id: "t-1" } }
    app = build_app(bus: bus, event_stream: ServerEventStreamDouble.new([event(:done)]))

    call(app, '{"message":"oi"}')

    expect(bus.dispatched.last.type).to eq(:send_message)
    expect(bus.dispatched.last.payload[:agent]).to eq("sales")
  end

  it "traduz history-only sem session_id (paridade D2)" do
    bus = ServerBusDouble.new { { task_id: "t-1" } }
    app = build_app(bus: bus, event_stream: ServerEventStreamDouble.new([event(:done)]))

    call(app, '{"message":"oi","history":[{"role":"user","content":"oi"}]}')

    payload = bus.dispatched.last.payload
    expect(payload[:history]).to eq([{ role: "user", content: "oi" }])
    expect(payload).not_to have_key(:session_id)
  end

  it "responde 200 com os headers SSE idênticos à Fase 0" do
    bus = ServerBusDouble.new { { task_id: "t-1" } }
    app = build_app(bus: bus, event_stream: ServerEventStreamDouble.new([event(:done)]))

    status, headers, = call(app, '{"message":"oi"}')

    expect(status).to eq(200)
    expect(headers).to include(
      "content-type" => "text/event-stream",
      "cache-control" => "no-cache",
      "connection" => "keep-alive"
    )
  end
end
