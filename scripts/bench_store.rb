# frozen_string_literal: true

# Micro-bench do TETO DE ESCRITA do Stores::SQLite sob N PROCESSOS.
# Isola a pergunta "SQLite aguenta multi-proc?" do ruído do provider LLM: mede
# a contenção de escrita crua contra o MESMO arquivo (WAL + busy_timeout +
# BEGIN IMMEDIATE + semáforo in-process — a config real de produção do harness).
#
# Cada processo abre seu próprio handle no MESMO db e faz M transações de escrita
# (INSERT OR REPLACE, chaves disjuntas → mede serialização de escrita do WAL, que
# permite só 1 escritor por vez no arquivo). Reporta, por nº de processos:
# throughput agregado (writes/s), latência p50/p95/max e erros "database is
# locked" (esperado ~0 graças ao busy_timeout; a contenção vira latência, não erro).
#
# Uso:
#   bundle exec ruby scripts/bench_store.rb [PROCS_CSV] [WRITES_POR_PROC]
#   ex.: bundle exec ruby scripts/bench_store.rb 1,2,4,8 2000
#
# Não toca no seu HARNESS_DB — usa um arquivo temporário isolado por rodada.

require_relative "../lib/harness"
require "async"
require "json"
require "tmpdir"
require "fileutils"

PROCS = (ARGV[0] || "1,2,4,8").split(",").map { |n| Integer(n.strip) }
WRITES = Integer(ARGV[1] || "2000")            # escritas por processo
# Payload ~ um record típico (session/checkpoint): algumas centenas de bytes.
PAYLOAD = {
  "messages" => Array.new(6) { { "role" => "user", "content" => "mensagem de exemplo com algum texto" } },
  "vars" => { "channel" => "bench", "store_id" => "loja-x" },
  "updated_at" => "2026-07-16T00:00:00Z"
}.freeze

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def percentile(sorted, pct)
  return 0.0 if sorted.empty?

  rank = (pct / 100.0) * (sorted.length - 1)
  lo = sorted[rank.floor]
  hi = sorted[rank.ceil]
  (lo + (hi - lo) * (rank - rank.floor)).round(3)
end

# Roda `procs` processos escrevendo WRITES cada no db compartilhado. -> métricas.
def run_round(procs, db_path)
  result_dir = Dir.mktmpdir("bench-res")
  # Pré-inicializa o arquivo (DDL + WAL) no PAI: evita a corrida de N filhos
  # rodando CREATE TABLE / PRAGMA WAL concorrentes num db recém-criado.
  Harness::Stores::SQLite.new(path: db_path).close

  started = mono

  pids = procs.times.map do |p|
    Process.fork do
      store = Harness::Stores::SQLite.new(path: db_path)
      lats = []
      locked = 0
      Sync do
        WRITES.times do |i|
          t0 = mono
          begin
            store.set("bench", "p#{p}-#{i}", PAYLOAD)
            lats << (mono - t0) * 1000.0            # ms
          rescue Harness::StoreError => e
            locked += 1 if e.message =~ /lock|busy/i
          end
        end
      end
      store.close
      File.write(File.join(result_dir, "#{p}.json"),
                 JSON.generate("count" => lats.length, "locked" => locked, "lats" => lats))
    end
  end
  pids.each { |pid| Process.wait(pid) }

  wall = mono - started
  lats = []
  count = 0
  locked = 0
  Dir[File.join(result_dir, "*.json")].each do |f|
    r = JSON.parse(File.read(f))
    count += r["count"]
    locked += r["locked"]
    lats.concat(r["lats"])
  end
  lats.sort!
  { procs: procs, wall: wall, count: count, locked: locked,
    throughput: (count / wall).round(0),
    p50: percentile(lats, 50), p95: percentile(lats, 95), max: (lats.last || 0).round(3) }
ensure
  FileUtils.remove_entry(result_dir) if result_dir && Dir.exist?(result_dir)
end

puts "bench SQLite (WAL) — #{WRITES} escritas/proc, payload ~#{PAYLOAD.to_json.bytesize}B"
puts format("%-6s %10s %12s %10s %10s %10s %8s", "procs", "wall(s)", "writes/s", "p50(ms)", "p95(ms)", "max(ms)", "locked")
puts "-" * 74

PROCS.each do |n|
  Dir.mktmpdir("bench-db") do |dir|
    db = File.join(dir, "bench.db")
    m = run_round(n, db)
    puts format("%-6d %10.2f %12d %10.2f %10.2f %10.2f %8d",
                m[:procs], m[:wall], m[:throughput], m[:p50], m[:p95], m[:max], m[:locked])
  end
end
