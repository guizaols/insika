# frozen_string_literal: true

require "spec_helper"

# RFC-0033 C2 — the parsed follow-up policy of ONE agent: the ONLY shape the
# engine accepts, shared by the tool, the firer, the doctor and the Studio.
# `parse` returns nil on a malformed hash (D9); `parse!` raises naming the
# defect.
RSpec.describe Insika::FollowupPolicy do
  def policy(hash)
    described_class.parse!(hash)
  end

  describe ".parse! / .parse" do
    it "a complete policy round-trips via to_h" do
      hash = {
        "arm" => "schedule",
        "policy" => {
          "quiet_hours" => { "timezone" => "America/Sao_Paulo", "start" => "21:30", "end" => "09:00" },
          "max_frequency" => "2/24h",
          "cancel_keywords" => ["não quero mais contato"],
          "silence_after_sends" => 3
        }
      }
      p = policy(hash)
      expect(p.arm).to eq("schedule")
      expect(p.quiet_hours).to be_a(Insika::FollowupPolicy::QuietHours)
      expect(p.max_frequency).to eq("2/24h")
      expect(p.cancel_keywords).to eq(["não quero mais contato"])
      expect(p.silence_after_sends).to eq(3)
      expect(p.to_h).to eq(hash)
    end

    it "arm defaults to 'schedule' when absent" do
      expect(policy("policy" => {}).arm).to eq("schedule")
    end

    it "quiet_hours absent -> no quiet window" do
      p = policy("policy" => {})
      expect(p.quiet_hours).to be_nil
      expect(p.quiet?(Time.now.utc)).to be(false)
    end

    it "max_frequency absent -> no frequency ceiling" do
      expect(policy("policy" => {}).max_frequency).to be_nil
    end

    it "cancel_keywords absent -> [] (no keyword detection)" do
      expect(policy("policy" => {}).cancel_keywords).to eq([])
    end

    it "silence_after_sends absent -> 3" do
      expect(policy("policy" => {}).silence_after_sends).to eq(3)
    end
  end

  describe "validation rules" do
    it "policy must be a Hash" do
      expect { policy("policy" => "nope") }.to raise_error(Insika::ValidationError, /Hash/)
      expect(described_class.parse("policy" => "nope")).to be_nil
    end

    it "arm (top level) must be a non-blank String" do
      expect { policy("arm" => "", "policy" => {}) }.to raise_error(Insika::ValidationError, /arm/)
    end

    it "quiet_hours start/end must match /\\A\\d{2}:\\d{2}\\z/" do
      # only the FORMAT is validated (no range check): "25:00" passes, "09:00" passes
      expect { policy("policy" => { "quiet_hours" => { "timezone" => "UTC", "start" => "25:00", "end" => "09:00" } }) }
        .not_to raise_error
      # a single-digit hour does not match \d{2}:\d{2}
      expect { policy("policy" => { "quiet_hours" => { "timezone" => "UTC", "start" => "21:30", "end" => "9:00" } }) }
        .to raise_error(Insika::ValidationError, /quiet_hours/)
    end

    it "quiet_hours missing timezone -> nil" do
      expect { policy("policy" => { "quiet_hours" => { "start" => "21:30", "end" => "09:00" } }) }
        .to raise_error(Insika::ValidationError, /timezone/)
    end

    it "a bogus IANA timezone is a malformed policy (the doctor names it)" do
      expect { policy("policy" => { "quiet_hours" => { "timezone" => "Not/AZone", "start" => "21:30", "end" => "09:00" } }) }
        .to raise_error(Insika::ValidationError, /timezone/)
    end

    it "max_frequency accepts /\\A\\d+\\/(\\d+)(m|h|d)s?\\z/" do
      %w[2/24h 2/24hs 1/30m 9/7d].each do |f|
        expect(policy("policy" => { "max_frequency" => f }).max_frequency).to eq(f)
      end
    end

    it "max_frequency rejects malformed windows" do
      ["2/", "x/24h", "2/3w"].each do |f|
        expect { policy("policy" => { "max_frequency" => f }) }
          .to raise_error(Insika::ValidationError, /max_frequency/)
      end
    end

    it "silence_after_sends must be an Integer > 0" do
      expect { policy("policy" => { "silence_after_sends" => 0 }) }
        .to raise_error(Insika::ValidationError, /silence_after_sends/)
      expect(described_class.parse("policy" => { "silence_after_sends" => 0 })).to be_nil
    end

    it "a keyword longer than 200 chars is refused" do
      long = "x" * 201
      expect { policy("policy" => { "cancel_keywords" => [long] }) }
        .to raise_error(Insika::ValidationError, /cancel_keywords/)
    end
  end

  describe "#frequency_window" do
    it "parses count + seconds" do
      expect(policy("policy" => { "max_frequency" => "2/24h" }).frequency_window)
        .to eq(count: 2, seconds: 86_400)
      expect(policy("policy" => { "max_frequency" => "1/30m" }).frequency_window)
        .to eq(count: 1, seconds: 1800)
      expect(policy("policy" => { "max_frequency" => "9/7d" }).frequency_window)
        .to eq(count: 9, seconds: 604_800)
    end

    it "tolerates the 's' suffix" do
      expect(policy("policy" => { "max_frequency" => "2/24hs" }).frequency_window)
        .to eq(count: 2, seconds: 86_400)
    end
  end

  describe "#quiet?" do
    let(:p) { policy("policy" => { "quiet_hours" => { "timezone" => "America/Sao_Paulo", "start" => "21:30", "end" => "09:00" } }) }

    # America/Sao_Paulo = UTC-3 (no DST since 2019)
    it "true inside the window (23:59 local)" do
      t = Time.iso8601("2026-08-14T23:59:00-03:00").utc
      expect(p.quiet?(t)).to be(true)
    end

    it "true just after midnight (00:01 local)" do
      t = Time.iso8601("2026-08-14T00:01:00-03:00").utc
      expect(p.quiet?(t)).to be(true)
    end

    it "false outside the window (15:00 local)" do
      t = Time.iso8601("2026-08-14T15:00:00-03:00").utc
      expect(p.quiet?(t)).to be(false)
    end
  end

  describe "#match_keyword" do
    let(:p) { policy("policy" => { "cancel_keywords" => ["não quero mais contato", "pare de me mandar"] }) }

    it "matches case- and accent-insensitively" do
      expect(p.match_keyword("NÃO quero mais contato.")).to eq("não quero mais contato")
    end

    it "matches as a substring" do
      expect(p.match_keyword("por favor pare de me mandar mensagens")).to eq("pare de me mandar")
    end

    it "returns nil when nothing matches" do
      expect(p.match_keyword("o que você tem?" )).to be_nil
    end
  end
end
