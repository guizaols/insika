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
end
