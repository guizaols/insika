# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/protocol"

RSpec.describe Harness::Server::A2A::Protocol do
  E = Harness::Server::A2A::Errors

  describe ".parse" do
    it "valid -> [:ok, {id, method, params}]" do
      body = { "jsonrpc" => "2.0", "id" => "1", "method" => "message/send", "params" => { "x" => 1 } }
      expect(described_class.parse(body)).to eq([:ok, { id: "1", method: "message/send", params: { "x" => 1 } }])
    end

    it "params missing -> {}" do
      _, r = described_class.parse({ "jsonrpc" => "2.0", "id" => "1", "method" => "tasks/get" })
      expect(r[:params]).to eq({})
    end

    it "non-Hash -> INVALID_REQUEST" do
      k, r = described_class.parse("nope")
      expect([k, r[:code]]).to eq([:error, E::INVALID_REQUEST])
    end

    it "jsonrpc errado -> INVALID_REQUEST (preserva id)" do
      k, r = described_class.parse({ "jsonrpc" => "1.0", "id" => "9", "method" => "m" })
      expect([k, r[:code], r[:id]]).to eq([:error, E::INVALID_REQUEST, "9"])
    end

    it "method missing/empty -> INVALID_REQUEST" do
      expect(described_class.parse({ "jsonrpc" => "2.0", "id" => "1" }).first).to eq(:error)
      expect(described_class.parse({ "jsonrpc" => "2.0", "id" => "1", "method" => "" }).first).to eq(:error)
    end

    it "batch (Array) not supported -> INVALID_REQUEST" do
      expect(described_class.parse([{ "jsonrpc" => "2.0" }]).first).to eq(:error)
    end
  end

  describe ".result / .error" do
    it "result envelope" do
      expect(described_class.result("1", { a: 1 })).to eq({ jsonrpc: "2.0", id: "1", result: { a: 1 } })
    end

    it "error envelope (sem data)" do
      expect(described_class.error("1", -32_601, "x")).to eq({ jsonrpc: "2.0", id: "1", error: { code: -32_601, message: "x" } })
    end

    it "error com data" do
      expect(described_class.error(nil, -1, "x", data: { k: 1 })[:error][:data]).to eq({ k: 1 })
    end
  end
end
