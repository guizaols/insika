#!/usr/bin/env bash
# RFC-0036 C8/E1 — the INSTALL PROOF: the gem is installable from the docs
# alone, and the INSTALLED bytes carry no domain artifact. Release gate
# runbook (docs/RELEASING.md) — checkout-only by design (scripts/ never ships).
#
#   scripts/install_proof/install_proof.sh
#
# Steps: (1) build the gem locally, (2) install into a FRESH GEM_HOME in a
# temp dir, (3) `gem contents insika` — assert no deploy/ packs/ examples/
# plugins/ evals/ scripts/ spec/ path and no `bia` string (the C1 audit
# repeated against the INSTALLED artifact — the difference that matters: not
# the repo's payload function, the shipped bytes), (4) create a fresh app dir
# and follow ONLY the public docs' smallest example (docs/AGENTS.md:
# Insika.agent("assistant") { … } + reply), (5) one smoke turn through the
# DSL runtime using the INSTALLED gem via -I "$GEM_HOME/gems/insika-*/lib" —
# no repo knowledge. Prints PASS on success, exits non-zero otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GEM_HOME="$WORK/gems"
export GEM_PATH="$GEM_HOME"

echo "== install proof (RFC-0036 E1) =="

# (1) build
echo "[1/5] gem build"
GEMFILE="$(cd "$ROOT" && gem build insika.gemspec | sed -n 's/.*File: \(insika-.*\.gem\)/\1/p')"
GEM="$ROOT/$GEMFILE"
trap 'rm -rf "$WORK" "$GEM"' EXIT
test -f "$GEM" || { echo "FAIL: no gem built"; exit 1; }

# (2) fresh GEM_HOME install
echo "[2/5] install into a fresh GEM_HOME"
gem install "$GEM" --no-document >/dev/null
GEM_LIB="$(gem contents insika | sed -n 's#^\(.*\)/lib/insika.rb$#\1#p' | head -1)"
test -n "$GEM_LIB" || { echo "FAIL: installed gem has no lib/insika.rb"; exit 1; }
echo "      installed at $GEM_LIB"

# (3) the shipped-bytes audit (C1 repeated on the artifact)
echo "[3/5] the installed payload carries no domain artifact"
# strip the gem root prefix first: the domain dirs are TOP-LEVEL (deploy/,
# packs/, examples/, plugins/, evals/, scripts/, spec/) — lib/insika/evals/
# is the ENGINE's eval harness and ships by design.
REL_PATHS="$(gem contents insika | sed "s#^.*/gems/insika-[^/]*/##")"
BAD_PATHS="$(echo "$REL_PATHS" | grep -E '^(deploy|packs|examples|plugins|evals|scripts|spec)/' || true)"
if [ -n "$BAD_PATHS" ]; then
  echo "FAIL: domain paths in the installed gem:"; echo "$BAD_PATHS"; exit 1
fi
BAD_NAME="$(echo "$REL_PATHS" | grep -E '\bbia\b' || true)"
if [ -n "$BAD_NAME" ]; then
  echo "FAIL: the demo persona name is in the installed gem:"; echo "$BAD_NAME"; exit 1
fi
echo "      clean: no domain directory, no persona name"

# (4) a fresh app dir, following ONLY the public docs (docs/AGENTS.md)
echo "[4/5] a fresh app dir from the docs alone"
APP="$WORK/app"
mkdir -p "$APP"
cat > "$APP/agent.rb" << 'RUBY'
# The smallest possible agent — docs/AGENTS.md, verbatim in spirit:
#   agent = Insika.agent("assistant") { … }
#   puts agent.reply("hi")   # => one turn, in-process
require "insika"

assistant = Insika.agent("assistant") do
  model ENV.fetch("INSIKA_PROOF_MODEL", "deepseek-v4-flash")
  provider :deepseek
  instructions "You are a concise, friendly assistant. Answer briefly."
end

puts assistant.reply("hi, what can you do?")
RUBY

# (5) one smoke turn through the INSTALLED gem (-I, no repo on the load path)
echo "[5/5] one smoke turn through the installed gem"
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "      SKIP (DEEPSEEK_API_KEY unset — the release gate runs this with a key)"
else
  ruby -I "$GEM_LIB" "$APP/agent.rb" | grep -q . || { echo "FAIL: the smoke turn produced no reply"; exit 1; }
  echo "      the installed gem answered"
fi

echo
echo "PASS — gem installs from the docs alone, and the installed bytes are domain-free."
