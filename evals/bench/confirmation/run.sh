#!/usr/bin/env bash
# The customer-confirmation experiment: the SAME deployment, twice, differing only
# in whether create_order is held for the customer's word.
#
#   SMOKE=1 ./run.sh       one cell per scenario per arm, into runs-smoke/ — not
#                          the sample, and never mixed into it
#   ./run.sh               the measured sample: REPS x 7 scenarios x 2 arms
#
# The arms are SEQUENTIAL: ../run.sh resets the shared `insika-bench` compose
# project and its volumes between cells, so two benches cannot run at once.
#
# Arm order alternates between repetitions. A provider that gets slower or dumber
# through the evening would otherwise land entirely on whichever arm always went
# second, and the table would read that as the gate.
set -euo pipefail

cd "$(dirname "$0")"
CONF_DIR="$PWD"
BENCH_DIR="$(cd .. && pwd)"

REPS="${REPS:-20}"
# One upstream for both arms. OpenRouter fronts sixteen for this model and picks
# per request; unpinned, half the difference between two arms could be which
# machine answered. Verified on the wire: a name the model does not have comes
# back "No endpoints found" in a second, which is how we know the field travels.
export BENCH_PROVIDER="${BENCH_PROVIDER:-DeepInfra}"
export BENCH_REASONING="${BENCH_REASONING:-medium}"

if [ "${SMOKE:-0}" = "1" ]; then
  REPS=1
  OUT="${OUT:-$CONF_DIR/runs-smoke}"
  # Its own report file too: a smoke that overwrote REPORT.md would put cells the
  # sample deliberately excludes where the sample's own table belongs.
  REPORT="${BENCH_REPORT:-$CONF_DIR/REPORT-smoke.md}"
else
  OUT="${OUT:-$CONF_DIR/runs}"
  REPORT="${BENCH_REPORT:-$CONF_DIR/REPORT.md}"
fi
mkdir -p "$OUT"

# WHAT PRODUCED THIS SAMPLE. Non-secret by construction: ids and digests, never a
# key. Written before the first cell, so a run that dies half way still says what
# it was running.
manifest="$OUT/manifest.json"
if [ ! -s "$manifest" ]; then
  BENCH_MANIFEST_OUT="$OUT" ruby -rjson -rdigest -e '
    dir = ARGV[0]
    sha = ->(path) { Digest::SHA256.file(path).hexdigest[0, 16] }
    tasks = Dir[File.join(dir, "tasks", "*.yml")].sort
    puts JSON.pretty_generate(
      "at" => Time.now.utc.iso8601,
      "commit" => `git rev-parse HEAD`.strip,
      # The SOURCE tree, not this run's own output. The shell truncates
      # manifest.json into the (untracked) OUT directory before this block runs,
      # so a bare `git status` reports every cut as dirty and the flag stops
      # meaning anything. Paths under OUT are excluded; nothing else is.
      "dirty" => begin
        out = File.expand_path(ENV.fetch("BENCH_MANIFEST_OUT", dir))
        root = `git rev-parse --show-toplevel`.strip
        `git status --porcelain`.lines.reject { |l|
          File.expand_path(File.join(root, l[3..].to_s.strip.split(" -> ").last)).start_with?(out)
        }.any?
      end,
      "image" => `docker images -q insika-bench-insika:local`.strip,
      "store_image" => `docker images -q insika-bench-store:1.0.0`.strip,
      "model" => ENV["BENCH_MODEL"], "provider" => ENV["BENCH_PROVIDER"],
      "reasoning" => ENV["BENCH_REASONING"], "scorecard" => "B", "reps" => ENV["REPS"],
      "prompt_sha256" => sha.call(File.join(dir, "..", "prompt", "AGENTS.md")),
      "seed_sha256" => sha.call(File.join(dir, "..", "seed", "store.json")),
      "tasks_sha256" => tasks.to_h { |t| [File.basename(t, ".yml"), sha.call(t)] }
    )
  ' "$CONF_DIR" > "$manifest"
  echo "manifest: $manifest"
fi

for rep in $(seq 1 "$REPS"); do
  # ARMS names the arms to run, for a re-measurement that can only touch one of
  # them (the held instruction does not exist when the hold is off). Unset = both,
  # alternating.
  if [ -n "${ARMS:-}" ]; then arms="$ARMS"
  elif [ $((rep % 2)) -eq 1 ]; then arms="true false"; else arms="false true"; fi
  for arm in $arms; do
    root="$OUT/rep$rep/confirmation-$arm"
    echo "=== repetition $rep | confirmation=$arm"
    # Each repetition gets its own root: ../run.sh skips a cell whose report JSON
    # is already on disk, and one shared root would let repetition 2 "resume"
    # repetition 1's cells — a sample of one, reported as twenty.
    HARNESSES=insika SCORECARD=B ROUNDS=1 \
      TASKS_DIR="$CONF_DIR/tasks" \
      BENCH_B_CONFIRMATION="$arm" \
      RUNS_ROOT="$root" BENCH_REPORT="$root/REPORT.md" \
      bash "$BENCH_DIR/run.sh"
  done
done

ruby "$CONF_DIR/report.rb" --runs "$OUT" --out "$REPORT"
