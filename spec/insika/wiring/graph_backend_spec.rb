# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Wiring::Graph do
  it "turns the slow-call log on only when INSIKA_SLOW_STORE_MS is set" do
    Dir.mktmpdir do |dir|
      db = File.join(dir, "g.db")
      on = described_class.backend_from_env("INSIKA_DB" => db, "INSIKA_SLOW_STORE_MS" => "50")
      off = described_class.backend_from_env("INSIKA_DB" => db)

      expect([on, off].map { |s| s.singleton_class.include?(Insika::Stores::SQLite::SlowLog) }).to eq([true, false])
    ensure
      [on, off].compact.each(&:close)
    end
  end
  it "puts the traces on their own file only when INSIKA_TRACE_DB is set" do
    Dir.mktmpdir do |dir|
      main = Insika::Stores::Memory.new
      traces = described_class.trace_backend_from_env(fallback: main, env: { "INSIKA_TRACE_DB" => File.join(dir, "t.db") })
      spine = described_class.spine(backend: main, trace_backend: traces)
      Insika::ContextTraceStore.new(store: spine.trace_backend).record(session_id: "s1", entry: { "turn" => 1 })

      expect([described_class.trace_backend_from_env(fallback: main, env: {}), traces.class,
              traces.list("context_traces").size, main.list("context_traces"), spine.llm_trace_store.class])
        .to eq([main, Insika::Stores::SQLite, 1, [], Insika::LLMTraceStore])
    ensure
      traces.close if traces.respond_to?(:close)
    end
  end
end
