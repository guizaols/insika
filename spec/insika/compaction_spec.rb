# frozen_string_literal: true

require "spec_helper"

# RFC-0044 — the pure half of in-session compaction: boundary math (plan),
# the prompt (previous summary folded in), and the Summarizer over an
# injected ask (the Distiller shape — no provider involved here).
RSpec.describe Insika::Compaction do
  def msgs(n, role_cycle: %w[user assistant])
    n.times.map { |i| { "role" => role_cycle[i % role_cycle.size], "content" => "m#{i}" } }
  end

  describe ".plan" do
    let(:config) { { "keep_last" => 5, "compact_after" => 10 } }

    it "below the threshold -> nil (uncompacted count must EXCEED compact_after)" do
      expect(described_class.plan(messages: msgs(10), state: nil, config: config)).to be_nil
    end

    it "past the threshold -> compacts down to the last keep_last" do
      plan = described_class.plan(messages: msgs(11), state: nil, config: config)
      expect(plan.from).to eq(0)
      expect(plan.upto).to eq(6) # 11 - keep_last(5)
      expect(plan.count).to eq(6)
    end

    it "re-compaction starts from the persisted boundary and counts only the tail" do
      plan = described_class.plan(messages: msgs(30), state: { "upto" => 12 }, config: config)
      expect(plan.from).to eq(12)
      expect(plan.upto).to eq(25)
    end

    it "an already-compacted session below the threshold -> nil (the boundary is stable)" do
      expect(described_class.plan(messages: msgs(20), state: { "upto" => 12 }, config: config)).to be_nil
    end

    it "retreats over role:tool messages — an eviction unit is never split" do
      transcript = msgs(6) +
                   [{ "role" => "assistant", "content" => "", "tool_calls" => [{ "id" => "c1" }] },
                    { "role" => "tool", "content" => "r1" },
                    { "role" => "tool", "content" => "r2" }] +
                   msgs(4)
      # 13 messages, keep_last 5 -> raw upto = 8 (a role:tool) -> retreat to 6
      # (the tool-calling assistant), keeping the whole cycle verbatim.
      plan = described_class.plan(messages: transcript, state: nil,
                                  config: { "keep_last" => 5, "compact_after" => 10 })
      expect(plan.upto).to eq(6)
    end

    it "a retreat that lands back on the previous boundary -> nil (nothing to compact)" do
      transcript = [{ "role" => "assistant", "content" => "", "tool_calls" => [{ "id" => "c1" }] }] +
                   Array.new(11) { { "role" => "tool", "content" => "r" } }
      expect(described_class.plan(messages: transcript, state: nil,
                                  config: { "keep_last" => 2, "compact_after" => 4 })).to be_nil
    end

    it "compact_after is clamped to at least keep_last (the plan always moves forward)" do
      plan = described_class.plan(messages: msgs(21), state: nil,
                                  config: { "keep_last" => 20, "compact_after" => 3 })
      expect(plan.upto).to eq(1)
    end

    it "missing/invalid config falls back to the defaults (20/40)" do
      expect(described_class.plan(messages: msgs(40), state: nil, config: nil)).to be_nil
      plan = described_class.plan(messages: msgs(41), state: nil, config: {})
      expect(plan.upto).to eq(21) # 41 - DEFAULT_KEEP_LAST(20)
    end
  end

  describe ".prompt" do
    let(:messages) { msgs(6) }
    let(:plan) { described_class::Plan.new(from: 0, upto: 4, count: 4) }

    it "renders the rules, then ONLY the plan's slice with absolute indexes" do
      prompt = described_class.prompt(messages: messages, plan: plan)
      expect(prompt).to start_with(described_class::DEFAULT_PROMPT.rstrip)
      expect(prompt).to include("[0] user: m0", "[3] assistant: m3")
      expect(prompt).not_to include("m4", "m5") # the verbatim tail never rides
    end

    it "folds the previous summary in (a fact from turn 3 must survive re-compaction)" do
      prompt = described_class.prompt(messages: messages, plan: plan, previous: "CEP 30140-071 given")
      expect(prompt).to include("The summary so far", "CEP 30140-071 given")
    end

    it "a platform base prompt replaces the engine default wholesale" do
      prompt = described_class.prompt(messages: messages, plan: plan, base: "REGRAS DA LOJA")
      expect(prompt).to start_with("REGRAS DA LOJA")
      expect(prompt).not_to include("You are compacting")
    end

    it "a tool-calling assistant with no text renders its tool names; long content is capped" do
      transcript = [{ "role" => "assistant", "content" => "",
                      "tool_calls" => [{ "name" => "search" }, { "function" => { "name" => "calc" } }] },
                    { "role" => "tool", "content" => "x" * 5_000 }]
      slice = described_class.transcript(transcript, described_class::Plan.new(from: 0, upto: 2, count: 2))
      expect(slice).to include("(tool calls: search, calc)")
      expect(slice.length).to be < 5_000 + 200
    end
  end

  describe Insika::Compaction::Summarizer do
    it "returns the trimmed summary and the cost from a usage-bearing answer" do
      answer = Struct.new(:content, :input_tokens, :output_tokens, :cached_tokens)
                     .new("  resumo  ", 100, 20, 60)
      result = described_class.new(ask: ->(_p) { answer }).summarize(prompt: "p")
      expect(result[:summary]).to eq("resumo")
      expect(result[:cost]).to eq({ "spent" => 120, "cached" => 60 })
    end

    it "a plain-string answer works, with nil cost (never 0)" do
      result = described_class.new(ask: ->(_p) { "resumo" }).summarize(prompt: "p")
      expect(result).to eq({ summary: "resumo", cost: nil })
    end

    it "a blank answer raises Unusable — empty output must never move the boundary" do
      expect { described_class.new(ask: ->(_p) { "  \n" }).summarize(prompt: "p") }
        .to raise_error(described_class::Unusable)
    end

    it "truncates a summary past MAX_SUMMARY_CHARS (compaction never grows the context)" do
      result = described_class.new(ask: ->(_p) { "x" * 10_000 }).summarize(prompt: "p")
      expect(result[:summary].length).to eq(Insika::Compaction::MAX_SUMMARY_CHARS)
    end
  end

  describe Insika::Compaction::SummarizerFactory do
    it "compaction.model wins over the platform utility_model" do
      asked = nil
      factory = ->(model, provider) { asked = [model, provider]; ->(_p) { "s" } }
      s = described_class.build({ "model" => "deepseek/custom" },
                                utility_model: "flash", ask_factory: factory)
      expect(s.model).to eq("deepseek/custom")
      expect(asked).to eq(%w[custom deepseek])
    end

    it "falls back to the utility_model; a bare ref has no provider" do
      asked = nil
      factory = ->(model, provider) { asked = [model, provider]; ->(_p) { "s" } }
      s = described_class.build({}, utility_model: "flash", ask_factory: factory)
      expect(s.model).to eq("flash")
      expect(asked).to eq(["flash", nil])
    end

    it "no model anywhere -> nil (feature inert, never a guess)" do
      expect(described_class.build({}, utility_model: nil)).to be_nil
      expect(described_class.build(nil)).to be_nil
    end
  end
end
