# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "zlib"
require "fileutils"
require "time"
require "optparse"

module Insika
  module Soak
    # The arrival-rate runner (RFC-0026 C3): sustain a declared load against a
    # live deploy for N hours, poll vitals hourly, append every observation to
    # the results file as it happens. It computes NO verdict (C5 does, offline)
    # and never retries a turn — a failed turn is evidence, not a problem to
    # smooth over. Threads, not fibers: the tool that measures the reactor
    # should not share its failure modes.
    class Runner
      # One failed precondition, named (P1..P5 per the techspec §7.2).
      Failure = Data.define(:check, :message)

      # Preflight refused the run. The failures name what was wrong; nothing
      # was written and no traffic past the probes was fired.
      class PreflightError < Insika::Error
        attr_reader :failures

        def initialize(failures)
          @failures = failures
          super(failures.map(&:message).join("; "))
        end
      end

      USAGE = <<~TXT
        insika soak — the 72h soak runner (RFC-0026)

        Usage: insika soak --run | --verify FILE | --preflight [options]

        Modes:
          --run                  fire the soak (mutually exclusive with --verify)
          --verify FILE          re-read an archived run; NO traffic, no network
          --preflight            run every precondition check and exit
          --dry-run              print the plan + one sample request, send nothing

        Options:
          --envelope PATH        the frozen envelope (default: evals/SOAK.md)
          --agent ID             the soak agent (default: from envelope)
          --out DIR              where the results file lands (default: evals/soak)
          --resume FILE          continue an interrupted run, recording the gap

        Environment:
          INSIKA_URL              base URL of the engine (default: http://localhost:9292)
          OPENCLAW_GATEWAY_TOKEN  Bearer; falls back to ADMIN_TOKEN, then "local-demo"
      TXT

      # Poisson inter-arrival seconds: `-mean * Math.log(1.0 - rand)`. Seeded,
      # so a re-run with the same seed is the same arrival sequence.
      def self.arrivals(seed:, turns_per_hour:, count:)
        rng = Random.new(seed)
        mean = 3600.0 / turns_per_hour
        Array.new(count) { -mean * Math.log(1.0 - rng.rand) }
      end

      # CLI entry (bin/insika delegates here). -> exit status.
      def self.main(argv, stdout: $stdout, stderr: $stderr, env: ENV, http: nil)
        opts = { envelope: Envelope::DEFAULT_PATH, out: "evals/soak" }
        modes = []
        OptionParser.new do |o|
          o.banner = "Usage: insika soak --run | --verify FILE | --preflight [options]"
          o.on("-h", "--help", "show this help") { stdout.puts USAGE; return 0 }
          o.on("--run", "fire the soak") { modes << :run }
          o.on("--verify FILE", "re-read an archived run") { |v| modes << [:verify, v] }
          o.on("--preflight", "run every precondition check") { modes << :preflight }
          o.on("--dry-run", "print the plan, send nothing") { modes << :dry_run }
          o.on("--envelope PATH") { |v| opts[:envelope] = v }
          o.on("--agent ID") { |v| opts[:agent] = v }
          o.on("--out DIR") { |v| opts[:out] = v }
          o.on("--resume FILE") { |v| opts[:resume] = v }
        end.parse!(argv)

        if modes.length != 1
          stderr.puts "insika soak: choose exactly one of --run, --verify, --preflight, --dry-run\n\n#{USAGE}"
          return 2
        end

        mode = modes.first
        if mode.is_a?(Array) && mode.first == :verify
          return verify(mode[1], envelope_path: opts[:envelope], stdout: stdout, stderr: stderr)
        end

        envelope = Envelope.load(opts[:envelope])
        runner = new(envelope: envelope, agent: opts[:agent], out: opts[:out],
                     env: env, http: http, stdout: stdout, stderr: stderr)

        case mode
        when :dry_run
          stdout.puts runner.dry_run_plan
          0
        when :preflight
          failures = runner.preflight
          if failures.empty?
            stdout.puts "preflight OK — every precondition holds"
            0
          else
            failures.each { |f| stderr.puts "preflight #{f.check}: #{f.message}" }
            2
          end
        when :run
          status = runner.run(resume: opts[:resume], traps: true)
          status == :complete ? 0 : 1
        end
      rescue OptionParser::ParseError => e
        stderr.puts "insika soak: #{e.message}\n\n#{USAGE}"
        2
      rescue PreflightError => e
        e.failures.each { |f| stderr.puts "preflight #{f.check}: #{f.message}" }
        stderr.puts "insika soak: refusing to start"
        2
      rescue Insika::ConfigError => e
        stderr.puts "insika soak: #{e.message}"
        2
      end

      # Pure fold over the archived file — no traffic, no network, no clock.
      def self.verify(path, envelope_path: nil, stdout: $stdout, stderr: $stderr)
        envelope = envelope_path ? Envelope.load(envelope_path) : Envelope.load
        records = read_records(path)
        result = Report.fold(records, envelope: envelope)
        stdout.puts result.to_s
        result.pass? ? 0 : 1
      rescue Insika::ConfigError => e
        stderr.puts "insika soak: #{e.message}"
        2
      end

      # Lazy line reader: .jsonl while running, .jsonl.gz once archived. Lines
      # that fail to parse travel through RAW so the fold can count them
      # (a truncated file must not read as a clean one).
      def self.read_records(path)
        lines = if path.end_with?(".gz")
                  Zlib::GzipReader.open(path) { |gz| gz.each_line.to_a }
                else
                  File.foreach(path).to_a
                end
        lines.map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          line
        end
      end

      attr_reader :envelope

      def initialize(envelope:, out: "evals/soak", agent: nil, env: ENV, http: nil,
                     seed: nil, clock: nil, sleeper: nil, stdout: $stdout, stderr: $stderr)
        @envelope = envelope
        @out = out
        @agent = agent || envelope[:agent]
        @env = env
        @http = http || Http.new(token: resolve_token(env))
        @seed = seed || Time.now.to_i
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || ->(s) { sleep s }
        @stdout = stdout
        @stderr = stderr
        @stop_reason = nil
        @lanes = []
        @in_flight = 0
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @vitals_failures = 0
        @vitals_degraded_noted = false
      end

      def target_url
        (@env["INSIKA_URL"] || @env["HARNESS_URL"] || "http://localhost:9292").sub(%r{/$}, "")
      end

      def corpus
        path = @envelope[:corpus] || "evals/soak/corpus.txt"
        lines = File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
        raise Insika::ConfigError, "soak corpus #{path} has no usable lines" if lines.empty?

        lines
      rescue Errno::ENOENT
        raise Insika::ConfigError, "soak corpus not found: #{path}"
      end

      # The five preconditions (techspec §7.2). Each is a REFUSAL TO START, not
      # a runtime behaviour: a soak must not measure its own limiter, a wrong
      # deploy, or a box that hides what it runs on.
      def preflight
        failures = []
        vitals = @http.get_vitals(target_url)

        if vitals[:status] != 200 || !vitals.dig(:body, "rss_bytes") || vitals.dig(:body, "boot_id").to_s.empty?
          failures << Failure.new("P1", "GET /v1/vitals must return 200 with a non-null rss_bytes and a non-empty boot_id")
        end

        probe = @http.post_turn(target_url, @agent, user: "soak-preflight", message: "ok",
                                timeout: (@envelope[:request_timeout_s] || 120))
        unless probe.dig(:timing).is_a?(Hash) && probe[:timing].any?
          failures << Failure.new("P2", "the probe turn carries no timing block (INSIKA_TURN_TIMING off on the target)")
        end
        unless probe.dig(:usage, "total_tokens").to_i.positive?
          failures << Failure.new("P3", "the probe turn called no model (no usage) — the run would measure the edge limiter")
        end

        pids = [vitals.dig(:body, "pid")]
        2.times do
          @sleeper.call(5)
          pids << @http.get_vitals(target_url).dig(:body, "pid")
        end
        if pids.compact.uniq.length != 1
          failures << Failure.new("P4", "vitals.pid is not stable across three polls — the RSS series would be a random worker per hour")
        end
        if @envelope[:web_concurrency] != 1
          failures << Failure.new("P4", "the envelope declares web_concurrency #{@envelope[:web_concurrency].inspect}, not 1")
        end
        unless URI(target_url).host == @envelope[:target_url_host]
          failures << Failure.new("P5", "target host #{URI(target_url).host.inspect} does not match the envelope's #{@envelope[:target_url_host].inspect}")
        end
        if @envelope[:agent] && @agent != @envelope[:agent]
          failures << Failure.new("P5", "agent #{@agent.inspect} does not match the envelope's #{@envelope[:agent].inspect}")
        end
        failures
      end

      def dry_run_plan
        lines = [
          "soak dry-run — no requests sent",
          "  envelope: #{@envelope[:target]} (sha #{@envelope.sha})",
          "  target:   #{target_url}",
          "  agent:    #{@agent}",
          "  shape:    #{@envelope[:turns_per_hour]} turns/h poisson, #{@envelope[:session_turns]}-turn sessions, " \
          "cap #{@envelope[:concurrency_cap]}, #{@envelope[:duration_hours]}h (#{@envelope[:warmup_hours]}h warmup)",
          "  sample:   POST #{URI.join(target_url + '/', 'v1/responses')} model=openclaw:#{@agent} user=soak-1",
          "  out:      #{@out}/"
        ]
        unless @envelope.calibrated?
          lines << "  NOTE: not calibrated — a #{@envelope[:duration_hours]}h run will refuse to start (E1 first)"
        end
        lines.join("\n")
      end

      # Fires the soak. -> :complete | :interrupted | :aborted.
      def run(resume: nil, traps: false)
        unless @envelope.calibrated? || @envelope.dry_run?
          raise Insika::ConfigError, "the #{@envelope[:duration_hours]}h run refuses to start: " \
                                     "the envelope is not calibrated (run E1 first, then write the three ceilings)"
        end

        failures = preflight
        raise PreflightError, failures unless failures.empty?

        install_traps if traps

        header = resume ? resume_header(resume) : new_header
        path = resume || File.join(@out, "#{header['run_id']}.jsonl")
        FileUtils.mkdir_p(File.dirname(path)) unless resume
        @file = File.open(path, "a")
        if resume
          append_gap_record(resume)
        else
          append(header)
        end

        run_id = header["run_id"]
        @stdout.puts "soak -> target=#{target_url} agent=#{@agent} duration=#{@envelope[:duration_hours]}h " \
                     "turns=#{@envelope[:turns_per_hour]}/h seed=#{@seed} out=#{path}"
        @stdout.puts "deploys are frozen for the window: any restart (boot_id or pid change) fails the run"

        duration_hours = @envelope[:duration_hours]
        offset_hours = resume ? elapsed_hours(header["started_at"]) : 0
        start = @clock.call
        deadline = start + (duration_hours - offset_hours) * 3600.0
        arrivals = self.class.arrivals(seed: @seed, turns_per_hour: @envelope[:turns_per_hour],
                                       count: @envelope[:turns_per_hour] * duration_hours)
        next_turn = start
        snapshot_index = 1
        turn_index = 0
        lane_id = 0

        loop do
          break if @stop_reason

          now = @clock.call
          # Hour 1 is due at start+3600 — the LAST snapshot (hour 72) is due
          # exactly at the deadline, so the snapshot fires before the loop
          # ends. Freshly computed from the index, never accumulated (float
          # drift must not eat the final hour).
          snapshot_due = start + snapshot_index * 3600.0
          if now >= snapshot_due - 1e-9 && snapshot_due <= deadline + 1e-9
            append_snapshot(offset_hours + snapshot_index)
            snapshot_index += 1
            next
          end
          break if now >= deadline

          # All scheduled arrivals consumed: nothing turn-shaped is ever due
          # again, so neither the spawn branch nor the wait math may keep
          # waking on next_turn.
          next_turn = Float::INFINITY if turn_index >= arrivals.length

          if now >= next_turn && next_turn <= deadline
            spawn_lane(lane_id, turn_index)
            lane_id += 1
            next_turn += arrivals[turn_index]
            turn_index += 1
            next
          end

          wait = [[snapshot_due, next_turn].min, deadline].min - now
          break if wait <= 0

          @sleeper.call(wait)
        end

        @lanes.each(&:join)
        reason = @stop_reason || "complete"
        append({ "t" => "end", "at" => Time.now.utc.iso8601, "reason" => reason })
        @file.close
        archive_path = gzip!(path)

        result = Report.fold(self.class.read_records(archive_path), envelope: @envelope)
        @stdout.puts result.to_s
        reason == "complete" ? :complete : :interrupted
      end

      private

      def resolve_token(env) = env["OPENCLAW_GATEWAY_TOKEN"] || env["ADMIN_TOKEN"] || "local-demo"

      def install_traps
        %w[INT TERM].each { |sig| Signal.trap(sig) { @stop_reason = "interrupted" } }
      end

      def new_header
        started = Time.now.utc.iso8601
        {
          "t" => "header", "run_id" => "#{@envelope[:target]}-#{started.tr(':', '-')}",
          "envelope_sha" => @envelope.sha, "envelope" => @envelope.values,
          "target_url" => target_url, "agent" => @agent,
          "seed" => @seed, "runner_version" => "insika #{Insika::VERSION}",
          "started_at" => started
        }
      end

      def resume_header(path)
        first = File.foreach(path).first
        header = JSON.parse(first)
        raise Insika::ConfigError, "#{path} has no header record" unless header["t"] == "header"

        header
      end

      def elapsed_hours(started_iso)
        [(Time.now.utc - Time.parse(started_iso)) / 3600, 0].max.floor
      end

      def append_gap_record(path)
        last_at = self.class.read_records(path).filter_map { |r| r.is_a?(Hash) ? r["at"] : nil }.compact.last
        to = Time.now.utc
        from = Time.parse(last_at) if last_at
        append({ "t" => "gap", "from" => (from || to).iso8601, "to" => to.iso8601,
                 "seconds" => (to - (from || to)).round, "reason" => "resume" })
      end

      def append(record)
        @file.puts(JSON.generate(record))
        @file.fsync
      end

      def append_snapshot(hour)
        vitals = @http.get_vitals(target_url)
        if vitals[:status] == 200 && vitals[:body].is_a?(Hash)
          @vitals_failures = 0
          append({ "t" => "snapshot", "at" => Time.now.utc.iso8601, "hour" => hour,
                   "envelope_sha" => @envelope.sha, "vitals" => vitals[:body], "error" => nil })
        else
          @vitals_failures += 1
          append({ "t" => "snapshot", "at" => Time.now.utc.iso8601, "hour" => hour,
                   "envelope_sha" => @envelope.sha, "vitals" => nil, "error" => "vitals poll failed" })
          if @vitals_failures >= 3 && !@vitals_degraded_noted
            @vitals_degraded_noted = true
            append({ "t" => "note", "at" => Time.now.utc.iso8601, "note" => "vitals_degraded" })
          end
        end
      end

      def spawn_lane(lane_id, turn_index)
        @lanes << Thread.new do
          queued_at = @clock.call
          @mutex.synchronize do
            @cond.wait(@mutex, 0.2) while @in_flight >= @envelope[:concurrency_cap]
            @in_flight += 1
          end
          queued_ms = ((@clock.call - queued_at) * 1000).round
          begin
            messages = corpus
            @envelope[:session_turns].times do |step|
              line = messages[turn_index % messages.length]
              result = @http.post_turn(target_url, @agent, user: "soak-#{lane_id}", message: line,
                                       timeout: (@envelope[:request_timeout_s] || 120))
              append({
                       "t" => "turn", "at" => Time.now.utc.iso8601, "lane" => lane_id, "step" => step + 1,
                       "corpus_line" => (turn_index % messages.length) + 1,
                       "ok" => result[:ok] == true, "status" => result[:status],
                       "queued_ms" => queued_ms, "ttfb_ms" => result[:ttfb_ms],
                       "total_ms" => result[:total_ms], "timing" => result[:timing],
                       "usage" => result[:usage], "error" => result[:error]
                     })
            end
          ensure
            @mutex.synchronize do
              @in_flight -= 1
              @cond.signal
            end
          end
        end
      end

      def gzip!(path)
        gz_path = "#{path}.gz"
        Zlib::GzipWriter.open(gz_path) { |gz| File.open(path, "rb") { |f| IO.copy_stream(f, gz) } }
        File.delete(path)
        gz_path
      end

      # stdlib HTTP transport, deliberately Net::HTTP — the same choice
      # loadtest.rb made, and the runner measures the reactor from outside it.
      class Http
        def initialize(token:)
          @token = token
        end

        def get_vitals(base_url)
          uri = URI.join(base_url + "/", "v1/vitals")
          req = Net::HTTP::Get.new(uri)
          req["Authorization"] = "Bearer #{@token}"
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 10
          http.read_timeout = 30
          res = http.request(req)
          { status: res.code.to_i, body: safe_json(res.body) }
        rescue StandardError => e
          { status: nil, body: nil, error: e.class.to_s }
        end

        # One turn: streaming POST /v1/responses; measures TTFB/total and
        # extracts the last usage + timing frames. No retry — a failed turn is
        # evidence.
        def post_turn(base_url, agent, user:, message:, timeout:)
          uri = URI.join(base_url + "/", "v1/responses")
          req = Net::HTTP::Post.new(uri)
          req["Authorization"] = "Bearer #{@token}"
          req["Content-Type"] = "application/json"
          req["Accept"] = "text/event-stream"
          req.body = JSON.generate(model: "openclaw:#{agent}", user: user, stream: true, input: message)

          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ttfb = nil
          usage = nil
          timing = nil
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.read_timeout = timeout
          http.open_timeout = 10

          status = nil
          http.start do
            http.request(req) do |res|
              status = res.code.to_i
              return { ok: false, status: status, error: "http #{status}" } unless status.between?(200, 299)

              buffer = +""
              res.read_body do |chunk|
                ttfb ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
                buffer << chunk
                while (i = buffer.index("\n\n"))
                  frame = buffer.slice!(0..i + 1)
                  frame.each_line do |line|
                    next unless line.start_with?("data:")

                    payload = line.sub(/^data:\s*/, "").strip
                    next if payload.empty? || payload == "[DONE]"

                    begin
                      obj = JSON.parse(payload)
                      u = obj.dig("response", "usage") || obj["usage"]
                      usage = u if u
                      tm = obj.dig("response", "timing")
                      timing = tm if tm
                    rescue JSON::ParserError
                      nil
                    end
                  end
                end
              end
            end
          end
          { ok: true, status: status, ttfb_ms: (ttfb || 0) * 1000.0,
            total_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0,
            usage: usage, timing: timing, error: nil }
        rescue ::Timeout::Error
          { ok: false, status: status, error: "timeout" }
        rescue StandardError => e
          { ok: false, status: status, error: e.class.to_s }
        end

        private

        def safe_json(body)
          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
