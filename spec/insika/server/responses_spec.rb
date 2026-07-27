# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/responses"
require_relative "../../../server/sse_body"

# Phase 6 Stage A: OpenAI Responses adapter (/v1/responses) — drop-in for the
# OpenClaw gateway. Tests request parsing and the Event->SSE frame map (fidelity
# to the OpenclawDispatcher parser, R1).
RSpec.describe Insika::Server::Responses do
  # minimal req responding to get_header (unique name so it doesn't leak a constant).
  RespReqDouble = Struct.new(:headers) do
    def get_header(k) = headers[k]
  end
  def req(headers = {}) = RespReqDouble.new(headers)

  def ev(type, data = {}) = Insika::Event.new(type: type, data: data, meta: { task_id: "t" })

  describe ".parse_request" do
    it "extracts the agent from model 'openclaw:<agent>', user, and string input" do
      body = { model: "openclaw:agent-store-x", user: "chat-1", stream: true, input: "oi" }
      out = described_class.parse_request(body, req)
      expect(out).to eq(agent: "agent-store-x", user: "chat-1", message: "oi")
    end

    it "falls back to the X-Openclaw-Agent header when the model has no agent" do
      out = described_class.parse_request({ user: "c", input: "x" }, req("HTTP_X_OPENCLAW_AGENT" => "agent-y"))
      expect(out[:agent]).to eq("agent-y")
    end

    it "input as an array of parts -> joins the texts" do
      body = { model: "openclaw:a", user: "c", input: [{ text: "linha1" }, { "text" => "linha2" }] }
      expect(described_class.parse_request(body, req)[:message]).to eq("linha1\nlinha2")
    end

    it "validates missing agent/user/input" do
      expect { described_class.parse_request({ user: "c", input: "x" }, req) }
        .to raise_error(Insika::ValidationError, /agent/)
      expect { described_class.parse_request({ model: "openclaw:a", input: "x" }, req) }
        .to raise_error(Insika::ValidationError, /user/)
      expect { described_class.parse_request({ model: "openclaw:a", user: "c", input: "  " }, req) }
        .to raise_error(Insika::ValidationError, /input/)
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

    it ":task_completed -> response.completed + [DONE]" do
      f = described_class.frame_for(ev(:task_completed, {}))
      expect(f).to include('"type":"response.completed"')
      expect(f).to end_with("data: [DONE]\n\n")
    end

    it ":task_completed with usage -> response.completed carries usage (tokens) + model (Phase 6)" do
      f = described_class.frame_for(ev(:task_completed, { usage: { input_tokens: 12, output_tokens: 8,
                                                                   total_tokens: 20, model: "deepseek-chat" } }))
      expect(f).to include('"usage"', '"input_tokens":12', '"output_tokens":8', '"total_tokens":20')
      expect(f).to include('"model":"deepseek-chat"')
      # model is a sibling of usage in the OpenAI shape, not INSIDE usage
      expect(f).not_to match(/"usage":\{[^}]*"model"/)
    end

    it ":task_failed -> response.failed + [DONE]" do
      f = described_class.frame_for(ev(:task_failed, { message: "boom" }))
      expect(f).to include('"type":"response.failed"')
      expect(f).to include('"message":"boom"')
      expect(f).to include("data: [DONE]")
    end

    it "events with no match -> nil (skipped)" do
      expect(described_class.frame_for(ev(:task_started))).to be_nil
      expect(described_class.frame_for(ev(:tool_result, { name: "x", result: "y" }))).to be_nil
      expect(described_class.frame_for(ev(:skill_activated, { name: "s" }))).to be_nil
    end

    it ":thinking -> nil: the provider's reasoning NEVER crosses the edge" do
      expect(described_class.frame_for(ev(:thinking, { delta: "deixa eu pensar" }))).to be_nil
    end
  end

  it "drains a whole turn as OpenAI Responses frames (SSE integration)" do
    stream = Insika::EventStream.new
    sub = stream.subscribe
    chunks = []

    fs = SSEStreamDouble.new
    Sync do
      collector = Async do
        Insika::Server::SSEBody.new(subscription: sub, serialize: described_class.method(:frame_for)).call(fs)
      end
      stream.emit(ev(:thinking, { delta: "vou saudar o cliente" })) # internal only
      stream.emit(ev(:content, { delta: "Oi" }))
      stream.emit(ev(:tool_call, { name: "search_products" }))
      stream.emit(ev(:content, { delta: " tudo bem?" }))
      stream.emit(ev(:task_started)) # no match: does not become a frame
      stream.emit(ev(:task_completed, {}))
      sub.close
      collector.wait
    end

    chunks = fs.chunks
    joined = chunks.join
    expect(joined).to include('"delta":"Oi"')
    expect(joined).to include('"name":"search_products"')
    expect(joined).to include('"delta":" tudo bem?"')
    expect(joined).to include('"type":"response.completed"')
    expect(joined).to end_with("data: [DONE]\n\n")
    expect(joined).not_to include("task_started") # skipped event
    expect(joined).not_to include("vou saudar o cliente") # reasoning stays internal
  end
end
