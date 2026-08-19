# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TurnTiming do
  describe ".enabled?" do
    it "is off by default (absent / blank / falsey values)" do
      [nil, "", "  ", "0", "false", "no", "off"].each do |v|
        expect(described_class.enabled?({ "INSIKA_TURN_TIMING" => v })).to be(false)
      end
    end

    it "is on for the accepted truthy values (case/space-insensitive)" do
      %w[1 true yes on TRUE  Yes].each do |v|
        expect(described_class.enabled?({ "INSIKA_TURN_TIMING" => " #{v} " })).to be(true)
      end
    end

    it "still honors the deprecated HARNESS_TURN_TIMING alias" do
      expect(described_class.enabled?({ "HARNESS_TURN_TIMING" => "1" })).to be(true)
    end
  end

  describe "#to_h" do
    it "reports only the windows whose endpoints both fired" do
      t = described_class.new
      t.mark(:prep_start)
      t.mark(:ask)
      t.mark(:done)
      # no :first_token -> ttft/gen absent (workflow-turn shape)
      h = t.to_h
      expect(h.keys).to contain_exactly(:prep_ms, :total_ms)
      expect(h[:prep_ms]).to be_a(Numeric)
      expect(h[:total_ms]).to be >= h[:prep_ms]
    end

    it "first-write-wins: first_token records the FIRST chunk, not the last" do
      t = described_class.new
      t.mark(:ask)
      first = t.instance_variable_get(:@marks)[:ask]
      t.mark(:first_token)
      recorded = t.instance_variable_get(:@marks)[:first_token]
      t.mark(:first_token) # a later chunk must NOT move it
      expect(t.instance_variable_get(:@marks)[:first_token]).to eq(recorded)
      expect(recorded).to be >= first
    end

    # inbound -> first outbox flush. Present only when BOTH ends fired.
    it "reports first_balloon_ms once inbound and first_balloon both fired" do
      t = described_class.new
      t.mark(:inbound)
      sleep 0.001
      t.mark(:first_balloon)

      expect(t.to_h[:first_balloon_ms]).to be_a(Numeric)
      expect(t.to_h[:first_balloon_ms]).to be > 0
    end

    it "omits first_balloon_ms when either end is missing (a missing number is not a zero)" do
      only_inbound = described_class.new
      only_inbound.mark(:inbound)
      expect(only_inbound.to_h).not_to have_key(:first_balloon_ms)

      only_balloon = described_class.new
      only_balloon.mark(:first_balloon)
      expect(only_balloon.to_h).not_to have_key(:first_balloon_ms)
    end
  end

  describe "breakdown: false (the channel-balloon-only clock)" do
    # a channel turn allocates TurnTiming even when INSIKA_TURN_TIMING
    # is off, but then to_h may carry ONLY first_balloon_ms — the full breakdown
    # marks are the flag's job.
    it "records only inbound/first_balloon; the breakdown marks are no-ops" do
      t = described_class.new(breakdown: false)
      t.mark(:inbound)
      t.mark(:prep_start)
      t.mark(:ask)
      t.mark(:first_token)
      t.mark(:done)
      t.mark(:first_balloon)

      expect(t.to_h.keys).to contain_exactly(:first_balloon_ms)
      expect(t.to_h[:first_balloon_ms]).to be_a(Numeric)
    end

    it "omits first_balloon_ms when the balloon never fired" do
      t = described_class.new(breakdown: false)
      t.mark(:inbound)

      expect(t.to_h).to eq({})
    end
  end
end
