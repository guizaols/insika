# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "time"

RSpec.describe Insika::Soak::Runner do
  def tmp_envelope(dir, overrides = {})
    yaml = {
      version: 1, target: "staging", target_url_host: "staging.example",
      agent: "soak-fixture", tenant: "soak",
      duration_hours: 72, warmup_hours: 6,
      arrival: "poisson", turns_per_hour: 60, session_turns: 1, concurrency_cap: 2,
      request_timeout_s: 120, corpus: File.join(dir, "corpus.txt"),
      web_concurrency: 1, chat_rate_limit: 0, agent_token_ceiling: 0, turn_timing: "required",
      rss_growth_ratio: 1.15, prep_p95_drift_ratio: 1.5, restarts_max: 0,
      error_rate_ceiling: 0.005, no_usage_rate_ceiling: 0.002,
      coverage_min_ratio: 0.95, gap_seconds_max: 900, hourly_turn_floor: 30,
      rss_ceiling_mb: 900, prep_p95_ceiling_ms: 10, total_p95_ceiling_ms: 30_000
    }.merge(overrides)
    path = File.join(dir, "SOAK.md")
    File.write(path, "```yaml\n#{YAML.dump(yaml.transform_keys(&:to_s))}```\n")
    File.write(File.join(dir, "corpus.txt"), "oi, tudo bem?\npreciso de ajuda com um pedido\n")
    Insika::Soak::Envelope.load(path)
  end

  def fake_http(turns: nil, vitals: nil)
    calls = { turns: 0, vitals: 0 }
    http = Class.new do
      define_method(:post_turn) do |_base, _agent, user:, message:, timeout:|
        calls[:turns] += 1
        turns || { ok: true, status: 200, ttfb_ms: 700.0, total_ms: 2900.0,
                   timing: { "prep_ms" => 0.4, "ttft_ms" => 700.0, "gen_ms" => 2200.0 },
                   usage: { "total_tokens" => 48_000 }, error: nil }
      end
      define_method(:get_vitals) do |_base|
        calls[:vitals] += 1
        vitals || { status: 200, body: { "boot_id" => "b1", "pid" => 1000,
                                         "rss_bytes" => 512 * 1024 * 1024 } }
      end
    end.new
    [http, calls]
  end

  describe ".arrivals" do
    it "is deterministic for a fixed seed" do
      expect(described_class.arrivals(seed: 42, rate_per_hour: 60, count: 100))
        .to eq(described_class.arrivals(seed: 42, rate_per_hour: 60, count: 100))
    end

    it "differs across seeds" do
      expect(described_class.arrivals(seed: 1, rate_per_hour: 60, count: 50))
        .not_to eq(described_class.arrivals(seed: 2, rate_per_hour: 60, count: 50))
    end

    it "has a mean inter-arrival within tolerance of 3600 / turns_per_hour over 10k draws" do
      gaps = described_class.arrivals(seed: 7, rate_per_hour: 60, count: 10_000)
      mean = gaps.sum / gaps.length
      expect(mean).to be_within(2.0).of(60.0)
      expect(gaps).to all(be >= 0)
    end
  end

  describe ".main (CLI)" do
    it "--help exits 0 and prints the usage block" do
      out = StringIO.new
      status = described_class.main(["--help"], stdout: out, stderr: StringIO.new)
      expect(status).to eq(0)
      expect(out.string).to include("insika soak")
      expect(out.string).to include("--verify")
    end

    it "an unknown flag aborts with exit 2" do
      err = StringIO.new
      status = described_class.main(["--bogus"], stdout: StringIO.new, stderr: err)
      expect(status).to eq(2)
      expect(err.string).to include("--bogus")
    end

    it "--dry-run sends zero requests and prints the resolved plan" do
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir)
        http, calls = fake_http
        out = StringIO.new
        status = described_class.main(
          ["--dry-run", "--envelope", File.join(dir, "SOAK.md"), "--agent", "soak-fixture"],
          stdout: out, stderr: StringIO.new, env: { "INSIKA_URL" => "http://staging.example" },
          http: http
        )
        expect(status).to eq(0)
        expect(calls[:turns]).to eq(0)
        expect(calls[:vitals]).to eq(0)
        expect(out.string).to include("dry-run")
        expect(out.string).to include("soak-fixture")
      end
    end

    it "--verify on a committed fixture prints its expected verdict" do
      out = StringIO.new
      fixture = File.expand_path("../../fixtures/soak/leak.jsonl", __dir__)
      envelope = File.expand_path("../../fixtures/soak/envelope.md", __dir__)
      status = described_class.main(["--verify", fixture, "--envelope", envelope],
                                    stdout: out, stderr: StringIO.new)
      expect(status).to eq(1)
      expect(out.string).to include("FAIL")
      expect(out.string).to include("rss_growth_ratio")
    end
  end

  describe "preflight" do
    def preflight(env: { "INSIKA_URL" => "http://staging.example" }, http:, agent: "soak-fixture")
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir)
        runner = described_class.new(envelope: envelope, agent: agent,
                                     env: env, http: http, sleeper: ->(_s) {})
        return runner.preflight
      end
    end

    it "passes when every precondition holds" do
      http, = fake_http
      expect(preflight(http: http)).to eq([])
    end

    it "fails P1 when vitals carries no rss_bytes" do
      http, = fake_http(vitals: { status: 200, body: { "boot_id" => "b1", "rss_bytes" => nil } })
      expect(preflight(http: http).map(&:check)).to include("P1")
    end

    it "fails P1 when vitals is not 200" do
      http, = fake_http(vitals: { status: 500, body: {} })
      expect(preflight(http: http).map(&:check)).to include("P1")
    end

    it "fails P2 when the probe turn carries no timing block" do
      http, = fake_http(turns: { ok: true, status: 200, timing: nil,
                                 usage: { "total_tokens" => 100 } })
      expect(preflight(http: http).map(&:check)).to include("P2")
    end

    it "fails P3 when the probe turn carries no usage — the limiter trap" do
      http, = fake_http(turns: { ok: true, status: 200,
                                 timing: { "prep_ms" => 0.4 }, usage: nil })
      expect(preflight(http: http).map(&:check)).to include("P3")
    end

    it "fails P4 when the pid is unstable across polls" do
      pids = [1000, 1000, 2000]
      http = Class.new do
        define_method(:get_vitals) do |_base|
          { status: 200, body: { "boot_id" => "b1", "pid" => pids.shift,
                                 "rss_bytes" => 512 * 1024 * 1024 } }
        end
        define_method(:post_turn) do |*_args, **_kwargs|
          { ok: true, status: 200, timing: { "prep_ms" => 0.4 },
            usage: { "total_tokens" => 100 } }
        end
      end.new
      expect(preflight(http: http).map(&:check)).to include("P4")
    end

    it "fails P5 when the target host does not match the envelope" do
      http, = fake_http
      expect(preflight(env: { "INSIKA_URL" => "http://wrong.example" }, http: http).map(&:check))
        .to include("P5")
    end

    it "fails P5 when the agent does not match the envelope" do
      http, = fake_http
      expect(preflight(http: http, agent: "other-agent").map(&:check)).to include("P5")
    end
  end

  describe "#run" do
    it "writes header, turns, hourly snapshots and a complete end — no verdict lost" do
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir, turns_per_hour: 12, hourly_turn_floor: 4, session_turns: 1)
        out_dir = File.join(dir, "out")
        http, calls = fake_http

        seed = 42
        # The fake clock is 10s in by the time the run starts: preflight polls
        # the pid twice, 5 fake seconds apart. The deadline moves with it.
        deadline = 72 * 3600.0 + 10
        # Exactly the runner's spawn model: turn k fires at the cumulative sum
        # of the first k gaps, and only while that sum stays inside the window.
        expected_turns = 0
        sum = 0.0
        described_class.arrivals(seed: seed, rate_per_hour: 12, count: 72 * 12).each do |gap|
          break if sum > deadline

          expected_turns += 1
          sum += gap
        end

        clock = { t: 0.0 }
        runner = described_class.new(
          envelope: envelope, agent: "soak-fixture", out: out_dir, seed: seed,
          env: { "INSIKA_URL" => "http://staging.example" }, http: http,
          clock: -> { clock[:t] }, sleeper: ->(s) { clock[:t] += s }
        )
        status = runner.run
        expect(status).to eq(:complete)

        file = Dir[File.join(out_dir, "*.jsonl.gz")].first
        lines = Zlib::GzipReader.open(file) { |gz| gz.each_line.map { |l| JSON.parse(l) } }
        by_type = lines.group_by { |l| l["t"] }
        expect(by_type["header"].length).to eq(1)
        expect(by_type["turn"].length).to eq(expected_turns)
        expect(by_type["snapshot"].length).to eq(72)
        expect(by_type["end"].first).to include("t" => "end", "reason" => "complete")

        header = by_type["header"].first
        expect(header["envelope_sha"]).to eq(envelope.sha)
        expect(header["agent"]).to eq("soak-fixture")

        snapshot = by_type["snapshot"].first
        expect(snapshot["hour"]).to eq(1)
        expect(snapshot["vitals"]["boot_id"]).to eq("b1")

        expect(calls[:turns]).to eq(expected_turns + 1) # +1: the preflight probe
        expect(calls[:vitals]).to eq(72 + 3) # 72 snapshots + 3 preflight polls
      end
    end

    it "scales ARRIVALS by session_turns: 3-turn sessions fire turns_per_hour/3 arrivals (turn load stays 12/h)" do
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir, turns_per_hour: 12, hourly_turn_floor: 4, session_turns: 3)
        out_dir = File.join(dir, "out")
        calls = []
        http = Class.new do
          define_method(:post_turn) do |_base, _agent, user:, message:, timeout:|
            calls << [user, message]
            { ok: true, status: 200, ttfb_ms: 700.0, total_ms: 2900.0,
              timing: { "prep_ms" => 0.4, "ttft_ms" => 700.0, "gen_ms" => 2200.0 },
              usage: { "total_tokens" => 48_000 }, error: nil }
          end
          define_method(:get_vitals) do |_base|
            { status: 200, body: { "boot_id" => "b1", "pid" => 1000,
                                   "rss_bytes" => 512 * 1024 * 1024 } }
          end
        end.new

        seed = 99
        deadline = 72 * 3600.0 + 10
        # The runner arrives at turns_per_hour / session_turns = 4 sessions/h.
        expected_sessions = 0
        sum = 0.0
        described_class.arrivals(seed: seed, rate_per_hour: 4.0, count: (4.0 * 72).ceil).each do |gap|
          break if sum > deadline

          expected_sessions += 1
          sum += gap
        end

        clock = { t: 0.0 }
        runner = described_class.new(
          envelope: envelope, agent: "soak-fixture", out: out_dir, seed: seed,
          env: { "INSIKA_URL" => "http://staging.example" }, http: http,
          clock: -> { clock[:t] }, sleeper: ->(s) { clock[:t] += s }
        )
        expect(runner.run).to eq(:complete)

        file = Dir[File.join(out_dir, "*.jsonl.gz")].first
        lines = Zlib::GzipReader.open(file) { |gz| gz.each_line.map { |l| JSON.parse(l) } }
        turns = lines.select { |l| l["t"] == "turn" }
        expect(turns.length).to eq(expected_sessions * 3) # 12 turns/h declared, not 36

        by_lane = turns.group_by { |l| l["lane"] }
        expect(by_lane.keys.length).to eq(expected_sessions)
        expect(by_lane.values).to all(have_attributes(length: 3))

        # Each session reads the corpus advancing per step, so the 3 turns of a
        # lane use 3 DIFFERENT (mod 2) lines, not the same line 3x.
        by_lane.each_value do |lane_turns|
          expect(lane_turns.map { |t| t["corpus_line"] }.uniq.length).to eq(2)
        end
        expect(calls.length).to eq(expected_sessions * 3 + 1) # +1: preflight probe
      end
    end

    it "--resume continues lane ids (a resume must not revive pre-gap sessions)" do
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir, turns_per_hour: 12, hourly_turn_floor: 4, session_turns: 1)
        out_dir = File.join(dir, "out")
        FileUtils.mkdir_p(out_dir)
        http, = fake_http

        now = Time.now.utc
        file = File.join(out_dir, "staging-resume.jsonl")
        header = { "t" => "header", "run_id" => "staging-resume", "envelope_sha" => envelope.sha,
                   "envelope" => envelope.values, "target_url" => "http://staging.example",
                   "agent" => "soak-fixture", "seed" => 7, "runner_version" => "insika 0.2.0",
                   "started_at" => (now - 3600).iso8601 }
        old = (0..4).map do |n|
          { "t" => "turn", "at" => (now - 3600 + n).iso8601, "lane" => n, "step" => 1,
            "corpus_line" => 1, "ok" => true, "status" => 200, "queued_ms" => 0,
            "ttfb_ms" => 700.0, "total_ms" => 2900.0,
            "timing" => { "prep_ms" => 0.4 }, "usage" => { "total_tokens" => 100 },
            "error" => nil }
        end
        File.write(file, ([header] + old).map { |l| JSON.generate(l) }.join("\n") + "\n")

        clock = { t: 0.0 }
        opts = {
          envelope: envelope, agent: "soak-fixture", out: out_dir, seed: 7,
          env: { "INSIKA_URL" => "http://staging.example" }, http: http,
          clock: -> { clock[:t] }, sleeper: ->(s) { clock[:t] += s }
        }
        expect(described_class.new(**opts).run(resume: file)).to eq(:complete)

        gz = File.join(out_dir, "staging-resume.jsonl.gz")
        lines = Zlib::GzipReader.open(gz) { |g| g.each_line.map { |l| JSON.parse(l) } }
        resumed = lines.select { |l| l["t"] == "turn" && l["lane"] >= 5 }
        expect(resumed.length).to be_positive
        expect(resumed.map { |l| l["lane"] }).to all(be >= 5)
      end
    end

    it "--resume appends a gap record spanning the outage" do
      Dir.mktmpdir do |dir|
        envelope = tmp_envelope(dir, turns_per_hour: 12, hourly_turn_floor: 4, session_turns: 1)
        out_dir = File.join(dir, "out")
        FileUtils.mkdir_p(out_dir)
        http, = fake_http

        now = Time.now.utc
        file = File.join(out_dir, "staging-resume.jsonl")
        header = { "t" => "header", "run_id" => "staging-resume", "envelope_sha" => envelope.sha,
                   "envelope" => envelope.values, "target_url" => "http://staging.example",
                   "agent" => "soak-fixture", "seed" => 7, "runner_version" => "insika 0.2.0",
                   "started_at" => (now - 3600).iso8601 }
        last_turn = { "t" => "turn", "at" => (now - 3600).iso8601, "lane" => 1, "step" => 1,
                      "corpus_line" => 1, "ok" => true, "status" => 200, "queued_ms" => 0,
                      "ttfb_ms" => 700.0, "total_ms" => 2900.0,
                      "timing" => { "prep_ms" => 0.4 }, "usage" => { "total_tokens" => 100 },
                      "error" => nil }
        File.write(file, "#{[header, last_turn].map { |l| JSON.generate(l) }.join("\n")}\n")

        clock = { t: 0.0 }
        opts = {
          envelope: envelope, agent: "soak-fixture", out: out_dir, seed: 7,
          env: { "INSIKA_URL" => "http://staging.example" }, http: http,
          clock: -> { clock[:t] }, sleeper: ->(s) { clock[:t] += s }
        }
        expect(described_class.new(**opts).run(resume: file)).to eq(:complete)

        gz = File.join(out_dir, "staging-resume.jsonl.gz")
        lines = Zlib::GzipReader.open(gz) { |g| g.each_line.map { |l| JSON.parse(l) } }
        gap = lines.find { |l| l["t"] == "gap" }
        expect(gap).not_to be_nil
        expect(gap["reason"]).to eq("resume")
        expect(gap["seconds"]).to be_within(120).of(3600)
        expect(lines.last["t"]).to eq("end")
        expect(lines.last["reason"]).to eq("complete")
      end
    end
  end
end
