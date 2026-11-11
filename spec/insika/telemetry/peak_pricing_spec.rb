# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/insika/telemetry/peak_pricing"

# A provider's peak hours as a multiplier over the catalog price. DeepSeek's are
# Monday to Friday, 09:00-12:00 and 14:00-18:00 in Beijing (01:00-04:00 and
# 06:00-10:00 UTC), Chinese public holidays excepted, at twice the off-peak rate.
RSpec.describe Insika::Telemetry::PeakPricing do
  # 2026-11-10 is a Tuesday.
  def at(hour, minute = 0, day: 10) = Time.utc(2026, 11, day, hour, minute)

  it "doubles DeepSeek inside both peak windows" do
    expect(described_class.multiplier("deepseek", at(1))).to eq(2)
    expect(described_class.multiplier("deepseek", at(3, 59))).to eq(2)
    expect(described_class.multiplier("deepseek", at(6))).to eq(2)
    expect(described_class.multiplier("deepseek", at(9, 59))).to eq(2)
  end

  it "leaves the catalog price outside them, the window end excluded" do
    [at(0, 59), at(4), at(5, 59), at(10), at(18)].each do |time|
      expect(described_class.multiplier("deepseek", time)).to eq(1)
    end
  end

  it "takes the weekday from the provider's calendar, not from the zone the Time carries" do
    sunday_night = Time.new(2026, 11, 15, 22, 30, 0, "-03:00") # Monday 09:30 in Beijing
    friday_night = Time.new(2026, 11, 13, 22, 30, 0, "-03:00") # Saturday 09:30 in Beijing
    expect(described_class.multiplier(:deepseek, sunday_night)).to eq(2)
    expect(described_class.multiplier(:deepseek, friday_night)).to eq(1)
  end

  it "is off-peak on a weekend" do
    expect(described_class.multiplier("deepseek", at(2, day: 14))).to eq(1) # Saturday
    expect(described_class.multiplier("deepseek", at(7, day: 15))).to eq(1) # Sunday
  end

  it "is off-peak on a Chinese public holiday that falls on a weekday" do
    expect(described_class.multiplier("deepseek", Time.utc(2026, 10, 1, 2))).to eq(1) # Thursday, National Day
    expect(described_class.multiplier("deepseek", Time.utc(2026, 10, 8, 2))).to eq(2) # the Thursday after
  end

  it "does not touch a provider that does not bill by the clock" do
    expect(described_class.multiplier("openai", at(2))).to eq(1)
    expect(described_class.multiplier(nil, at(2))).to eq(1)
  end

  describe ".apply" do
    it "prices a known cost at the rate in force" do
      expect(described_class.apply(0.25, provider: "deepseek", at: at(2))).to eq(0.5)
      expect(described_class.apply(0.25, provider: "deepseek", at: at(12))).to eq(0.25)
    end

    it "keeps an unknown cost unknown" do
      expect(described_class.apply(nil, provider: "deepseek", at: at(2))).to be_nil
    end
  end

  it "reports the last year each holiday list covers" do
    expect(described_class.holidays_through).to eq("deepseek" => 2027)
  end
end
