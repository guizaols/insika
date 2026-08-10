# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/insika/server/a2a/http"

RSpec.describe Insika::Server::A2A::Http do
  # internet fake: grava (url, headers, body) e devolve uma resposta com #read.
  FakeResponse = Struct.new(:body) { def read = body }

  class FakeInternet
    attr_reader :calls

    def initialize(response_json) = (@response = response_json; @calls = [])
    def post(url, headers, body) = (@calls << [url, headers, body]; FakeResponse.new(@response))
    def close = nil
  end

  it "post_json serializa o body e parseia a resposta (chaves string)" do
    internet = FakeInternet.new('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}')
    http = described_class.new(internet: internet)

    result = http.post_json("http://r/a2a", { "jsonrpc" => "2.0", "id" => 1, "method" => "tasks/get" })

    url, _headers, body = internet.calls.first
    expect(url).to eq("http://r/a2a")
    expect(JSON.parse(body)).to include("method" => "tasks/get")
    expect(result).to eq({ "jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true } })
  end

  it "close is best-effort (does not raise)" do
    expect { described_class.new(internet: FakeInternet.new("{}")).close }.not_to raise_error
  end
end
