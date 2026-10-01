# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Insika::Wiring::Graph.trace_backend_for" do
  let(:graph) { Insika::Wiring::Graph }

  it "defers the trace scopes on SQLite, and writes in the turn when the flush is 0" do
    Dir.mktmpdir do |dir|
      sqlite = Insika::Stores::SQLite.new(path: File.join(dir, "t.db"))

      expect(graph.trace_backend_for(sqlite, {})).to be_a(Insika::Stores::WriteBehind)
      expect(graph.trace_backend_for(sqlite, { "INSIKA_TRACE_FLUSH_MS" => "0" })).to be(sqlite)
    ensure
      sqlite&.close
    end
  end

  it "uses Memory as is" do
    memory = Insika::Stores::Memory.new

    expect(graph.trace_backend_for(memory, {})).to be(memory)
  end
end
