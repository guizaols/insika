# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::EnvSchema do
  describe ".validate" do
    it "a clean environment yields no findings" do
      env = { "INSIKA_DB" => "/data/h.db", "INSIKA_PORT" => "9292", "INSIKA_OTEL" => "1" }
      expect(described_class.validate(env)).to be_empty
    end

    it "flags an unknown key in the owned INSIKA_ namespace (typo catcher)" do
      findings = described_class.validate({ "INSIKA_EGRES_ALLOW_HTTP" => "1" })
      expect(findings.map(&:kind)).to eq([:unknown])
      expect(findings.first.severity).to eq(:error)
      expect(findings.first.key).to eq("INSIKA_EGRES_ALLOW_HTTP")
    end

    it "still catches a typo under the legacy HARNESS_ namespace" do
      findings = described_class.validate({ "HARNESS_EGRES_ALLOW_HTTP" => "1" })
      expect(findings.map(&:kind)).to eq([:unknown])
      expect(findings.first.key).to eq("HARNESS_EGRES_ALLOW_HTTP")
    end

    it "does NOT flag foreign namespaces (OPENCLAW_ shared, LITESTREAM_, RAILWAY_, PORT)" do
      env = {
        "OPENCLAW_HOME" => "/x", "OPENCLAW_STATE_DIR" => "/y", # OpenClaw product owns these
        "LITESTREAM_REPLICA_URL" => "s3://b", "RAILWAY_PROJECT_ID" => "z", "PORT" => "3000"
      }
      expect(described_class.validate(env)).to be_empty
    end

    it "still validates the 3 OPENCLAW_ keys the engine DOES know (no unknown, but typed)" do
      # a known OPENCLAW_ key is never 'unknown'; foreign OPENCLAW_ keys are ignored.
      expect(described_class.validate({ "OPENCLAW_GATEWAY_TOKEN" => "tok" })).to be_empty
    end

    it "flags a non-integer INSIKA_PORT" do
      findings = described_class.validate({ "INSIKA_PORT" => "abc" })
      expect(findings.map(&:kind)).to eq([:invalid])
      expect(findings.first.message).to match(/integer/)
    end

    it "accepts a valid integer and negative integers" do
      expect(described_class.validate({ "INSIKA_SUBAGENT_FANOUT_CAP" => "8" })).to be_empty
    end

    it "flags a non-boolean flag" do
      findings = described_class.validate({ "INSIKA_EGRESS_ALLOW_HTTP" => "maybe" })
      expect(findings.map(&:kind)).to eq([:invalid])
    end

    it "accepts the full boolean vocabulary case-insensitively" do
      %w[1 0 true FALSE yes No on OFF].each do |v|
        expect(described_class.validate({ "INSIKA_OTEL" => v })).to be_empty
      end
    end

    it "flags a malformed URL" do
      findings = described_class.validate({ "INSIKA_PUBLIC_URL" => "not-a-url" })
      expect(findings.map(&:kind)).to eq([:invalid])
    end

    it "accepts an http(s) URL" do
      expect(described_class.validate({ "INSIKA_PUBLIC_URL" => "https://x.example/y" })).to be_empty
    end

    it "a blank value on an OPTIONAL key is not a finding" do
      expect(described_class.validate({ "INSIKA_PORT" => "" })).to be_empty
    end

    it "folds in deployment `extra:` specs (widening the known set)" do
      extra = [described_class.spec(name: "DEEPSEEK_MODEL", description: "model")]
      # DEEPSEEK_MODEL is now known (no finding); it is non-prefixed so was never 'unknown' anyway.
      expect(described_class.validate({ "DEEPSEEK_MODEL" => "deepseek-chat" }, extra: extra)).to be_empty
    end

    it "an `extra:` required key, absent, is a missing_required finding" do
      extra = [described_class.spec(name: "DEEPSEEK_API_KEY", required: true, secret: true)]
      findings = described_class.validate({}, extra: extra)
      expect(findings.map(&:kind)).to eq([:missing_required])
    end

    it "an `extra:` required key, present-but-blank, is invalid (not duplicated)" do
      extra = [described_class.spec(name: "DEEPSEEK_API_KEY", required: true, secret: true)]
      findings = described_class.validate({ "DEEPSEEK_API_KEY" => "  " }, extra: extra)
      expect(findings.length).to eq(1)
      expect(findings.first.kind).to eq(:invalid)
    end

    context "legacy HARNESS_ aliases (rename pass 2)" do
      it "a known key set under the legacy prefix is DEPRECATED (warn), not fatal" do
        findings = described_class.validate({ "HARNESS_DB" => "/data/h.db" })
        expect(findings.map(&:kind)).to eq([:deprecated])
        expect(findings.first.severity).to eq(:warn)
        expect(findings.first.message).to match(/HARNESS_DB is deprecated — rename to INSIKA_DB/)
      end

      it "still type-checks the VALUE of a legacy key (deprecated + invalid)" do
        findings = described_class.validate({ "HARNESS_PORT" => "abc" })
        expect(findings.map(&:kind)).to contain_exactly(:deprecated, :invalid)
      end

      it "a required key present under only its legacy alias is NOT missing" do
        extra = [described_class.spec(name: "INSIKA_NEEDED", required: true)]
        expect(described_class.validate({ "HARNESS_NEEDED" => "x" }, extra: extra).map(&:kind)).to eq([:deprecated])
      end
    end
  end

  describe ".read (dual-read)" do
    it "prefers the canonical INSIKA_ name" do
      expect(described_class.read("INSIKA_DB", { "INSIKA_DB" => "/new", "HARNESS_DB" => "/old" })).to eq("/new")
    end

    it "falls back to the deprecated HARNESS_ alias when the new name is blank/absent" do
      expect(described_class.read("INSIKA_DB", { "HARNESS_DB" => "/old" })).to eq("/old")
      expect(described_class.read("INSIKA_DB", { "INSIKA_DB" => "", "HARNESS_DB" => "/old" })).to eq("/old")
    end

    it "nil when neither is set" do
      expect(described_class.read("INSIKA_DB", {})).to be_nil
    end
  end

  describe ".reconcile_legacy!" do
    it "backfills INSIKA_* from a legacy HARNESS_* alias and warns once with the list" do
      env = { "HARNESS_DB" => "/old", "HARNESS_OTEL" => "1" }
      warned = []
      migrated = described_class.reconcile_legacy!(env, warn: ->(m) { warned << m })
      expect(migrated).to eq(%w[HARNESS_DB HARNESS_OTEL])
      expect(env["INSIKA_DB"]).to eq("/old")
      expect(env["INSIKA_OTEL"]).to eq("1")
      expect(warned.length).to eq(1)
      expect(warned.first).to match(/HARNESS_DB, HARNESS_OTEL/)
    end

    it "the new name WINS when both are set (no overwrite) and is not reported" do
      env = { "INSIKA_DB" => "/new", "HARNESS_DB" => "/old" }
      expect(described_class.reconcile_legacy!(env, warn: ->(_) {})).to be_empty
      expect(env["INSIKA_DB"]).to eq("/new")
    end

    it "is a no-op (no warning) with no legacy keys" do
      warned = []
      expect(described_class.reconcile_legacy!({ "INSIKA_DB" => "/x" }, warn: ->(m) { warned << m })).to be_empty
      expect(warned).to be_empty
    end
  end

  describe ".enforce!" do
    it "WARNS on findings and returns them without raising (last-known-good default)" do
      warned = []
      findings = described_class.enforce!({ "INSIKA_BOGUS" => "1" }, strict: false, warn: ->(m) { warned << m })
      expect(findings.map(&:kind)).to eq([:unknown])
      expect(warned).to include(a_string_matching(/INSIKA_BOGUS/))
    end

    it "RAISES ConfigError with error findings when strict" do
      expect { described_class.enforce!({ "INSIKA_BOGUS" => "1" }, strict: true, warn: ->(_) {}) }
        .to raise_error(Insika::ConfigError) { |e| expect(e.findings.map(&:key)).to eq(["INSIKA_BOGUS"]) }
    end

    it "a deprecated legacy key is a WARN, never fatal — even under strict" do
      expect { described_class.enforce!({ "HARNESS_DB" => "/x" }, strict: true, warn: ->(_) {}) }.not_to raise_error
    end

    it "strict + clean env does not raise" do
      expect { described_class.enforce!({ "INSIKA_DB" => "/x" }, strict: true, warn: ->(_) {}) }.not_to raise_error
    end

    it "derives strictness from INSIKA_CONFIG_STRICT when strict: nil (legacy alias honored)" do
      expect { described_class.enforce!({ "INSIKA_CONFIG_STRICT" => "1", "INSIKA_BOGUS" => "1" }, warn: ->(_) {}) }
        .to raise_error(Insika::ConfigError)
      expect { described_class.enforce!({ "HARNESS_CONFIG_STRICT" => "1", "INSIKA_BOGUS" => "1" }, warn: ->(_) {}) }
        .to raise_error(Insika::ConfigError)
      expect { described_class.enforce!({ "INSIKA_BOGUS" => "1" }, warn: ->(_) {}) }.not_to raise_error
    end
  end

  describe ".truthy?" do
    it "matches the engine convention" do
      expect(described_class.truthy?("1")).to be(true)
      expect(described_class.truthy?("ON")).to be(true)
      expect(described_class.truthy?("0")).to be(false)
      expect(described_class.truthy?(nil)).to be(false)
    end
  end
end
