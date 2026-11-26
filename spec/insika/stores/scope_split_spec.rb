# frozen_string_literal: true

require "tmpdir"
require_relative "../../../lib/insika/testing/store_contract"

RSpec.describe Insika::Stores::ScopeSplit do
  let(:main) { Insika::Stores::Memory.new }
  let(:side) { Insika::Stores::Memory.new }

  subject(:store) { described_class.new(main: main, side: side) }

  it_behaves_like "an Insika store"

  it "keeps config:* scopes in the side backend and the rest in main" do
    store.set("config:skills", "a", { "x" => 1 })
    store.set("sessions", "s1", { "y" => 2 })

    expect(side.get("config:skills", "a")).to eq("x" => 1)
    expect(main.get("config:skills", "a")).to be_nil
    expect(main.get("sessions", "s1")).to eq("y" => 2)
    expect(store.scopes).to eq(%w[config:skills sessions])
  end

  it "lists config scopes without reading main (a cold boot must not scan the big file)" do
    store.set("config:tools", "t", {})
    expect(main).not_to receive(:scopes)
    expect(store.scopes("config:")).to eq(["config:tools"])
  end

  describe "#adopt!" do
    it "copies the config rows of main into an empty side, once" do
      main.set("config:agents", "shop", { "name" => "Shop" })
      main.set("sessions", "s1", {})

      expect(store.adopt!).to eq(1)
      expect(store.get("config:agents", "shop")).to eq("name" => "Shop")
      expect(side.scopes).to eq(["config:agents"])

      store.set("config:agents", "shop", { "name" => "Edited" })
      expect(store.adopt!).to eq(0)
      expect(store.get("config:agents", "shop")).to eq("name" => "Edited")
    end
  end

  it "is what the env builds when INSIKA_CONFIG_DB is set" do
    Dir.mktmpdir do |dir|
      env = { "INSIKA_DB" => File.join(dir, "main.db"), "INSIKA_CONFIG_DB" => File.join(dir, "config.db") }
      backend = Insika::Wiring::Graph.raw_backend_from_env(env)
      backend.set("config:settings", "k", { "v" => 1 })
      backend.close

      expect(Insika::Stores::SQLite.new(path: env["INSIKA_CONFIG_DB"]).get("config:settings", "k")).to eq("v" => 1)
      expect(Insika::Stores::SQLite.new(path: env["INSIKA_DB"]).get("config:settings", "k")).to be_nil
    end
  end
end
