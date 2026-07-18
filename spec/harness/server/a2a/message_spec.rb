# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/message"

RSpec.describe Harness::Server::A2A::Message do
  describe ".text_from" do
    it "concatena TextParts (kind)" do
      msg = { "parts" => [{ "kind" => "text", "text" => "oi " }, { "kind" => "text", "text" => "mundo" }] }
      expect(described_class.text_from(msg)).to eq("oi mundo")
    end

    it "tolera a chave 'type' (spec antigo)" do
      expect(described_class.text_from({ "parts" => [{ "type" => "text", "text" => "x" }] })).to eq("x")
    end

    it "ignores non-text parts (only TextPart in this slice)" do
      msg = { "parts" => [{ "kind" => "file", "file" => {} }, { "kind" => "text", "text" => "t" }] }
      expect(described_class.text_from(msg)).to eq("t")
    end

    it "no parts / non-Hash -> ''" do
      expect(described_class.text_from({})).to eq("")
      expect(described_class.text_from(nil)).to eq("")
    end
  end

  describe ".agent_message" do
    it "role agent + 1 TextPart" do
      expect(described_class.agent_message("oi")).to eq({ role: "agent", parts: [{ kind: "text", text: "oi" }] })
    end
  end
end
