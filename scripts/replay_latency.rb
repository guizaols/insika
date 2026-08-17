#!/usr/bin/env ruby
# frozen_string_literal: true

# RFC-0027 C7 — E2 replay harness. The number that kills or keeps H-latência.
#
# Replays N conversations against a LIVE staging engine (relay inbound) and
# measures the median first-balloon latency on the CUSTOMER clock: the POST that
# creates the turn -> the first POST the engine hands back to the surrogate
# consumer. The engine's in-process `first_balloon_ms` (C5) is the other half of
# the story; this script is the before/after on the wire.
#
#   scripts/replay_latency.rb --url https://staging/channels/relay/events \
#                            --token $INSIKA_RELAY_TOKEN \
#                            --corpus path/to/16.json \
#                            --out report.json
#
# It hosts a local deliver_url and the staging relay must be configured to POST
# to it (INSIKA_RELAY_DELIVER_URL=<the url this script prints>).
#
# `--hold-ms N` SIMULATES the legacy 4-6s pedestal (a hold before the first
# message of each case is forwarded), so the before/after comparison does not
# depend on a live toggle: run once with --hold-ms 0, once with --hold-ms 5000,
# compare the two reports. That is what "no drop vs buffered baseline" means as a
# number.
#
# Exit 0 ALWAYS — this is a measurement, not a gate. A human applies the discard.
#
# Not in lib/ and not in CI: it needs a provider and a staging agent. The
# arithmetic it must not silently rot (corpus parsing, percentiles) is covered by
# spec/scripts/replay_latency_spec.rb — no network there.

require "json"
require "net/http"
require "optparse"
require "socket"

