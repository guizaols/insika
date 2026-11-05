# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/label_sessions"

RSpec.describe LabelSessions do
  let(:sessions) { Insika::SessionStore.new(store: Insika::Stores::Memory.new) }
  let(:map) { { "101" => { "customer_name" => "Ana", "customer_phone" => "5511999" }, "102" => { "customer_name" => "Bia" } } }

  it "labels only the agent's unnamed sessions, keeping names a live turn wrote" do
    sessions.create(id: "101", vars: { "agent" => "natura" })
    sessions.create(id: "t:102", vars: { "agent" => "natura", "customer_name" => "Bianca" })
    sessions.create(id: "103", vars: { "agent" => "natura" })
    sessions.create(id: "x:101", vars: { "agent" => "other" })

    expect(described_class.ids(sessions, "natura")).to contain_exactly("101", "103")
    expect(described_class.run(sessions, "natura", map, dry_run: true)).to eq(1)
    expect(sessions.find("101").vars["customer_name"]).to be_nil

    before = sessions.find("101").updated_at
    expect(described_class.run(sessions, "natura", map)).to eq(1)
    expect(sessions.find("101").updated_at).to eq(before)
    expect(sessions.find("101").vars).to include("customer_name" => "Ana", "customer_phone" => "5511999")
    expect(sessions.find("t:102").vars["customer_name"]).to eq("Bianca")
    expect(sessions.find("x:101").vars["customer_name"]).to be_nil

    expect(described_class.run(sessions, nil, map)).to eq(1)
    expect(sessions.find("x:101").vars["customer_name"]).to eq("Ana")
  end
end
