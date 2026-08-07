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
    it "accepts all four modes, as String or Symbol" do
      expect(described_class.resolve(profile({ queue_mode: "collect" })).mode).to eq(:collect)
      expect(described_class.resolve(profile({ queue_mode: :followup })).mode).to eq(:followup)
      expect(described_class.resolve(profile({ queue_mode: "steer" })).mode).to eq(:steer)
      expect(described_class.resolve(profile({ queue_mode: :interrupt })).mode).to eq(:interrupt)
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

  describe "#interrupt? (RFC-0015 §6.4)" do
    it "is true only for the interrupt mode, and takes no knob of its own" do
      policy = described_class.resolve(profile({ queue_mode: "interrupt" }))

      expect(policy.interrupt?).to be(true)
      expect(policy.steer?).to be(false)
      expect(policy.collect?).to be(false)
      expect(described_class.resolve(profile({ queue_mode: "steer" })).interrupt?).to be(false)
    end
  end

  describe "steer (RFC-0015 §6.3)" do
    it "is off unless the mode asks for it, and carries the documented bound" do
      expect(described_class.resolve(profile({})).steer?).to be(false)
      policy = described_class.resolve(profile({ queue_mode: "steer" }))
      expect(policy.steer?).to be(true)
      expect(policy.steer_max_messages).to eq(5)
    end

    it "steer_max_messages of 0 is an agent saying no, not a bound of zero to trip later" do
      expect(described_class.resolve(profile({ queue_mode: "steer", steer_max_messages: 0 })).steer?)
        .to be(false)
    end

    it "the bound resolves through the platform layer like every other queue key" do
      policy = described_class.resolve(profile({ queue_mode: "steer" }),
                                       settings_store: settings({ "steer_max_messages" => 2 }))

      expect(policy.steer_max_messages).to eq(2)
    end

    it "#frame appends the raw text by default and the template when there is one" do
      expect(described_class.resolve(profile({ queue_mode: "steer" })).frame("1234")).to eq("1234")
      framed = described_class.resolve(profile({ queue_mode: "steer",
                                                 steer_join: "added: %{message}" }))
      expect(framed.frame("1234")).to eq("added: 1234")
    end

    it "REFUSES a steer_join that would drop the message" do
      expect { described_class.resolve(profile({ queue_mode: "steer", steer_join: "the customer spoke" })) }
        .to raise_error(Insika::ValidationError, /must contain/)
    end

    it "a platform template does not become 0 on the way through (text, not integer)" do
      policy = described_class.resolve(profile({ queue_mode: "steer" }),
                                       settings_store: settings({ "steer_join" => "add: %{message}" }))

      expect(policy.frame("x")).to eq("add: x")
    end
  end
end
