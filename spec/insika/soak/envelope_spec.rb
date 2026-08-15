# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Soak::Envelope do
  def fixture_source(values = {})
    yaml = {
      version: 1, target: "staging", duration_hours: 72, warmup_hours: 6,
      arrival: "poisson", turns_per_hour: 60, session_turns: 7, concurrency_cap: 8,
      rss_growth_ratio: 1.15, prep_p95_drift_ratio: 1.5,
      restarts_max: 0, error_rate_ceiling: 0.005, no_usage_rate_ceiling: 0.002,
      coverage_min_ratio: 0.95, gap_seconds_max: 900, hourly_turn_floor: 30
    }.merge(values)
    <<~MD
      # SOAK envelope

      prose paragraph.

      ```yaml
      #{YAML.dump(yaml.transform_keys(&:to_s)).lines.map { |l| l.chomp.empty? ? "" : "      #{l}" }.join}
      ```
    MD
  end

  def parse(source, sha: "sha256:abc")
    described_class.parse(source, sha: sha)
  end

  describe ".parse" do
    it "parses a valid fixture and exposes values with symbol keys" do
      env = parse(fixture_source)
      expect(env[:duration_hours]).to eq(72)
      expect(env[:rss_growth_ratio]).to eq(1.15)
      expect(env.values).to be_frozen
      expect(env.values).to be_a(Hash)
      expect(env.values).to all(satisfy { |k, _| k.is_a?(Symbol) })
    end

    it "exposes the sha and to_h merges it" do
      env = parse(fixture_source, sha: "sha256:deadbeef")
      expect(env.sha).to eq("sha256:deadbeef")
      expect(env.to_h).to eq(env.values.merge(sha: "sha256:deadbeef"))
    end

    it "raises ConfigError when there is no yaml fence" do
      expect { parse("# just prose\n") }.to raise_error(Insika::ConfigError, /yaml/)
    end

    it "uses the FIRST fence when two are present" do
      first = fixture_source.sub("duration_hours: 72", "duration_hours: 72")
      source = "#{first}\nmore prose\n```yaml\nduration_hours: 4\n```\n"
      expect(parse(source)[:duration_hours]).to eq(72)
    end

    it "raises ConfigError on unparseable yaml" do
      source = "```yaml\nfoo: [unclosed\n```\n"
      expect { parse(source) }.to raise_error(Insika::ConfigError)
    end

    Insika::Soak::Envelope::REQUIRED.each do |key|
      it "raises ConfigError naming :#{key} when it is missing" do
        values = { key => nil }
        expect { parse(fixture_source(values)) }
          .to raise_error(Insika::ConfigError, /#{key}/)
      end
    end

    it "raises ConfigError when a ratio is <= 1" do
      expect { parse(fixture_source(rss_growth_ratio: 1.0)) }
        .to raise_error(Insika::ConfigError, /rss_growth_ratio/)
      expect { parse(fixture_source(prep_p95_drift_ratio: 0.9)) }
        .to raise_error(Insika::ConfigError, /prep_p95_drift_ratio/)
    end

    it "raises ConfigError when a positive count is zero or negative" do
      expect { parse(fixture_source(turns_per_hour: 0)) }
        .to raise_error(Insika::ConfigError, /turns_per_hour/)
      expect { parse(fixture_source(hourly_turn_floor: -1)) }
        .to raise_error(Insika::ConfigError, /hourly_turn_floor/)
    end

    it "raises ConfigError when warmup_hours >= duration_hours" do
      expect { parse(fixture_source(duration_hours: 6, warmup_hours: 6)) }
        .to raise_error(Insika::ConfigError, /warmup_hours/)
    end

    it "raises ConfigError when a rate is outside 0..1" do
      expect { parse(fixture_source(error_rate_ceiling: 2)) }
        .to raise_error(Insika::ConfigError, /error_rate_ceiling/)
      expect { parse(fixture_source(coverage_min_ratio: -0.1)) }
        .to raise_error(Insika::ConfigError, /coverage_min_ratio/)
    end

    it "tolerates a negative-0 free pass on restarts_max (>= 0)" do
      expect(parse(fixture_source(restarts_max: 0))[:restarts_max]).to eq(0)
      expect { parse(fixture_source(restarts_max: -1)) }
        .to raise_error(Insika::ConfigError, /restarts_max/)
    end

    describe "calibration" do
      it "is not calibrated when a CALIBRATED key is missing" do
        expect(parse(fixture_source)).not_to be_calibrated
      end

      it "is calibrated when all CALIBRATED keys are present and positive" do
        env = parse(fixture_source(rss_ceiling_mb: 900, prep_p95_ceiling_ms: 10,
                                   total_p95_ceiling_ms: 30_000))
        expect(env).to be_calibrated
        expect(env[:rss_ceiling_mb]).to eq(900)
      end

      it "raises ConfigError when a calibrated key is present but not positive" do
        expect { parse(fixture_source(rss_ceiling_mb: 0, prep_p95_ceiling_ms: 10,
                                      total_p95_ceiling_ms: 30_000)) }
          .to raise_error(Insika::ConfigError, /rss_ceiling_mb/)
      end
    end

    describe "dry_run?" do
      it "is true at <= 8h" do
        expect(parse(fixture_source(duration_hours: 4, warmup_hours: 1))).to be_dry_run
        expect(parse(fixture_source(duration_hours: 8, warmup_hours: 1))).to be_dry_run
      end

      it "is false above 8h" do
        expect(parse(fixture_source)).not_to be_dry_run
      end
    end

    it "carries optional envelope keys through" do
      env = parse(fixture_source(agent: "soak-fixture", tenant: "soak"))
      expect(env[:agent]).to eq("soak-fixture")
      expect(env[:tenant]).to eq("soak")
    end
  end

  describe ".load" do
    it "computes the sha of the WHOLE file, prose included" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SOAK.md")
        File.write(path, fixture_source)
        env = described_class.load(path)

        expected = "sha256:#{Digest::SHA256.hexdigest(File.binread(path))}"
        expect(env.sha).to eq(expected)
      end
    end

    it "changes the sha when any byte changes, including prose" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SOAK.md")
        File.write(path, fixture_source)
        sha_a = described_class.load(path).sha

        File.write(path, fixture_source.sub("prose paragraph.", "prose paragraph changed."))
        sha_b = described_class.load(path).sha

        expect(sha_b).not_to eq(sha_a)
      end
    end

    it "raises ConfigError when the file is missing" do
      expect { described_class.load("/nonexistent/SOAK.md") }
        .to raise_error(Insika::ConfigError)
    end
  end
end
