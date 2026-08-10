# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/insika/server/a2a/agent_card"

RSpec.describe Insika::Server::A2A::AgentCard do
  CardSkill = Struct.new(:name, :description)

  let(:agent) { Insika::AgentProfile.build(id: "assistant", model: "m", base_prompt: "Você é o assistente.") }

  it "builds the card with name/url/version/protocolVersion" do
    card = described_class.build(agent: agent, base_url: "https://h.example")
    expect(card[:name]).to eq("assistant")
    expect(card[:url]).to eq("https://h.example/a2a")
    expect(card[:description]).to eq("Você é o assistente.")
    expect(card[:version]).to eq("0.1.0")
    expect(card[:protocolVersion]).to be_a(String)
  end

  it "honest capabilities (streaming/push false) + text/plain modes" do
    card = described_class.build(agent: agent, base_url: "u")
    expect(card[:capabilities]).to eq({ streaming: false, pushNotifications: false, stateTransitionHistory: false })
    expect(card[:defaultInputModes]).to eq(["text/plain"])
    expect(card[:defaultOutputModes]).to eq(["text/plain"])
  end

  it "maps skills from the catalog" do
    card = described_class.build(agent: agent, base_url: "u",
                                 skills: [CardSkill.new("cardapio", "consulta o cardápio")])
    expect(card[:skills]).to eq([{ id: "cardapio", name: "cardapio", description: "consulta o cardápio", tags: [] }])
  end

  it "without skills -> []" do
    expect(described_class.build(agent: agent, base_url: "u")[:skills]).to eq([])
  end
end
