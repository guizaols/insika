# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/client"

RSpec.describe Harness::Server::A2A::Client do
  # http fake: uma fila de respostas (envelopes JSON-RPC), grava os requests.
  class FakeHttp
    attr_reader :requests

    def initialize(responses) = (@responses = responses.dup; @requests = [])
    def post_json(url, body) = (@requests << [url, body]; @responses.shift)
  end

  def envelope_task(state, text: nil, id: "rt1")
    status = { "state" => state }
    status["message"] = { "role" => "agent", "parts" => [{ "kind" => "text", "text" => text }] } if text
    { "jsonrpc" => "2.0", "id" => 1, "result" => { "id" => id, "kind" => "task", "status" => status } }
  end

  let(:no_sleep) { ->(_s) {} }

  describe "#send_message" do
    it "monta o envelope message/send (role user, TextPart, contextId) e devolve a Task" do
      http = FakeHttp.new([envelope_task("submitted")])
      client = described_class.new(http: http, sleeper: no_sleep)
      task = client.send_message("http://r/a2a", "oi", context_id: "ctx1")

      _url, req = http.requests.first
      expect(req["method"]).to eq("message/send")
      expect(req.dig("params", "message", "parts")).to eq([{ "kind" => "text", "text" => "oi" }])
      expect(req.dig("params", "message", "contextId")).to eq("ctx1")
      expect(task["id"]).to eq("rt1")
    end

    it "envelope error -> RemoteError" do
      http = FakeHttp.new([{ "jsonrpc" => "2.0", "id" => 1, "error" => { "code" => -32_001, "message" => "sem task" } }])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect { client.send_message("u", "x") }.to raise_error(Harness::Server::A2A::RemoteError, /sem task/)
    end
  end

  describe "#call (send + poll)" do
    it "poll até completed -> { text: }" do
      # send -> submitted; get_task #1 -> working; get_task #2 -> completed(42)
      http = FakeHttp.new([envelope_task("submitted"), envelope_task("working"), envelope_task("completed", text: "42")])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "quanto?")).to eq({ text: "42", state: "completed", id: "rt1" })
    end

    it "SEMPRE faz >=1 get_task (message/send sem content) -> pega o texto no get_task" do
      # send devolve completed SEM message (como o inbound message_send); o
      # get_task traz o content.
      http = FakeHttp.new([envelope_task("completed"), envelope_task("completed", text: "42")])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "x")).to eq({ text: "42", state: "completed", id: "rt1" })
      expect(http.requests.map { |_u, r| r["method"] }).to eq(%w[message/send tasks/get])
    end

    it "remoto failed -> { error: } (texto do erro, senão o estado)" do
      http = FakeHttp.new([envelope_task("failed", text: "deu ruim"), envelope_task("failed", text: "deu ruim")])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "x")).to eq({ error: "deu ruim", state: "failed", id: "rt1" })
    end

    it "failed sem message -> error = estado (evita o footgun de '' truthy)" do
      http = FakeHttp.new([envelope_task("failed"), envelope_task("failed")])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "x")[:error]).to eq("failed")
    end

    it "input-required -> { text: } (o modelo decide)" do
      http = FakeHttp.new([envelope_task("input-required", text: "qual ano?"), envelope_task("input-required", text: "qual ano?")])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "x")).to include(text: "qual ano?", state: "input-required")
    end

    it "envelope error durante o fluxo -> { error: } (call nunca levanta)" do
      http = FakeHttp.new([{ "jsonrpc" => "2.0", "error" => { "code" => -1, "message" => "recusado" } }])
      client = described_class.new(http: http, sleeper: no_sleep)
      expect(client.call("u", "x")).to eq({ error: "recusado", state: "failed", id: nil })
    end

    it "poll estoura (poll_max) -> { error: }" do
      responses = [envelope_task("submitted")] + Array.new(5) { envelope_task("working") }
      client = described_class.new(http: FakeHttp.new(responses), sleeper: no_sleep, poll_max: 2)
      expect(client.call("u", "x")[:error]).to match(/não concluiu/)
    end
  end
end
