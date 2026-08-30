# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../lib/insika/server/responses"
require_relative "../../../lib/insika/server/sse_body"

# OpenAI Responses adapter (v1/responses) — drop-in for the
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
    it "extracts the agent from model 'insika:<agent>', user, and string input" do
      body = { model: "insika:agent-store-x", user: "chat-1", stream: true, input: "oi" }
      out = described_class.parse_request(body, req)
      expect(out).to eq(agent: "agent-store-x", user: "chat-1", message: "oi")
    end

    it "falls back to the X-Insika-Agent header when the model has no agent" do
      out = described_class.parse_request({ user: "c", input: "x" }, req("HTTP_X_INSIKA_AGENT" => "agent-y"))
      expect(out[:agent]).to eq("agent-y")
    end

    it "input as an array of parts -> joins the texts" do
      body = { model: "insika:a", user: "c", input: [{ text: "linha1" }, { "text" => "linha2" }] }
      expect(described_class.parse_request(body, req)[:message]).to eq("linha1\nlinha2")
    end

    it "input as an array with a MALFORMED part is refused (422)" do
      body = { model: "insika:a", user: "c",
               input: [{ text: "linha1" }, { "type" => "image" }] } # image without url
      expect { described_class.parse_request(body, req) }
        .to raise_error(Insika::ValidationError, /malformed content part/)
    end

    it "validates missing agent/user/input" do
      expect { described_class.parse_request({ user: "c", input: "x" }, req) }
        .to raise_error(Insika::ValidationError, /agent/)
      expect { described_class.parse_request({ model: "insika:a", input: "x" }, req) }
        .to raise_error(Insika::ValidationError, /user/)
      expect { described_class.parse_request({ model: "insika:a", user: "c", input: "  " }, req) }
        .to raise_error(Insika::ValidationError, /input/)
    end

    # The anchor case of WS9: a WhatsApp voice note has no caption, so the
    # input array carries ONE audio part and no text at all. Joining only the
    # text parts made that "input empty" — a 422 before the turn existed.
    it "input with ONLY a media part (a voice note) is accepted, message empty" do
      body = { model: "insika:a", user: "c",
               input: [{ "type" => "audio", "url" => "https://cdn.example.com/v.ogg" }] }
      out = described_class.parse_request(body, req)

      expect(out[:message]).to eq("")
      expect(out[:parts]).to eq([{ "type" => "audio", "url" => "https://cdn.example.com/v.ogg" }])
    end

    # Document is additive to the multimodal input contract, same
    # shape discipline as audio/image.
    it "input with ONLY a document part (no caption) is accepted, message empty" do
      body = { model: "insika:a", user: "c",
               input: [{ "type" => "document", "url" => "https://cdn.example.com/receita.pdf" }] }
      out = described_class.parse_request(body, req)

      expect(out[:message]).to eq("")
      expect(out[:parts]).to eq([{ "type" => "document", "url" => "https://cdn.example.com/receita.pdf" }])
    end

    it "input as an array with a MALFORMED document part is refused (422)" do
      body = { model: "insika:a", user: "c", input: [{ "type" => "document" }] } # no url
      expect { described_class.parse_request(body, req) }
        .to raise_error(Insika::ValidationError, /malformed content part/)
    end

    it "input with only EMPTY text parts is still empty (a part is not a loophole)" do
      body = { model: "insika:a", user: "c", input: [{ "type" => "text", "text" => "   " }] }
      expect { described_class.parse_request(body, req) }
        .to raise_error(Insika::ValidationError, /input empty/)
    end

    it "forwards the channel's declared capabilities (WS9, saída — additive)" do
      out = described_class.parse_request(
        { model: "insika:a", user: "c", input: "oi",
          channel: { capabilities: %w[image_output audio_output] } }, req
      )
      expect(out[:channel]).to eq(capabilities: %w[image_output audio_output])
    end

    it "channel absent -> no channel key (parity)" do
      out = described_class.parse_request({ model: "insika:a", user: "c", input: "oi" }, req)
      expect(out).not_to have_key(:channel)
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

    it "task_completed with usage -> response.completed carries usage (tokens) + model" do
      f = described_class.frame_for(ev(:task_completed, { usage: { input_tokens: 12, output_tokens: 8,
                                                                    total_tokens: 20, model: "deepseek-chat" } }))
      expect(f).to include('"usage"', '"input_tokens":12', '"output_tokens":8', '"total_tokens":20')
      expect(f).to include('"model":"deepseek-chat"')
      # model is a sibling of usage in the OpenAI shape, not INSIDE usage
      expect(f).not_to match(/"usage":\{[^}]*"model"/)
    end

    it "task_completed with outcome -> response.completed carries it (WS5 stuck, additive)" do
      f = described_class.frame_for(ev(:task_completed, { outcome: :stuck }))
      expect(f).to include('"outcome":"stuck"')
    end

    it "task_completed WITHOUT outcome -> no outcome sibling (parity)" do
      f = described_class.frame_for(ev(:task_completed, {}))
      expect(f).not_to include("outcome")
    end

    it "task_completed with output_parts -> response.completed carries them (WS9, saída)" do
      f = described_class.frame_for(ev(:task_completed,
        { output_parts: [{ "type" => "image", "mime_type" => "image/png",
                           "base64" => "QUJD", "model" => "gpt-image-1" }] }))
      expect(f).to include('"type":"response.completed"')
      expect(f).to include('"output_parts"', '"type":"image"', '"base64":"QUJD"')
    end

    it "task_completed WITHOUT output_parts -> no output_parts sibling (parity)" do
      f = described_class.frame_for(ev(:task_completed, {}))
      expect(f).not_to include("output_parts")
    end


    it ":task_failed -> response.failed + [DONE]" do
      f = described_class.frame_for(ev(:task_failed, { message: "boom" }))
      expect(f).to include('"type":"response.failed"')
      expect(f).to end_with("data: [DONE]\n\n")
    end

    it ":ttft -> insika.ttft carrying ttft_ms (live TTFB, WS6 — additive)" do
      f = described_class.frame_for(ev(:ttft, { ttft_ms: 712 }))
      expect(f).to include("event: insika.ttft")
      expect(f).to include('"type":"insika.ttft"')
      expect(f).to include('"ttft_ms":712')
    end

    it "events with no match -> nil (skipped)" do
      expect(described_class.frame_for(ev(:task_started))).to be_nil
      expect(described_class.frame_for(ev(:tool_result, { name: "x", result: "y" }))).to be_nil
      expect(described_class.frame_for(ev(:skill_activated, { name: "s" }))).to be_nil
    end

    it ":thinking -> nil: the provider's reasoning NEVER crosses the edge" do
      expect(described_class.frame_for(ev(:thinking, { delta: "deixa eu pensar" }))).to be_nil
    end

    # This consumer accumulates every delta into ONE WhatsApp message, so a
    # frame here is a message a customer reads. Model text that did not turn out to
    # be the answer — the narration before a tool call, the reasoning-in-prose a
    # model emits when it has no tool to call — must not produce one.
    it ":intermediate -> nil: only the answer crosses the edge" do
      monologue = "Let me look into this. However, I notice this is Joe's Pizzeria context…"
      expect(described_class.frame_for(ev(:intermediate, { delta: monologue }))).to be_nil
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