# Pure helpers (covered by the spec) + the network runner.
module ReplayLatency
  TARGET_MS = 2_000

  module_function

  # Corpus JSON -> [case] (string keys): { "id", "external_id", "agent",
  # "messages": [{ "at_ms", "text" }] }. Refuses shapes the run cannot mean —
  # a missing external_id would make two cases share one session.
  def parse_corpus(json)
    raw = JSON.parse(json)
    raise "corpus must be a JSON array" unless raw.is_a?(Array)
    raise "corpus must have at least 1 case" if raw.empty?

    raw.each do |c|
      raise "corpus case is missing \"id\"" if c["id"].to_s.strip.empty?
      raise "case #{c['id']} is missing external_id" if c["external_id"].to_s.strip.empty?
      raise "case #{c['id']} is missing agent" if c["agent"].to_s.strip.empty?

      msgs = c["messages"]
      valid = msgs.is_a?(Array) && !msgs.empty? &&
              msgs.all? { |m| m.is_a?(Hash) && !m["text"].to_s.strip.empty? }
      raise "case #{c['id']} must carry non-empty messages [{at_ms, text}]" unless valid
    end
    raw
  end

  # Nearest-rank percentile of an ascending-sorted numeric array; nil when empty.
  def percentile(sorted, q)
    return nil if sorted.empty?

    idx = (q * sorted.size).ceil - 1
    sorted[[idx, sorted.size - 1].min]
  end

  def median(sorted) = percentile(sorted, 0.5)

  # The report's arithmetic from measured per-case numbers:
  # -> { "median_first_balloon_ms", "p95_first_balloon_ms" } (Numeric | nil).
  def statistics(samples)
    sorted = samples.compact.sort
    {
      "median_first_balloon_ms" => median(sorted),
      "p95_first_balloon_ms" => percentile(sorted, 0.95)
    }
  end

  # Runs the harness. options: url, token, corpus, hold_ms, out.
  def run(options)
    receiver = DeliverReceiver.new
    puts "listening on #{receiver.url} — point the relay at INSIKA_RELAY_DELIVER_URL=#{receiver.url}"

    cases = options[:corpus].map do |c|
      measure_case(c, receiver, options[:url], options[:token], options[:hold_ms])
    end

    report = {
      "n" => cases.size,
      **statistics(cases.map { |c| c[:first_balloon_ms] }),
      "per_case" => cases.map do |c|
        { "id" => c[:id], "agent" => c[:agent], "external_id" => c[:external_id],
          "first_balloon_ms" => c[:first_balloon_ms], "balloons" => c[:balloons] }
      end
    }
    File.write(options[:out], JSON.pretty_generate(report))

    median = report["median_first_balloon_ms"]
    reached = median && median < TARGET_MS
    puts "median first balloon: #{median} ms (p95: #{report['p95_first_balloon_ms']} ms)"
    puts "TARGET: #{reached ? 'REACHED' : 'not reached'} — median < #{TARGET_MS} ms"
    puts "report: #{options[:out]}"
    report
  end

  # One conversation: sends each message at its at_ms offset (the consumer's
  # buffer is gone; `--hold-ms` simulates the legacy pedestal) and measures
  # monotonic time from the case start to the first delivery of this external_id.
  #
  # The hold is ONCE, before the first message — it is the pedestal the customer
  # felt, and `start` is the measurement's reference, so a 3-message case must
  # not accumulate the pedestal per message (that inflated the buffered baseline
  # N× and made the before/after look better than it is).
  def measure_case(c, receiver, url, token, hold_ms)
    id = c["id"]
    external_id = c["external_id"]
    start = monotonic_now
    sleep(hold_ms / 1000.0) if hold_ms.positive?

    c["messages"].sort_by { |m| m["at_ms"].to_i }.each do |m|
      sleep_until(start + (m["at_ms"].to_i / 1000.0))
      post_message(url, token, agent: c["agent"], external_id: external_id, message: m["text"])
    end

    first = nil
    300.times do
      times = receiver.delivery_times(external_id)
      unless times.empty?
        first = ((times.min - start) * 1000).round(2)
        break
      end
      sleep 0.05
    end

    { id: id, agent: c["agent"], external_id: external_id,
      first_balloon_ms: first, balloons: receiver.delivery_count(external_id) }
  end

  def sleep_until(monotonic_target)
    delay = monotonic_target - monotonic_now
    sleep(delay) if delay.positive?
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Outbound POST to the relay's inbound route.
  def post_message(url, token, payload)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 10
    req = Net::HTTP::Post.new(uri.path.empty? ? "/" : uri.path)
    req["Authorization"] = "Bearer #{token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(payload)
    http.request(req)
  end

  # Local deliver_url: receives the engine's delivery POSTs and records the
  # monotonic arrival clock per external_id.
  class DeliverReceiver
    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @mutex = Mutex.new
      @deliveries = []
      @thread = Thread.new { accept_loop }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    # Ascending arrival times (monotonic) for one external_id.
    def delivery_times(external_id)
      @mutex.synchronize do
        @deliveries.select { |d| d[:external_id] == external_id }.map { |d| d[:at] }
      end
    end

    def delivery_count(external_id) = delivery_times(external_id).size

    def close
      @server.close rescue nil
      @thread.join(1)
    end

    private

    def accept_loop
      loop do
        sock = @server.accept
        Thread.new(sock) { |s| handle(s) }
      end
    rescue IOError, Errno::EBADF
      nil # the server was closed
    end

    def handle(sock)
      return unless sock.gets.to_s.start_with?("POST")

      content_length = 0
      while (line = sock.gets)
        break if line == "\r\n" || line == "\n"

        content_length = Regexp.last_match(1).to_i if line =~ /content-length: (\d+)/i
      end
      body = content_length.positive? ? sock.read(content_length) : "{}"
      payload = JSON.parse(body.to_s)
      @mutex.synchronize do
        @deliveries << { external_id: payload["external_id"],
                         at: ReplayLatency.monotonic_now }
      end
      sock.write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" \
                 "content-length: 2\r\nconnection: close\r\n\r\n{}")
    rescue StandardError
      nil
    ensure
      begin
        sock.close
      rescue IOError
        nil
      end
    end
  end
end

# -- CLI ---------------------------------------------------------------------

def parse_args(argv)
  options = { url: nil, token: nil, corpus: nil, out: "report.json", hold_ms: 0 }
  parser = OptionParser.new do |opts|
    opts.banner = "usage: replay_latency.rb --url URL --token TOKEN --corpus FILE [--out FILE] [--hold-ms MS]"
    opts.on("--url URL", "the relay inbound route (e.g. https://staging/channels/relay/events)") { |v| options[:url] = v }
    opts.on("--token TOKEN", "the relay inbound bearer") { |v| options[:token] = v }
    opts.on("--corpus FILE", "conversations JSON (techspec §8 corpus shape)") { |v| options[:corpus] = v }
    opts.on("--out FILE", "report destination (default report.json)") { |v| options[:out] = v }
    opts.on("--hold-ms MS", Integer, "simulated pre-batch pedestal, for the buffered baseline") { |v| options[:hold_ms] = v }
  end
  parser.parse(argv)
  missing = %w[url token corpus].select { |k| options[k.to_sym].to_s.empty? }
  if missing.any?
    warn "missing required option(s): #{missing.join(', ')}"
    warn parser.banner
    exit 1
  end
  options
end

if __FILE__ == $PROGRAM_NAME
  options = parse_args(ARGV)
  corpus = ReplayLatency.parse_corpus(File.read(options[:corpus]))
  ReplayLatency.run(url: options[:url], token: options[:token], corpus: corpus,
                    out: options[:out], hold_ms: options[:hold_ms])
  # Exit 0 always — measurement over gate.
end