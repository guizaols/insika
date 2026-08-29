---
title: Releasing
parent: Ship it
nav_order: 5
permalink: /releasing/
---

# Releasing

How an `insika` gem release is cut, and how the install is **proven** before the
push. The rule that matters: a green suite is not a green gem —
the suite resolves everything by path, so the entire class of packaging failure
is invisible to it. Do not publish on rspec alone.

## Before anything

1. The suite is green: `bundle exec rspec`.
2. `lib/insika/version.rb` carries the version being published.
3. Every new `lib/` file is **tracked in git**. The gemspec's `files` come from
   `git ls-files`: an untracked file builds without a warning and the installed
   gem fails at `require` — this is exactly the failure this proof exists to catch.

## Cut the gem

```bash
gem build insika.gemspec    # -> insika-<version>.gem
```

## Prove the install — from OUTSIDE the repo

Install into a clean gem home and run the four shapes from a directory that is
not the checkout, with the repo's `lib/` nowhere on the load path:

```bash
T=$(mktemp -d)
gem install --install-dir "$T/gemhome" insika-<version>.gem
cd "$T"

# 1. reply in-process
GEM_HOME="$T/gemhome" GEM_PATH="$T/gemhome" ruby -e '
  require "insika"
  agent = Insika.agent("assistant") { model "deepseek-v4-flash"; provider :deepseek }
  puts agent.reply("hi")'                                   # needs DEEPSEEK_API_KEY

# 2. serve  — /studio login 200, /v1/responses streams, /start.md 200
# 3. Insika::Server.rack_app mounted under the host's own router (Rack::URLMap)
# 4. Insika.embed(backend: Insika::Stores::SQLite.new(path: "e1.db")) { … }.reply
```

Shapes 2–4 are the ones that fail when a file is missing from the gem (the
Studio's `views/`, `assets/dist/`, the onboarding docs); run all four.

Then the load guard, from the **installed** gem — no test double:

```bash
GEM_HOME="$T/gemhome" GEM_PATH="$T/gemhome" ruby -e '
  require "insika"
  abort "leak" if %w[RubyLLM Roda Falcon SQLite3 OpenTelemetry].any? { |c| Object.const_defined?(c) }
  puts "clean"'
```

### The 1.0 release gate — the clean-install proof

For the 1.0 release the proof above is scripted and its **installed-bytes**
half is asserted by the domain-boundary suite on the artifact, not the
repo. Run the runbook, with a key (the smoke turn is one `reply` through the
installed gem):

```bash
DEEPSEEK_API_KEY=sk-... scripts/install_proof/install_proof.sh   # prints PASS
```

The script builds, installs into a FRESH `GEM_HOME`, asserts `gem contents
insika` carries no `deploy/ packs/ examples/ plugins/ evals/ scripts/ spec/`
path and no demo-persona-name string, and answers one turn from an app dir that follows
only the public docs. Archive the PASS output with the release notes — it is
the 1.0 exit criterion "install proof by the docs alone".

The same gate writes the freeze date: a breaking `/v1` change needs a new
`Insika-Version` entry (server/app.rb), a compatibility branch
and a rewritten `**Frozen as of:**` line in `docs/API.md` — the version-gate
spec pins the two together, and the 1.0 release writes the date at release
time.

Catalog submission checklist: verify the best-of-Agent-Harnesses
catalog size at submission time (161 vs 154 — the counts diverge across the
catalog's own pages) and cite the conformance suite as the `durable` evidence.

## Publish

```bash
gem push insika-<version>.gem
```

Publishing is irreversible in practice — a yanked 0.1.0 is a bad first
impression. The version number is cheap; the name is not. The install proof before
push, and nothing else.
