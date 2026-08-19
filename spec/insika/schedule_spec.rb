# frozen_string_literal: true

require "spec_helper"

# the schedule declaration parser — the ONLY shape the engine
# accepts (engine/doctor/Studio share it), the FollowupPolicy precedent.
RSpec.describe Insika::Schedule do
  def valid(**over)
    { "id" => "daily_report", "cron" => "0 22 * * *", "tz" => "America/Sao_Paulo",
      "message" => "Run the daily report now." }.merge(over)
  end

  describe "parse" do
    it "accepts a cron declaration with defaults" do
      s = described_class.parse!(valid)
      expect(s.id).to eq("daily_report")
      expect(s.cron).to eq("0 22 * * *")
      expect(s.tz).to eq("America/Sao_Paulo")
      expect(s.every).to be_nil
      expect(s.session_mode).to eq("new")
      expect(s.overrides).to be_nil
      expect(s.enabled).to be(true)
    end

    it "accepts every-interval, presence means cron?/every? split" do
      s = described_class.parse!(valid("cron" => nil, "every" => 86_400))
      expect(s.every).to eq(86_400)
      expect(s.every?).to be(true)
      expect(s.cron?).to be(false)
    end

    it "parses the fixed-session mode, overrides and disabled" do
      s = described_class.parse!(valid("session_mode" => "fixed", "session_id" => "standing",
                                       "overrides" => { "turn_timeout" => 900, "max_tool_calls" => 200,
                                                        "model" => "deepseek-v4-flash" },
                                       "enabled" => false))
      expect(s.fixed_session?).to be(true)
      expect(s.overrides).to eq("turn_timeout" => 900, "max_tool_calls" => 200,
                                "model" => "deepseek-v4-flash")
      expect(s.enabled).to be(false)
    end

    it "normalizes symbol keys" do
      s = described_class.parse!(id: "x", cron: "0 0 * * *", message: "m")
      expect(s.id).to eq("x")
    end

    it "defaults the timezone to Etc/UTC" do
      s = described_class.parse!(valid("tz" => nil))
      expect(s.tz).to eq("Etc/UTC")
    end
  end

  describe "parse (nil on malformed)" do
    it "requires the id" do
      expect(described_class.parse(valid("id" => ""))).to be_nil
      expect(described_class.parse(valid("id" => "Daily Report!"))).to be_nil
    end

    it "requires exactly ONE trigger" do
      expect(described_class.parse(valid("cron" => nil, "message" => "x"))).to be_nil
      expect(described_class.parse(valid("every" => 60))).to be_nil
    end

    it "rejects a malformed cron expression" do
      expect(described_class.parse(valid("cron" => "0 22 * *"))).to be_nil
      expect(described_class.parse(valid("cron" => "60 22 * * *"))).to be_nil
    end

    it "rejects an invalid every" do
      expect(described_class.parse(valid("cron" => nil, "every" => 0))).to be_nil
      expect(described_class.parse(valid("cron" => nil, "every" => "fast"))).to be_nil
    end

    it "rejects an unknown timezone and a malformed message" do
      expect(described_class.parse(valid("tz" => "Mars/Olympus"))).to be_nil
      expect(described_class.parse(valid("message" => ""))).to be_nil
    end

    it "rejects a bad session_mode and unknown override keys" do
      expect(described_class.parse(valid("session_mode" => "once"))).to be_nil
      expect(described_class.parse(valid("overrides" => { "hallucinate" => 9 }))).to be_nil
      expect(described_class.parse(valid("overrides" => { "max_tool_calls" => "many" }))).to be_nil
    end

    it "validates overrides.model at declaration, never at resolution" do
      expect(described_class.parse(valid("overrides" => { "model" => 42 }))).to be_nil
      expect(described_class.parse(valid("overrides" => { "model" => "" }))).to be_nil
      expect(described_class.parse(valid("overrides" => { "model" => "deepseek-v4-flash" })))
        .not_to be_nil
    end
  end

  describe "to_h round-trip" do
    it "is self-describing" do
      original = valid("session_mode" => "fixed", "session_id" => "s9",
                       "overrides" => { "turn_timeout" => 900 }, "enabled" => false)
      expect(described_class.parse!(original).to_h.compact)
        .to eq(original)
    end
  end
end