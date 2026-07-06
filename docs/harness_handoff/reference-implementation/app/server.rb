# frozen_string_literal: true

require "json"
require "rack"
require_relative "../lib/agent_runtime"
require_relative "../config/wiring"

# Corpo de resposta em streaming (SSE). Sob Falcon isso stream-a de
# verdade, sem bloquear (o encaixe async natural pro runtime segurando
# muitas conexões abertas). Sob Puma, prefira rodar o AGENT.run num job
# e streamar de volta — a decisão Fibers vs pool que você já conhece.
class SSEStream
  def initialize(&producer)
    @producer = producer
  end

  def each
    write = ->(event) { yield "data: #{JSON.generate(event.to_h)}\n\n" }
    @producer.call(write)
  end
end

# POST /agent/messages
#   { "message": "...", "history": [{"role":"user","content":"..."}], "context": {} }
# -> text/event-stream de Events
APP = lambda do |env|
  req = Rack::Request.new(env)

  unless req.post? && req.path == "/agent/messages"
    return [404, { "content-type" => "text/plain" }, ["not found"]]
  end

  payload = JSON.parse(req.body.read, symbolize_names: true)
  agent_id = payload[:agent] || "sales"
  message = payload.fetch(:message)
  history = payload[:history] || []

  body = SSEStream.new do |write|
    begin
      RUNNER.run(agent_id, message, history: history, &write)
    rescue => e
      write.call(AgentRuntime::Event.new(:error, { message: e.message }))
    end
  end

  headers = {
    "content-type" => "text/event-stream",
    "cache-control" => "no-cache",
    "connection" => "keep-alive"
  }
  [200, headers, body]
end
