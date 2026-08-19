# frozen_string_literal: true

require "spec_helper"

# the five-field cron subset — the schedule trigger parser. The
# materialization (`next_after`) is asserted in UTC; the tz argument is the
# wall-clock the expression names.
RSpec.describe Insika::Cron do
  describe "parsing" do
    it "accepts a plain five-field expression" do
      expect(described_class.new("0 22 * * *")).to be_a(described_class)
    end

    it "refuses a wrong field count" do
      expect { described_class.new("0 22 * *") }
        .to raise_error(Insika::ValidationError, /5 fields/)
    end

    it "refuses a value out of range" do
      expect { described_class.new("60 22 * * *") }
        .to raise_error(Insika::ValidationError, /minute value 60/)
      expect { described_class.new("0 24 * * *") }
        .to raise_error(Insika::ValidationError, /hour value 24/)
      expect { described_class.new("0 0 0 * *") }
        .to raise_error(Insika::ValidationError, /dom value 0/)
      expect { described_class.new("0 0 * 13 *") }
        .to raise_error(Insika::ValidationError, /month value 13/)
    end

    it "refuses a zero or non-integer step" do
      expect { described_class.new("*/0 * * * *") }
        .to raise_error(Insika::ValidationError, /step/)
      expect { described_class.new("*/x * * * *") }
        .to raise_error(Insika::ValidationError, /step|cron/)
    end

    it "refuses the unsupported L/W/# spellings loudly" do
      expect { described_class.new("0 0 L * *") }
        .to raise_error(Insika::ValidationError)
      expect { described_class.new("0 0 1W * *") }
        .to raise_error(Insika::ValidationError)
    end

    it "accepts a reversed-range list per field" do
      expect(described_class.new("1,2,3 9-17 * * 1-5,6")).to be_a(described_class)
    end
  end

  describe "#next_after" do
    it "returns the same-day occurrence, strictly after the instant" do
      c = described_class.new("30 14 * * *")
      # at the exact minute, the fire is already in progress -> the next day
      expect(c.next_after(Time.iso8601("2026-08-19T14:30:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-20T14:30:00Z"))
      # half a minute after 14:29 -> today 14:30
      expect(c.next_after(Time.iso8601("2026-08-19T14:29:30Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-19T14:30:00Z"))
    end

    it "supports steps and lists" do
      c = described_class.new("*/15 9-17 * * *")
      expect(c.next_after(Time.iso8601("2026-08-19T09:07:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-19T09:15:00Z"))
    end

    it "materializes in the schedule's timezone" do
      c = described_class.new("0 22 * * *")
      # Sao_Paulo is UTC-3, no DST: 22:00 local = 01:00Z the next day
      expect(c.next_after(Time.iso8601("2026-08-19T21:00:00Z"), tz: "America/Sao_Paulo").utc)
        .to eq(Time.iso8601("2026-08-20T01:00:00Z"))
    end

    it "E4 — crosses a DST transition correctly (America/New_York)" do
      # 2026-03-08 02:00-03:00 does not exist (spring forward); the day's
      # OTHER fires keep their wall-clock in the new offset.
      daily = described_class.new("0 12 * * *")
      before = daily.next_after(Time.iso8601("2026-03-07T11:59:00Z"), tz: "America/New_York")
      during = daily.next_after(Time.iso8601("2026-03-08T11:59:00Z"), tz: "America/New_York")
      expect(before.utc).to eq(Time.iso8601("2026-03-07T17:00:00Z")) # EST = UTC-5
      expect(during.utc).to eq(Time.iso8601("2026-03-08T16:00:00Z")) # EDT = UTC-4

      # a wall-clock that does not exist that day (02:30) is skipped, not invented
      gap = described_class.new("30 2 * * *")
      expect(gap.next_after(Time.iso8601("2026-03-07T00:00:00Z"), tz: "America/New_York"))
        .to eq(gap.next_after(Time.iso8601("2026-03-07T03:00:00Z"), tz: "America/New_York"))
    end

    it "supports the day-of-week OR day-of-month rule" do
      # both restricted: a date matches on EITHER (standard cron).
      c = described_class.new("0 9 13 * 5")
      expect(c.next_after(Time.iso8601("2026-08-19T00:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-21T09:00:00Z")) # Friday 21st
      # a 13th on a NON-Friday still fires (the OR): 2026-09-13 is a Monday,
      # asked from after the last Friday before it.
      expect(c.next_after(Time.iso8601("2026-09-11T10:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-09-13T09:00:00Z"))
    end

    it "treats dow 7 as Sunday" do
      c7 = described_class.new("0 0 * * 7")
      expect(c7.next_after(Time.iso8601("2026-08-19T00:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-23T00:00:00Z"))
    end

    it "jumps to the next month and year" do
      c = described_class.new("0 0 1 * *")
      expect(c.next_after(Time.iso8601("2026-08-31T12:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-09-01T00:00:00Z"))
      c = described_class.new("0 0 1 1 *")
      expect(c.next_after(Time.iso8601("2026-12-31T12:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2027-01-01T00:00:00Z"))
    end

    it "handles leap years and returns nil for an impossible date" do
      leap = described_class.new("0 0 29 2 *")
      expect(leap.next_after(Time.iso8601("2026-08-19T00:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2028-02-29T00:00:00Z"))
      impossible = described_class.new("0 0 31 2 *")
      expect(impossible.next_after(Time.iso8601("2026-08-19T00:00:00Z"), tz: "UTC")).to be_nil
    end

    it "is strictly after — a fire AT the instant is already passed" do
      c = described_class.new("0 0 * * *")
      expect(c.next_after(Time.iso8601("2026-08-19T00:00:00Z"), tz: "UTC").utc)
        .to eq(Time.iso8601("2026-08-20T00:00:00Z"))
    end
  end
end