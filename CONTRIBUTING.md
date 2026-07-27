# Contributing

Thanks for looking. Insika is pre-release: the public surface still moves, so the
most valuable contributions right now are **bug reports with a reproduction** and
**small, focused pull requests**.

## Setup

```bash
bundle install
bundle exec rspec          # the whole suite, no API key, no network
```

The suite needs no provider key: every LLM call is behind a seam (`Executor#create_chat`)
that the tests replace with a fake chat. If a change of yours only passes with a real
key, that is a design smell — move the boundary, don't add the key.

Running the thing itself needs Ruby `>= 3.3` (`4.0.6` is pinned in `.ruby-version`)
and one provider key:

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb --serve   # :9292 → /studio
```

See [docs/RUNNING-LOCAL.md](docs/RUNNING-LOCAL.md). Front-end work on the Studio
additionally needs Node — `assets/dist/` is checked in precisely so that running the
server does not:

```bash
cd studio && npm install && npm run build && npm test
```

## What a good pull request looks like

- **One concern.** A rename, a fix, or a feature — not all three.
- **Specs alongside the code.** `spec/` mirrors `lib/`; 170+ spec files already show
  the shape. New behaviour without a spec will be asked for one.
- **Green suite.** `bundle exec rspec` before you push; `npm test` too if you touched
  `studio/assets/src/`.
- **A conventional commit**, matching the history: `feat(scope): …`, `fix(scope): …`,
  `refactor(scope): …`, `docs(scope): …`.
- **Rebased on `main`.** Branch off `main`, PRs are squash-merged.
- **Docs updated in the same PR** when the change is user-visible. A feature nobody
  can find is not shipped.

## House rules

These are not style preferences — they are how the engine stays small.

- **Config over code.** A capability should be expressible as *data* (a pack, an
  `AgentProfile` field, a manifest) before it is expressible as a subclass. The DSL
  is sugar that generates that data; it is never a second code path.
- **Don't add a dependency** to solve something the standard library or the existing
  primitives already cover. Every gem in the `Gemfile` carries a comment saying which
  future package owns it — keep that boundary true. Front-end additions are held to
  the same bar (the Studio's test layer is plain `node --test`, zero new deps).
- **The core does not require `ruby_llm` at load time.** It is required lazily, and
  `spec/insika/load_guard_spec.rb` proves it. Same for OpenTelemetry.
- **String keys at the persistence boundary.** Stores hold JSON, which has no Symbols.
  Build profiles through `AgentProfile.build` rather than teaching a reader to accept
  both spellings.
- **`Insika::Coercion` is the single home** for `presence` / `blank?` / `present?` /
  `utf8` / `deep_stringify`. Don't re-implement them locally.
- **Bytes from outside the engine get `Coercion.utf8`** at the boundary — sockets,
  pipes, subprocesses. Untagged bytes break `JSON.generate` the first time a user
  types an accent.
- **Secrets live in the environment only.** Never on disk, never in a store, never in
  a prompt. New environment variables are registered in `lib/insika/env_schema.rb`.
- **All documentation is in English**, including comments — the repo has one language
  so a reader never hits a wall. (The deliberate exceptions are content that *is*
  data: the bilingual safety suite, the eval corpus, and demo fixtures.)

## Documentation

Public docs live in `docs/*.md` and are served by a running instance at
`GET /docs/<name>.md`, so they are both the website source and an agent-readable
surface. One source, no copies. `docs/internal/` is not part of the repo.

## Reporting

- **Bugs / features** — a GitHub issue. For a bug, include the Ruby version, what you
  configured (redact keys), what you expected, and what happened. A failing spec is
  the best possible report.
- **Security vulnerabilities** — *not* an issue. See [SECURITY.md](SECURITY.md).

## Licensing

The project is MIT ([LICENSE](LICENSE)). By opening a pull request you agree that your
contribution is licensed under the same terms. There is no CLA.
