# frozen_string_literal: true

# Load-test do harness — bate DIRETO em POST /v1/responses (o caminho de produção:
# achei-b2b/WhatsApp -> motor). Equivalente Ruby do loadtest-gateway.mjs do
# OpenClaw; como o contrato SSE é o MESMO, dá pra comparar apples-to-apples
# harness vs gateway.
#
# Mede, por turno: TTFB (tempo até o 1º byte SSE), total, e o `usage` (tokens +
# cache hit) do último frame com usage. Dispara N turnos concorrentes espalhados
# nos agentes informados. Saída: P50/P95 de TTFB e total, tokens médios, taxa de
# cache hit e taxa de erro. Só stdlib.
#
# Uso:
#   HARNESS_URL=http://localhost:9292 \
#   OPENCLAW_GATEWAY_TOKEN=xxx \
#   bundle exec ruby scripts/loadtest.rb \
#     --agents bia,agent-store-cacau-show --concurrency 16 --iterations 3 \
#     --message "oi, tudo bem?"
#
#   --ports 9292,9293  distribui round-robin entre vários processos locais.
#   --same-user 1      reusa o mesmo user por agente (mede cache de conversa quente).

require "net/http"
require "uri"
require "json"

args = {}
ARGV.each_slice(2) { |k, v| args[k.sub(/^--/, "")] = v if k&.start_with?("--") }

TOKEN = ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo"
base = (ENV["HARNESS_URL"] || "http://localhost:9292").sub(%r{/$}, "")
BASE_URLS = (args["ports"] ? args["ports"].split(",").map { |p| "http://localhost:#{p.strip}" } : [base])
AGENTS = (args["agents"] || "bia").split(",").map(&:strip).reject(&:empty?)
CONC = Integer(args["concurrency"] || "8")
ITERS = Integer(args["iterations"] || "1")
MESSAGE = args["message"] || "oi, tudo bem?"
TIMEOUT = Integer(args["timeout"] || "120")
SAME_USER = args["same-user"] && args["same-user"] != "false"

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Um turno: POST streaming; mede TTFB/total; extrai o último JSON com `usage`.
def run_turn(base_url, agent, idx)
  user = SAME_USER ? "loadtest-#{agent}" : "loadtest-#{agent}-#{idx}"
  uri = URI.join(base_url + "/", "v1/responses")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"] = "application/json"
  req["Accept"] = "text/event-stream"
  req.body = JSON.generate(model: "openclaw:#{agent}", user: user, stream: true, input: MESSAGE)

  t0 = mono
  ttfb = nil
  usage = nil
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.read_timeout = TIMEOUT
  http.open_timeout = 10

  status = nil
  http.start do
    http.request(req) do |res|
      status = res.code.to_i
      return { ok: false, status: status } unless status.between?(200, 299)

      buffer = +""
      res.read_body do |chunk|
        ttfb ||= mono - t0
        buffer << chunk
        # Frames SSE: "data: {json}\n\n". Guarda o último usage visto.
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
            rescue JSON::ParserError
              nil
            end
          end
        end
      end
    end
  end
  { ok: true, status: status, ttfb: (ttfb || (mono - t0)) * 1000.0, total: (mono - t0) * 1000.0, usage: usage }
rescue StandardError => e
  { ok: false, error: e.class.to_s }
end

def pct(sorted, p)
  return 0.0 if sorted.empty?

  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]; hi = sorted[r.ceil]
  (lo + (hi - lo) * (r - r.floor)).round(1)
end

total_turns = AGENTS.length * CONC * ITERS
puts "loadtest -> #{BASE_URLS.join(', ')} | agentes=#{AGENTS.join(',')} conc=#{CONC} iters=#{ITERS} turnos=#{total_turns}"

jobs = []
ITERS.times { |it| AGENTS.each { |a| CONC.times { |c| jobs << [a, it * CONC + c] } } }

results = []
mutex = Mutex.new
started = mono
jobs.each_slice(CONC).each_with_index do |batch, wave|
  threads = batch.map.with_index do |(agent, idx), i|
    Thread.new do
      base_url = BASE_URLS[(wave + i) % BASE_URLS.length]   # round-robin de portas
      r = run_turn(base_url, agent, idx)
      mutex.synchronize { results << r }
    end
  end
  threads.each(&:join)
end
wall = mono - started

ok = results.select { |r| r[:ok] }
errs = results.length - ok.length
ttfbs = ok.map { |r| r[:ttfb] }.compact.sort
totals = ok.map { |r| r[:total] }.compact.sort
toks = ok.map { |r| r.dig(:usage, "total_tokens") || r.dig(:usage, "output_tokens") }.compact
cache_hits = ok.map { |r| r.dig(:usage, "prompt_cache_hit_tokens") || r.dig(:usage, "cached_tokens") }.compact

puts "-" * 60
puts "turnos ok:      #{ok.length}/#{results.length}  (erros: #{errs})"
puts "throughput:     #{(ok.length / wall).round(1)} turnos/s  (wall #{wall.round(1)}s)"
puts "TTFB  p50/p95:  #{pct(ttfbs, 50)} / #{pct(ttfbs, 95)} ms"
puts "total p50/p95:  #{pct(totals, 50)} / #{pct(totals, 95)} ms"
puts "tokens médios:  #{toks.empty? ? '-' : (toks.sum.to_f / toks.length).round(0)}"
puts "cache hit médio:#{cache_hits.empty? ? '-' : (cache_hits.sum.to_f / cache_hits.length).round(0)} tokens"
