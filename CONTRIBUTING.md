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

See [docs/RUNNING-LOCAL.md](docs/RUNNING-LOCAL.md). Writing a **store backend** (an
`insika-pg` of your own) starts at `lib/insika/testing/store_contract.rb`: require it
from your gem's suite and pass both shared-example groups — the universal one, and the
multi-worker one if the backend is meant to sit under `WEB_CONCURRENCY > 1`. Front-end
work on the Studio additionally needs Node — `assets/dist/` is checked in precisely so
that running the server does not:

```bash
cd lib/insika/studio && npm install && npm run build && npm test
```

## What a good pull request looks like

- **One concern.** A rename, a fix, or a feature — not all three.
- **Specs alongside the code.** `spec/` mirrors `lib/`; 170+ spec files already show
  the shape. New behaviour without a spec will be asked for one.
- **Green suite.** `bundle exec rspec` before you push; `npm test` too if you touched
  `lib/insika/studio/assets/src/`.
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
  primitives already cover. Runtime dependencies live in `insika.gemspec` (the
  `Gemfile` consumes them via `gemspec`), each with a comment saying what needs it —
  keep that boundary true. Front-end additions are held to the same bar (the Studio's
  test layer is plain `node --test`, zero new deps).
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

Public docs live in `docs/*.md`. The same files are three things at once: what GitHub
renders, what a running instance serves at `GET /docs/<name>.md`, and the pages of the
site at [guizaols.github.io/insika](https://guizaols.github.io/insika/). One source, no
copies. `docs/internal/` is not part of the repo.

`docs/` is also the Jekyll site root ([Just the Docs](https://just-the-docs.com), built
by `.github/workflows/pages.yml`). To preview:

```bash
cd docs && bundle install && bundle exec jekyll serve --livereload
```

Two rules when adding or moving a doc: give it the small frontmatter block the sidebar
needs (`title` / `parent` / `nav_order` / `permalink` — copy a neighbour, keep the
permalink equal to the `/docs/<slug>.md` slug), and add it to
`Insika::Onboarding::PUBLIC_DOCS` so the API serves it too. The frontmatter is stripped
before it reaches `GET /docs/<name>.md`, and a spec proves it. Links between docs stay
**relative** (`[Tools](TOOLS.md)`) so they work in all three places; anything outside
`docs/` — `examples/`, the README — needs an absolute GitHub URL, since the site root is
`docs/`.

## Reporting

- **Bugs / features** — a GitHub issue. For a bug, include the Ruby version, what you
  configured (redact keys), what you expected, and what happened. A failing spec is
  the best possible report.
- **Security vulnerabilities** — *not* an issue. See [SECURITY.md](SECURITY.md).

## Licensing

The project is MIT ([LICENSE](LICENSE)). By opening a pull request you agree that your
contribution is licensed under the same terms. There is no CLA.
