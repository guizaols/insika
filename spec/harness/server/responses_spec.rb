# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/responses"
require_relative "../../../server/sse_body"

# Fase 6 Etapa A: adapter OpenAI Responses (/v1/responses) — drop-in do gateway
# OpenClaw. Testa o parse do request e o mapa Event->frame SSE (fidelidade ao
# parser do OpenclawDispatcher, R1).
RSpec.describe Harness::Server::Responses do
  # req mínimo respondendo a get_header (nome único p/ não vazar constante).
  RespReqDouble = Struct.new(:headers) do
    def get_header(k) = headers[k]
  end
  def req(headers = {}) = RespReqDouble.new(headers)

  def ev(type, data = {}) = Harness::Event.new(type: type, data: data, meta: { task_id: "t" })

  describe ".parse_request" do
    it "extrai agente de model 'openclaw:<agent>', user e input string" do
      body = { model: "openclaw:agent-store-x", user: "chat-1", stream: true, input: "oi" }
      out = described_class.parse_request(body, req)
      expect(out).to eq(agent: "agent-store-x", user: "chat-1", message: "oi")
    end

    it "cai no header X-Openclaw-Agent quando model não tem agente" do
      out = described_class.parse_request({ user: "c", input: "x" }, req("HTTP_X_OPENCLAW_AGENT" => "agent-y"))
      expect(out[:agent]).to eq("agent-y")
    end

    it "input como array de partes -> junta os textos" do
      body = { model: "openclaw:a", user: "c", input: [{ text: "linha1" }, { "text" => "linha2" }] }
      expect(described_class.parse_request(body, req)[:message]).to eq("linha1\nlinha2")
    end

    it "valida agente/user/input ausentes" do
      expect { described_class.parse_request({ user: "c", input: "x" }, req) }
        .to raise_error(Harness::ValidationError, /agent/)
      expect { described_class.parse_request({ model: "openclaw:a", input: "x" }, req) }
        .to raise_error(Harness::ValidationError, /user/)
      expect { described_class.parse_request({ model: "openclaw:a", user: "c", input: "  " }, req) }
        .to raise_error(Harness::ValidationError, /input/)
    end
  end

  describe ".frame_for" do
    it ":content -> response.output_text.delta" do
      f = described_class.frame_for(ev(:content, { delta: "Oi" }))
      expect(f).to include("event: response.output_text.delta")
      expect(f).to include('"type":"response.output_text.delta"')
      expect(f).to include('"delta":"Oi"')
    end

    it ":tool_call -> response.output_item.added (function_call)" do
      f = described_class.frame_for(ev(:tool_call, { name: "search_products", arguments: {} }))
      expect(f).to include('"type":"response.output_item.added"')
      expect(f).to include('"type":"function_call"')
      expect(f).to include('"name":"search_products"')
    end

    it ":done -> response.completed + [DONE]" do
      f = described_class.frame_for(ev(:done, {}))
      expect(f).to include('"type":"response.completed"')
      expect(f).to end_with("data: [DONE]\n\n")
    end

    it ":task_failed -> response.failed + [DONE]" do
      f = described_class.frame_for(ev(:task_failed, { message: "boom" }))
      expect(f).to include('"type":"response.failed"')
      expect(f).to include('"message":"boom"')
      expect(f).to include("data: [DONE]")
    end

    it "eventos sem correspondência -> nil (pulados)" do
      expect(described_class.frame_for(ev(:task_started))).to be_nil
      expect(described_class.frame_for(ev(:tool_result, { name: "x", result: "y" }))).to be_nil
      expect(described_class.frame_for(ev(:skill_activated, { name: "s" }))).to be_nil
    end
  end

  it "drena um turno inteiro como frames OpenAI Responses (integração SSE)" do
    stream = Harness::EventStream.new
    sub = stream.subscribe
    chunks = []

    Sync do
      collector = Async do
        Harness::Server::SSEBody.new(subscription: sub, serialize: described_class.method(:frame_for))
                                .each { |c| chunks << c }
      end
      stream.emit(ev(:content, { delta: "Oi" }))
      stream.emit(ev(:tool_call, { name: "search_products" }))
      stream.emit(ev(:content, { delta: " tudo bem?" }))
      stream.emit(ev(:task_started)) # sem correspondência: não vira frame
      stream.emit(ev(:done, {}))
      sub.close
      collector.wait
    end

    joined = chunks.join
    expect(joined).to include('"delta":"Oi"')
    expect(joined).to include('"name":"search_products"')
    expect(joined).to include('"delta":" tudo bem?"')
    expect(joined).to include('"type":"response.completed"')
    expect(joined).to end_with("data: [DONE]\n\n")
    expect(joined).not_to include("task_started") # evento pulado
  end
end
