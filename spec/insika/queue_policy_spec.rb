# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::QueuePolicy do
  def profile(limits) = Insika::AgentProfile.build(id: "a", model: "m", limits: limits)
  def settings(queue) = Struct.new(:get).new({ "queue" => queue })

  describe "defaults" do
    it "a bare wiring is exactly today's behavior: followup, no window" do
      policy = described_class.resolve(profile({}))

      expect(policy.mode).to eq(:followup)
      expect(policy.debounce_ms).to eq(0)
      expect(policy.collect?).to be(false)
      expect(policy.debounce?).to be(false)
    end

    it "resolves with no profile and no settings at all" do
      expect(described_class.resolve(nil).mode).to eq(:followup)
    end
  end

  describe "resolution order (session vars > agent > platform > default)" do
    it "the platform default applies to an agent that declares nothing" do
      policy = described_class.resolve(profile({}),
                                       settings_store: settings({ "queue_mode" => "collect",
                                                                  "debounce_ms" => 2_000 }))

      expect(policy.mode).to eq(:collect)
      expect(policy.debounce_ms).to eq(2_000)
    end

    it "the agent overrides the platform" do
      policy = described_class.resolve(profile({ debounce_ms: 500 }),
                                       settings_store: settings({ "debounce_ms" => 2_000 }))

      expect(policy.debounce_ms).to eq(500)
    end

    it "session vars pin one conversation over both" do
      policy = described_class.resolve(profile({ queue_mode: "collect" }),
                                       settings_store: settings({ "queue_mode" => "collect" }),
                                       vars: { "queue_mode" => "followup" })

      expect(policy.mode).to eq(:followup)
    end
  end

  describe "a PRESENT key wins even carrying nil/0 (off, never inherit)" do
    it "an agent key present with nil disables a platform window" do
      policy = described_class.resolve(profile({ debounce_ms: nil }),
                                       settings_store: settings({ "debounce_ms" => 2_000 }))

      expect(policy.debounce_ms).to eq(0)
      expect(policy.debounce?).to be(false)
    end

    it "an agent key present with 0 does the same" do
      policy = described_class.resolve(profile({ debounce_ms: 0 }),
                                       settings_store: settings({ "debounce_ms" => 2_000 }))

      expect(policy.debounce_ms).to eq(0)
    end
  end

  describe "debounce_max_ms" do
    it "a non-positive ceiling falls back to the default — 'defer forever' is not a setting" do
      expect(described_class.resolve(profile({ debounce_max_ms: 0 })).debounce_max_ms)
        .to eq(described_class::DEFAULTS[:debounce_max_ms])
    end

    it "a positive ceiling is honored" do
      expect(described_class.resolve(profile({ debounce_max_ms: 3_000 })).debounce_max_ms).to eq(3_000)
    end
  end

  describe "mode validation" do
    it "accepts the implemented modes, as String or Symbol" do
      expect(described_class.resolve(profile({ queue_mode: "collect" })).mode).to eq(:collect)
      expect(described_class.resolve(profile({ queue_mode: :followup })).mode).to eq(:followup)
    end

    it "REFUSES a specified-but-unshipped mode instead of silently behaving as followup" do
      expect { described_class.resolve(profile({ queue_mode: "steer" })) }
        .to raise_error(Insika::ValidationError, /not implemented yet/)
    end

    it "refuses an unknown mode" do
      expect { described_class.resolve(profile({ queue_mode: "colect" })) }
        .to raise_error(Insika::ValidationError, /unknown queue_mode/)
    end

    it "a blank mode is an absent mode, not an error" do
      expect(described_class.resolve(profile({ queue_mode: "  " })).mode).to eq(:followup)
    end
  end

  describe "#collect?" do
    it "is true only for the collect mode" do
      expect(described_class.resolve(profile({ queue_mode: "collect" })).collect?).to be(true)
      expect(described_class.resolve(profile({ queue_mode: "followup" })).collect?).to be(false)
    end
  end
end
