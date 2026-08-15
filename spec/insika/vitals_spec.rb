# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Vitals do
  describe ".snapshot" do
    it "carries every documented key" do
      body = described_class.snapshot
      expect(body).to include(
        "boot_id", "pid", "started_at", "uptime_s", "version", "ruby", "yjit",
        "rss_bytes", "gc", "threads", "in_flight", "db_bytes", "at"
      )
      expect(body.keys).to all(be_a(String))
    end

    it "returns a valid body with no executor/db_path" do
      body = described_class.snapshot
      expect(body["in_flight"]).to be_nil
      expect(body["db_bytes"]).to be_nil
    end

    it "reads in_flight from the executor and db bytes from the path" do
      executor = Class.new { def in_flight = %w[a b] }.new
      Dir.mktmpdir do |dir|
        db = File.join(dir, "test.db")
        File.write(db, "x" * 100)
        File.write("#{db}-wal", "y" * 50)

        body = described_class.snapshot(executor: executor, db_path: db)
        expect(body["in_flight"]).to eq(2)
        expect(body["db_bytes"]).to eq("db" => 100, "wal" => 50, "shm" => 0)
      end
    end

    it "has a monotonic uptime_s across calls a second apart" do
      a = described_class.snapshot["uptime_s"]
      sleep 1.1
      b = described_class.snapshot["uptime_s"]
      expect(b).to be > a
    end
  end

  describe ".rss_bytes" do
    it "is a positive integer on this platform, or nil — never 0" do
      rss = described_class.rss_bytes
      expect(rss).to be_nil.or(be > 0)
    end
  end

  describe ".gc_stat" do
    it "carries exactly GC_KEYS with string keys" do
      stat = described_class.gc_stat
      expect(stat.keys.sort).to eq(described_class::GC_KEYS.map(&:to_s).sort)
      expect(stat.values).to all(be_a(Integer))
    end
  end

  describe ".db_bytes" do
    it "returns nil for a missing file" do
      expect(described_class.db_bytes("/nonexistent/x.db")).to be_nil
    end

    it "returns nil for a nil path" do
      expect(described_class.db_bytes(nil)).to be_nil
    end
  end
end
