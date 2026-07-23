# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TurnTiming do
  describe ".enabled?" do
    it "is off by default (absent / blank / falsey values)" do
      [nil, "", "  ", "0", "false", "no", "off"].each do |v|
        expect(described_class.enabled?({ "HARNESS_TURN_TIMING" => v })).to be(false)
      end
    end

    it "is on for the accepted truthy values (case/space-insensitive)" do
      %w[1 true yes on TRUE  Yes].each do |v|
        expect(described_class.enabled?({ "HARNESS_TURN_TIMING" => " #{v} " })).to be(true)
      end
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
  end
end
