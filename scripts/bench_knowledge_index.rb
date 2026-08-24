# frozen_string_literal: true

# Insika knowledge-retrieval benchmark — measures Insika::Knowledge::Index::Scan
# in isolation, at a range of concept counts. This is the measurement the
# optional SQLite full-text index (Index::FTS5) is gated on: build it only
# once Scan is shown to actually hurt at the concept counts a real deployment
# reaches, never speculatively. See docs/KNOWLEDGE.md.
#
# Deterministic, in-process, no network, no API key — same discipline as
# scripts/bench.rb: reproducible by anyone with
#
#     bundle exec ruby scripts/bench_knowledge_index.rb
#
# Usage:
#   bundle exec ruby scripts/bench_knowledge_index.rb [options]
#
# Options:
#   --counts N,N,...   concept counts to measure               (default: 50,200,1000,5000)
#   --iterations N     measured searches per count               (default: 500)
#   --warmup N         unmeasured warmup searches per count      (default: 50)
#   --top-k N          top_k passed to #search                   (default: 5)
#   --json             emit the results as JSON (for CI gating)
#   --help             show this help and exit

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require_relative "../lib/insika"

BOOL_FLAGS = %w[json help].freeze
VALUE_FLAGS = %w[counts iterations warmup top-k].freeze

def parse_args(argv)
  args = {}
  i = 0
  while i < argv.length
    tok = argv[i]
    abort "bench_knowledge_index: expected a --flag, got #{tok.inspect}" unless tok.start_with?("--")

    key = tok.sub(/^--/, "")
    nxt = argv[i + 1]
    if BOOL_FLAGS.include?(key)
      args[key] = true
      i += 1
    elsif VALUE_FLAGS.include?(key)
      abort "bench_knowledge_index: --#{key} needs a value" if nxt.nil? || nxt.start_with?("--")

      args[key] = nxt
      i += 2
    else
      abort "bench_knowledge_index: unknown flag --#{key} (see --help)"
    end
  end
  args
end

ARGS = parse_args(ARGV)
COUNTS = (ARGS["counts"] || "50,200,1000,5000").split(",").map(&:to_i)
ITERATIONS = (ARGS["iterations"] || "500").to_i
WARMUP = (ARGS["warmup"] || "50").to_i
TOP_K = (ARGS["top-k"] || "5").to_i
JSON_OUT = ARGS.fetch("json", false)

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Interpolated percentile (same method scripts/bench.rb and scripts/loadtest.rb use).
def pct(sorted, p)
  return 0.0 if sorted.empty?

  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]
  hi = sorted[r.ceil]
  (lo + (hi - lo) * (r - r.floor)).round(3)
end

def stats(samples_us)
  sorted = samples_us.compact.sort
  { p50_us: pct(sorted, 50), p95_us: pct(sorted, 95),
    mean_us: sorted.empty? ? 0.0 : (sorted.sum / sorted.length).round(3),
    max_us: sorted.empty? ? 0.0 : sorted.last.round(3), n: sorted.length }
end

# Synthetic, brand-free concepts — the shape a real store accumulates, not a
# best case: varied names/descriptions/bodies so term matching does real work
# instead of hitting the first candidate every time.
TOPICS = %w[entrega frete devolucao pagamento estoque tamanho garantia
            desconto rastreio cadastro].freeze

def seed(store, count)
  count.times do |i|
    topic = TOPICS[i % TOPICS.length]
    name = "#{topic}-concept-#{i}"
    store.write(
      "bench-agent", name,
      Insika::Knowledge::Concept.render(
        name: name, description: "Sobre #{topic}, caso número #{i}, detalhe adicional aqui",
        type: "fact",
        body: "Corpo completo do conceito #{i} sobre #{topic}. " \
              "Contém texto suficiente para o índice ter que escanear algo real, " \
              "incluindo termos como prazo, cliente, pedido e loja.",
        provenance: "observed", confidence: 0.6, sources: ["sess_#{i}"], occurrences: 1,
        created_at: "2026-08-01T00:00:00Z", updated_at: "2026-08-24T00:00:00Z"
      )
    )
  end
end

QUERY = "qual o prazo de entrega e a garantia desse pedido"

def run_count(count)
  store = Insika::KnowledgeStore.new(store: Insika::Stores::Memory.new)
  seed(store, count)
  index = Insika::Knowledge::Index::Scan.new(store: store)

  WARMUP.times { index.search("bench-agent", query: QUERY, top_k: TOP_K) }

  samples = ITERATIONS.times.map do
    started = mono
    index.search("bench-agent", query: QUERY, top_k: TOP_K)
    (mono - started) * 1_000_000 # microseconds
  end

  stats(samples)
end

results = COUNTS.to_h { |count| [count, run_count(count)] }

if JSON_OUT
  require "json"
  puts JSON.pretty_generate(
    insika_version: Insika::VERSION, iterations: ITERATIONS, top_k: TOP_K,
    results: results.transform_keys(&:to_s)
  )
else
  puts "insika #{Insika::VERSION} · knowledge index benchmark · #{ITERATIONS} iteration(s), top_k=#{TOP_K}"
  puts
  printf("%-10s %10s %10s %10s %10s\n", "concepts", "p50 (µs)", "p95 (µs)", "mean (µs)", "max (µs)")
  results.each do |count, s|
    printf("%-10d %10.1f %10.1f %10.1f %10.1f\n", count, s[:p50_us], s[:p95_us], s[:mean_us], s[:max_us])
  end
  puts
  puts "Reading: Index::FTS5 (the optional SQLite adapter) is worth building only " \
       "once p95 here actually hurts a turn's budget at the concept counts a real deployment " \
       "reaches — never speculatively. See docs/KNOWLEDGE.md."
end
