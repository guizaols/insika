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
    it "exposes only inbound/first_balloon; the breakdown windows stay out of #to_h" do
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

  describe "#metrics (the turn row, whatever the flag)" do
    it "keeps every window, the queue wait and the tool calls even with breakdown: false" do
      t = described_class.new(breakdown: false)
      %i[inbound prep_start ask first_token done first_balloon].each { t.mark(_1) }
      t.tool("search", true, 12)
      t.tool("cart", false, 30)

      m = t.metrics
      expect(m.keys).to include("ttft_ms", "total_ms", "first_balloon_ms", "queue_ms", "prep_ms", "gen_ms")
      expect(m).to include("tools_ms" => 42, "tools" => [["search", true, 12], ["cart", false, 30]])
      expect(t.to_h.keys).to eq([:first_balloon_ms])
    end

    it "omits windows and tools that never happened" do
      expect(described_class.new.metrics).to eq({})
    end
  end

  describe "store call counting" do
    it "groups config scopes by their second segment and the rest by the first" do
      expect(described_class.scope_group("config:agent_files")).to eq("config:agent_files")
      expect(described_class.scope_group("sessions")).to eq("sessions")
      expect(described_class.scope_group("knowledge:agent-1:t")).to eq("knowledge")
    end

    it "adds the total and the per-call breakdown to #to_h, busiest first" do
      t = described_class.new
      t.count_store(:get, "config:agents")
      t.count_store(:get, "config:agents")
      t.count_store(:set, "sessions")

      expect(t.to_h).to include(store_calls: 3,
                                store_calls_by: { "get config:agents" => 2, "set sessions" => 1 })
      expect(t.to_h[:store_calls_by].keys.first).to eq("get config:agents")
    end

    it "omits the store keys when nothing was counted (absent, never zero)" do
      expect(described_class.new.to_h).not_to have_key(:store_calls)
    end

    # The counts are opt-in diagnostics: a channel clock with INSIKA_TURN_TIMING
    # off must not grow the task record or the completion event.
    it "does not count on a channel clock (breakdown: false)" do
      t = described_class.new(breakdown: false)
      t.count_store(:get, "sessions")
      expect(t.to_h).not_to have_key(:store_calls)
    end
  end
end
