# frozen_string_literal: true

RSpec.describe Insika::AgentProfile do
  describe "compatibility with" do
    it "accepts the minimal signature" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.id).to eq("a")
      expect(profile.model).to eq("m")
      expect(profile.provider).to be_nil
      expect(profile.base_prompt).to eq("")
      expect(profile.prompt_files).to eq([])
      expect(profile.tools_allow).to be_nil
      expect(profile.tools_deny).to eq([])
      expect(profile.skills).to be_nil
    end

    describe "#tool_opted_in? (preserved)" do
      it "true when the name is in allow" do
        profile = described_class.build(id: "a", model: "m", tools_allow: ["a"])
        expect(profile.tool_opted_in?("a")).to be(true)
        expect(profile.tool_opted_in?("b")).to be(false)
      end

      it "false with tools_allow nil" do
        profile = described_class.build(id: "a", model: "m")
        expect(profile.tool_opted_in?("a")).to be(false)
      end
    end
  end

  describe "new fields" do
    let(:profile) { described_class.build(id: "a", model: "m") }

    it "has correct defaults" do
      expect(profile.context_providers).to be_nil
      expect(profile.workflows_allow).to be_nil
      expect(profile.policies).to eq([])
      expect(profile.prompt_refs).to eq([])
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS)
      expect(profile.prompt_caching).to be_nil # R3: opt-in, off by default
      expect(profile.tool_output_compression).to be_nil # A3/C3: opt-in, off by default
      expect(profile.budget).to be_nil # WS2: no budget (parity)
    end

    it "budget is normalized to string keys (the data shape the edge reads)" do
      profile = described_class.build(id: "a", model: "m",
                                      budget: { daily: 100_000, monthly: 2_000_000,
                                                soft: true, alert_at: 0.8 })
      expect(profile.budget).to eq("daily" => 100_000, "monthly" => 2_000_000,
                                   "soft" => true, "alert_at" => 0.8)
    end

    it "tool_output_compression round-trips on/off" do
      off = described_class.build(id: "a", model: "m")
      on = described_class.build(id: "a", model: "m", tool_output_compression: true)

      expect(off.tool_output_compression).to be_nil # absent -> off (parity)
      expect(on.tool_output_compression).to be(true)
    end

    it "DEFAULT_LIMITS matches (+ approval_timeout from, tool_concurrency from)" do
      expect(described_class::DEFAULT_LIMITS).to eq(
        turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
        context_budget: 8_000, max_tool_calls: 50, max_tool_repeat: 3,
        approval_timeout: 3_600, tool_concurrency: 1
      )
    end

    it "limits does a partial merge, not a replacement" do
      # value distinct from any default so the override doesn't coincide with
      # a preserved key (tool_timeout is also 60 by default).
      profile = described_class.build(id: "a", model: "m", limits: { turn_timeout: 999 })
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS.merge(turn_timeout: 999))
    end
  end

  describe "Array() normalization" do
    it "accepts a single value in tools_deny, policies and prompt_refs" do
      profile = described_class.build(
        id: "a", model: "m", tools_deny: "x", policies: "p", prompt_refs: "r"
      )
      expect(profile.tools_deny).to eq(["x"])
      expect(profile.policies).to eq(["p"])
      expect(profile.prompt_refs).to eq(["r"])
    end
  end

  describe "capabilities — opt-in asymmetry" do
    it "default nil = NO capability (not 'all', unlike tools_allow)" do
      expect(described_class.build(id: "a", model: "m").capabilities).to be_nil
    end

    it "accepts the explicit list of intents" do
      profile = described_class.build(id: "a", model: "m", capabilities: [:browse, :search])
      expect(profile.capabilities).to eq([:browse, :search])
    end

    it " profile (without the kwarg) is still buildable" do
      expect { described_class.build(id: "a", model: "m") }.not_to raise_error
    end
  end

  describe "tools_deferred (Tool Search)" do
    it "default nil = no deferred (all eager — parity)" do
      expect(described_class.build(id: "a", model: "m").tools_deferred).to be_nil
    end

    it "accepts the allowlist of searchable-not-wired tools" do
      profile = described_class.build(id: "a", model: "m", tools_deferred: %w[send_email create_invoice])
      expect(profile.tools_deferred).to eq(%w[send_email create_invoice])
    end
  end

  describe "memory (cross-session memory) — opt-in" do
    it "default nil = OFF (parity)" do
      expect(described_class.build(id: "a", model: "m").memory).to be_nil
    end

    it "accepts memory: true (on)" do
      expect(described_class.build(id: "a", model: "m", memory: true).memory).to be(true)
    end
  end

  describe "subagents (capacity field — never inherits)" do
    it "defaults to nil (opt-in: NONE, like capabilities)" do
      expect(described_class.build(id: "a", model: "m").subagents).to be_nil
    end

    it "normalizes a present value to [String] (accepts symbols)" do
      profile = described_class.build(id: "a", model: "m", subagents: [:researcher, "writer"])
      expect(profile.subagents).to eq(%w[researcher writer])
    end

    it "an explicit empty list stays [] (present but no children)" do
      expect(described_class.build(id: "a", model: "m", subagents: []).subagents).to eq([])
    end

    it "round-trips through to_h (persistence)" do
      profile = described_class.build(id: "a", model: "m", subagents: ["researcher"])
      expect(profile.to_h[:subagents]).to eq(["researcher"])
    end
  end

  describe "metadata + store_id (turn context)" do
    it "default = {} (agent without metadata)" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end

    it "store_id reads from metadata (symbol key)" do
      profile = described_class.build(id: "a", model: "m", metadata: { store_id: "loja-7" })
      expect(profile.store_id).to eq("loja-7")
    end

    it "store_id tolerates string key (store JSON round-trip)" do
      profile = described_class.build(id: "a", model: "m", metadata: { "store_id" => "loja-9" })
      expect(profile.store_id).to eq("loja-9")
    end

    it "metadata: nil becomes {} (doesn't break store_id)" do
      profile = described_class.build(id: "a", model: "m", metadata: nil)
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end
  end
end
