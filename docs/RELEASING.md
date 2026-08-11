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
  agent = Insika.agent("assistant") { model "deepseek-chat"; provider :deepseek }
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

## Publish

```bash
gem push insika-<version>.gem
```

Publishing is irreversible in practice — a yanked 0.1.0 is a bad first
impression. The version number is cheap; the name is not. The install proof before
push, and nothing else.
