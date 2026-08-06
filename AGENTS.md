# AGENTS.md

Instructions for AI coding agents working **on this repository**.

> Not to be confused with [docs/AGENTS.md](docs/AGENTS.md), which documents the
> *product* concept — how a user of Insika creates and configures an agent.

## What this is

Insika is a Ruby runtime for LLM agents in production: a durable, resumable turn
pipeline behind an OpenAI-Responses-compatible HTTP API, plus a web control UI. Plain
Ruby — no Rails, no ActiveRecord. Stores are SQLite (or in-memory for tests). The
server runs on Falcon over the Async fiber scheduler.

Read in this order before changing anything non-trivial:
[README.md](README.md) → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) →
[CONTRIBUTING.md](CONTRIBUTING.md) (the house rules are binding).

## Commands

```bash
bundle exec rspec                     # whole suite — no API key, no network
bundle exec rspec spec/insika/foo_spec.rb
bin/insika doctor                     # validate configuration
bin/insika env                        # the registered environment schema

DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb --serve   # :9292 → /studio

cd studio && npm install && npm run build && npm test          # front-end only
```

There is no linter configured — no `.rubocop.yml`, no rubocop in the `Gemfile`. Match
the surrounding style instead of running a formatter.

## Layout

| Path | What |
|------|------|
| `lib/insika/` | the engine (executor, stores, policy, context, tools, safety, sandbox, telemetry, DSL) |
| `lib/insika/wiring/graph.rb` | the composition root — where objects get assembled |
| `server/` | HTTP/SSE transport only (`/v1`, `/a2a`); no business logic |
| `studio/` | the control UI (Roda + ERB, Stimulus/Turbo); `assets/dist/` is **checked in** |
| `config/` | `deployment.rb`, `wiring.rb` — the real deployment's wiring |
| `plugins/`, `examples/`, `scripts/`, `evals/` | plugins (manifest + entry — see `docs/PLUGINS.md`), runnable examples, operator scripts, the eval CORPUS + `run.rb` CLI (the harness itself is `lib/insika/evals/*`) |
| `spec/` | mirrors `lib/`; 170+ spec files |
| `docs/` | public docs — one source read three ways: GitHub, `GET /docs/<name>.md`, and the Jekyll site rooted here (`docs/_config.yml`) |

## Rules that bite

- **Specs are not optional.** New behaviour ships with a spec in the mirrored path.
  The suite must be green before you claim done.
- **No new dependency** without a strong reason; every gem in the `Gemfile` has a
  comment naming the future package that owns it.
- **The core must load without `ruby_llm` or OpenTelemetry.** Both are required lazily;
  `spec/insika/load_guard_spec.rb` enforces it. A top-level `require` of either will
  fail that spec.
- **Config over code** — new capability arrives as data on the `AgentProfile`/pack
  first. The DSL only generates that data; it is never a parallel code path.
- **String keys** at the persistence boundary (stores hold JSON). Build profiles via
  `AgentProfile.build`; do not teach readers to accept both spellings.
- **`Insika::Coercion`** owns `presence` / `blank?` / `present?` / `utf8` /
  `deep_stringify`. Tag bytes from outside the engine with `Coercion.utf8`.
- **New env vars** are registered in `lib/insika/env_schema.rb`, or `doctor` and
  strict-config validation will not know about them.
- **Everything in the repo is written in English**, comments included. Exceptions are
  content that is data: the bilingual safety suite, the eval corpus, demo fixtures.
- **Secrets never leave the environment** — not into a store, a prompt, an event, or a
  log.

## Gotchas

- `docs/internal/`, `docs/FOLLOWUP.md`, `docs/README.md`, `docs/techspec/` and
  `spec/scripts/` are **gitignored** working material. Edits there are local by design
  and will not show in `git status` — do not try to commit them, and do not assume a
  reader of the public repo can see them.
- `studio/assets/dist/` **is** committed so `serve` runs without Node. If you touch
  `assets/src/`, rebuild and commit the bundle.
- A `docs/*.md` file is simultaneously a Jekyll page, so it starts with a frontmatter
  block. `Insika::Onboarding#doc` strips it — keep that true. Links between docs must
  stay relative; a link to anything outside `docs/` needs an absolute GitHub URL.
  `docs/` has its own `Gemfile` (Jekyll only); the root `bundle install` never sees it.
- The `Dockerfile` pins `INSIKA_DB=/data/harness.db` — that filename is real data on a
  live volume. Renaming it boots an empty database. Rename the variable spelling if you
  must; leave the path alone.
- Environment variables are `INSIKA_*`. The old `HARNESS_*` spellings are read as a
  deprecated fallback only; never document or add one.
- Commits are conventional (`feat(scope): …`), branches come off `main`, PRs are
  squash-merged.
