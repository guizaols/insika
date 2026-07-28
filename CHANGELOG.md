# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
it is released. Entries land with the pull request that makes the change.

## [Unreleased]

Nothing has been released yet — `Insika::VERSION` is `0.1.0` and no version is tagged.
Everything below is what the first release will contain.

### Added

- **Turn pipeline** — a durable, resumable turn: command bus → context builder → policy
  engine → middleware → executor tool-loop → event stream. Every turn checkpoints, so a
  crash resumes without repeating side-effects.
- **Drop-in HTTP API** — `POST /v1/responses` speaking the OpenAI-Responses shape, with
  SSE streaming and usage, plus an `/a2a` surface. One deployment serves many agents;
  the `model` field is the agent id.
- **Agents as data** — an immutable `AgentProfile` stored as a row, created and edited
  at runtime via the DSL, `POST /v1/agents` (pack import), or the Studio. Every edit is
  hot; an in-flight turn keeps the profile it started with.
- **`Insika.agent { … }` DSL** — thin sugar that *generates* the same provisioning pack
  the API and UI produce. `reply` for one in-process turn, `serve` for the server.
- **Tools** — code tools, tools defined as data (declarative HTTP manifests), and MCP
  import, all behind a tool envelope with timeouts and optional human approval.
- **Skills** — the `SKILL.md` format with progressive loading, so an agent's context
  grows only when it needs to.
- **Memory** — cross-session facts and notes, per agent.
- **Guardrails** — opt-in, per-agent content safety on input and output:
  prompt-injection detection, PII/secret redaction, abuse moderation.
- **Sandbox** — a confined-execution primitive for code that must run somewhere.
- **Egress guard** — bounds which hosts a tool can reach (the SSRF boundary).
- **Edge limits** — per-session rate limits and a per-agent token ceiling that halt a
  flood before it costs an LLM call, backed by a usage ledger.
- **Subagents** — bounded fan-out delegation with a concurrency cap, and workflows
  exposed over the API.
- **Studio** — a web control UI for agents, prompts, skills, tools, sessions, tasks,
  approvals, and settings, with live transcripts over SSE.
- **LLM-first onboarding** — `GET /start.md`, `GET /models.json`, and `GET /docs/*.md`,
  so a coding agent can set up the first agent by reading a running instance.
- **Observability** — an event stream and per-session tool-call traces always on, plus
  opt-in OpenTelemetry traces *and* metrics under a documented, vendor-neutral attribute
  convention with an operator-declared pricing table for estimated cost.
- **Operations** — SQLite (or in-memory) stores, Falcon on the Async fiber scheduler,
  strict configuration validation with a `doctor` check, and a provider-free benchmark
  that measures engine overhead alone.
- **Documentation site** — the `docs/*.md` files are also a Jekyll (Just the Docs) site
  published at <https://guizaols.github.io/insika/>. Same files, no copy: what GitHub
  renders, what `GET /docs/<name>.md` serves, and what the site publishes are one source.

### Changed

- `GET /docs/<name>.md` strips the docs-site frontmatter, so the raw markdown a coding
  agent receives is the prose only.

### Fixed

- **An agent's inline identity now reaches the model.** `base_prompt` — what the DSL's
  `instructions` and a pack manifest set — was stored, round-tripped and advertised on
  the A2A agent card, but never injected into the system prompt: every composition root
  wires the prompt provider with `base: ""`, so an agent whose identity was inline ran
  with *no* identity. Agents whose identity comes from `prompt_files` (the production
  path) were unaffected.
- **`max_tokens` now reaches the provider.** The agent param was authored in the DSL,
  the Studio and a pack, resolved onto the turn — and then sent to the chat as
  `with_max_output_tokens`, a method no version of `ruby_llm` has. Guarded by
  `respond_to?`, it was skipped in silence, so an agent with a token ceiling ran without
  one. It now rides `with_params(max_tokens:)`, merged into a single call with the
  reasoning toggle (`with_params` replaces the gem's whole params hash, so two calls
  would drop the first one's keys).
- **A data-tool whose API moved now says so.** A 3xx counted as success, and since
  servers send a redirect with an empty body, the model received `""` and narrated a
  plausible outage. The HTTP client still does not follow the hop — the egress guard
  cleared the authored URL, not the redirect's destination — but the tool now returns
  `HTTP 301: moved to <url>`, which names the definition to fix. This is what broke
  `examples/data-tool/currency_agent.rb` (its endpoint moved host).
