# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Insika::Wiring::Graph.backend_from_env" do
  let(:graph) { Insika::Wiring::Graph }

  it "is Memory with nothing set, SQLite with INSIKA_DB" do
    expect(graph.backend_from_env({})).to be_a(Insika::Stores::Memory)
    Dir.mktmpdir do |dir|
      sqlite = graph.backend_from_env({ "INSIKA_DB" => File.join(dir, "x.db") })
      expect(sqlite).to be_a(Insika::Stores::SQLite)
      sqlite.close
    end
  end

  it "is Postgres with INSIKA_DATABASE_URL, which wins over INSIKA_DB", if: ENV["PG_TEST_URL"] do
    pg = graph.backend_from_env({ "INSIKA_DATABASE_URL" => ENV["PG_TEST_URL"], "INSIKA_DB" => "/nope.db" })
    expect(pg).to be_a(Insika::Stores::Postgres)
    expect(Insika::Stores.durable?(pg)).to be(true)
    pg.close
  end

  it "only Memory is ephemeral" do
    expect(Insika::Stores.durable?(Insika::Stores::Memory.new)).to be(false)
    Dir.mktmpdir do |dir|
      sqlite = Insika::Stores::SQLite.new(path: File.join(dir, "x.db"))
      expect(Insika::Stores.durable?(sqlite)).to be(true)
      sqlite.close
    end
  end
end
