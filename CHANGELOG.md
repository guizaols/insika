# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
it is released. Entries land with the pull request that makes the change.

## [Unreleased]

## [0.1.0] - 2026-08-10

The first release: `gem install insika`.

### Added

- **A publishable core (RFC-0018)** — `gem install insika` gives every shape: `reply`
  in-process, `serve`, `Insika::Server.rack_app` mounted, and `embed(backend:)`. The
  server and the Studio moved under `lib/insika/` and ship in the gem; the exported
  store contract (`lib/insika/testing/store_contract.rb`) is what a third-party
  backend specs against, now with an opt-in multi-worker group that fails a backend
  whose `transaction` yields without isolation.
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
- **Embedding** — `Insika.embed(backend:) { … }` builds a graph that owns its store and
  its LLM credentials, and `Insika::Server.rack_app(graph, token:)` hands you the `/v1`
  transport as a value to mount in your own router. Two graphs in one process no longer
  share a provider key or a database. What the process still owns — signals, the
  reactor, the Studio — is written down in [Embedding](docs/EMBEDDING.md).
- **Tools** — code tools, tools defined as data (declarative HTTP manifests), and MCP
  import, all behind a tool envelope with timeouts and optional human approval.
- **`halt_when`** — a data-tool can end the turn from its own **response**
  (`{ "json_path": "tool_result.status", "equals": ["SUBSCRIBED"] }`), for backends that
  perform the side effect *and* notify the customer themselves: without it the model
  writes a second confirmation and the person gets the message twice. Per result, not
  per tool — the same call still lets the model explain a failure. See
  [Tools](docs/TOOLS.md#halt_when-when-the-answer-is-already-out).
- **Refinement: a gated, reviewable prompt edit** — a refinement run can now carry a
  *proposal*, and the whole design is one sentence: an edit is scored by **running
  it**, and a human approves it before it reaches anyone. The candidate is applied to
  a throwaway clone of the agent, the golden set is replayed against the clone over
  the ordinary `/v1/responses`, and any regression against the accepted baseline
  disqualifies it. Nothing asks a model whether an edit looks good.
  Edits are anchored and bounded (`before` must still match the file, exactly and
  once) so the diff is a five-second decision, the gate's result is attributable, and
  a proposal built from a stale snapshot cannot overwrite something you wrote — the
  apply re-checks every anchor and refuses the whole proposal if anything drifted.
  Approving writes through the versioned file store, so rollback is the Restore
  button that was already there. Opt-in per agent (`refine mode: :propose, files:
  %w[TOOLS.md]`); an agent with no golden cases, with no recorded baseline, or with a
  baseline in which nothing passes, **cannot be edited at all** — the gate refuses
  rather than passing vacuously (a regression is measured against a case that *was*
  passing, so an all-red baseline would wave everything through). See
  [Refinement](docs/REFINEMENT.md#changing-the-agent-the-gate).
- **A panel of proposers, a budget, and an optional unattended apply** — `proposers`
  asks several models the same question and gates every answer independently; the gate
  arbitrates and you are shown the best survivor with the others listed under it.
  Convergence only breaks a tie (two models agreeing on wording is weak evidence; a
  golden case passing is strong evidence), identical candidates are gated once, and a
  model that answers prose or dies takes only itself out of the panel. `budget.tokens`
  bounds what one run may spend across every proposal and every replay — checked before
  each step, never mid-flight, with the candidates it could not afford recorded as such
  and unmetered legs tallied rather than counted as free. `mode: :auto_apply` lets a
  gate-passing edit land with nobody watching: off by default, and when on it still
  needs zero regressions and a diff within `auto_apply_max_edits` (default 1) — a
  larger one waits for a person instead of being thrown away. It reuses the human
  approval path, so the staleness re-check, the versioned write and the undo are the
  same. See [Refinement](docs/REFINEMENT.md#more-than-one-proposer).
- **The gate refuses to grade a judged baseline without a judge** — a rubric'd case
  with no verdict counts as a pass, so replaying without a judge against a baseline
  recorded with one does not measure less, it measures backwards. Found by running the
  panel against the real pilot: the gate reported *6/6, no regression* against a
  baseline the same corpus had just scored *2/6*, and both candidates cleared. With the
  judge configured, the same two candidates were correctly rejected on judge-score
  drops. Third member of the same family as the missing and all-red baseline refusals.
- **The refinement budget counts the prompt cache** — the engine's `total_tokens` is
  input + output and excludes the cached prefix (a 27 KB pack reports `88` total against
  `26624` cached), so a ceiling built on it alone let a run send hundreds of times what
  it said. Cost now bills `total + cached` and records the cached share, which on a real
  panel run was 95% of the spend. A run that cannot be gated is also refused **before**
  the proposal is paid for, not after.
- **The eval baseline is a per-agent record, not only a file** — `evals/baseline.json`
  works from a checkout; the refinement gate runs inside a deployment that has none.
  `insika evals:baseline import|show|export` moves it into the store and back, with
  the file staying the export format. A case the golden store does not know is
  reported rather than guessed at: a silently shrunk baseline is a weaker gate.
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
- **Parallel tool calls** — opt-in via `limits[:tool_concurrency]`, one number that is
  both the switch and the cap on how many of a batch run at once. Off by default, and
  automatically off for any turn holding an approval-required tool (two calls suspended
  for an operator would deadlock on the single per-task mailbox). Documented trade-offs:
  `max_tool_calls` becomes approximate, tool results are recorded in completion order,
  and a turn deadline waits for in-flight calls instead of cancelling them.
- **Message coalescing** — opt-in via `limits[:queue_mode] = "collect"` plus
  `debounce_ms`, so the fragments a person types in a row ("oi" / "queria saber do
  pedido" / "1234567") become one turn instead of three. The quiet window is held on
  the session's own fiber, never on the request, so the caller is still acked
  immediately. `debounce_max_ms` caps the total deferral. Off by default
  (`followup` = one turn per message, today's behavior), resolved session vars →
  agent → platform, where a key set explicitly to `nil`/`0` means *off*, not
  *inherit*. Only offered on surfaces whose response can report
  `{"merged": true}` — a caller that cannot hear that verdict would deliver the same
  answer once per fragment, so `/v1/responses` and open streams are refused rather
  than silently coalesced.
- **Message steering** — opt-in via `limits[:queue_mode] = "steer"`, so a message that
  arrives while the agent is *already running tools* is appended to that run instead of
  waiting for it. It lands at a **tool-batch boundary**, appended at the tail: after the
  last result of a batch and before the model's next step — never between two tool
  results (which Anthropic rejects outright), and never rewriting anything already sent,
  so the prompt cache survives. A steered message is a first-class transcript message
  with no origin, because a person wrote it. Bounded by `steer_max_messages`, worded by
  an optional `steer_join` template. Four cases the run cannot absorb — a turn with no
  tool call, a batch ending in `halt_when`, a workflow run, and overflow past the bound —
  release the message as the next turn on the session rather than losing it. Same
  surface rule as coalescing: only a caller that can hear `{"steered": true}` may steer,
  since the reply belongs to the turn it joined.
- **Message interrupt** — opt-in via `limits[:queue_mode] = "interrupt"`, for the message
  that makes the turn in flight *wrong* ("não, esquece isso"). That turn is abandoned at
  its next boundary and the new message becomes an ordinary turn, with its own `task_id`
  and its own reply — so unlike coalescing and steering it needs no verdict field and
  works on every surface. A tool call in flight still runs to completion and is recorded:
  the batch is one unit of work, and faking failures would teach the model that tools
  failed when they did not.
- **A cancelled turn publishes nothing.** A cancel that arrived while the provider was
  working used to be observed only after the answer had already been streamed, so the
  customer read the reply of a turn that then terminated `:cancelled` and persisted
  nothing — text delivered, transcript silent about it. There is now a boundary between
  the provider's last word and publishing, so the two never disagree. Applies to every
  cancel, not just `interrupt`.
- **Channels** — a way in and out for people, registered by id and mounted on one
  generic route family under `/channels/<id>/`. A channel translates and authenticates,
  and does nothing else: it may refuse a request, never widen one. Plugins register
  their own through `contracts.channels`, and a deployment that registers none has no
  such route at all. See [Channels](docs/CHANNELS.md).
- **The web widget** — one `<script>` tag on a site and the adopter has an agent: a
  bubble, a panel, and the answer streaming in token by token, with no backend of
  theirs, no build step and no npm. It is the channel for a team with *no* messaging
  stack of its own, and the first one where the reply rides the request's own
  connection. Because the caller is an anonymous browser there is no secret to check,
  so three things stand in for one: an exact-match origin allowlist, an agent
  allowlist (a visitor addresses what the operator published and nothing else), and a
  **mandatory chat rate limit** — the widget answers `503` until one is configured,
  which is the only place the engine refuses to serve rather than warn. The engine
  issues session ids and the client never proposes one. See
  [Channels](docs/CHANNELS.md#the-web-widget).
- **The relay channel** — for an adopter who already owns a messaging stack (a WhatsApp
  BSP, a Zendesk, a legacy app) and wants the engine for the **turn**, not the platform.
  You POST the customer's message to `/channels/relay/events`; the engine acks
  immediately and POSTs the answer to your own callback when there is one. Everything
  platform-shaped — the 24-hour window, templates, media, read receipts, WhatsApp
  formatting — stays yours, permanently: this is not a migration step toward a native
  channel. Configured entirely by environment (`INSIKA_RELAY_TOKEN`, which is both the
  switch and the credential, plus the callback URL and its optional bearer), so there is
  no way to expose the route without a secret.
- **At-most-once outbound delivery** — a reply owed to a channel is written durably when
  the turn commits and **claimed** before the HTTP call, so a crash loses a delivery
  rather than duplicating it; bounded retry with backoff handles a recipient that is
  merely down, and boot re-dispatches what was recorded but never claimed. Each attempt
  reports on `:channel_delivered`, because a turn completing says nothing about whether
  the customer received it.
- **Inbound deduplication** — an optional `event_id` on a channel message is remembered
  for 24 hours, so a platform retrying a webhook it already delivered gets
  `{"duplicate": true}` and the same `task_id` back instead of a second LLM turn and a
  second message. No id means at-least-once turns, said out loud rather than papered
  over with a content hash.
- **Studio** — a web control UI for agents, prompts, skills, tools, sessions, tasks,
  approvals, and settings, with live transcripts over SSE.
- **LLM-first onboarding** — `GET /start.md`, `GET /models.json`, and `GET /docs/*.md`,
  so a coding agent can set up the first agent by reading a running instance.
- **Evals** — a small corpus of real conversations, replayed against a running deployment
  and checked two ways: deterministic assertions (was the tool called, did a CPF leak)
  and a **rubric** scored by a judge. Cases are YAML data, authorable in the Studio as
  well as in the repo, and the graders are a **panel of distinct models** with
  configurable aggregation and agreement — sampling one model N times measures its
  variance, not its bias. A baseline turns a run into a pre-merge gate that blocks only
  on regressions. A case can also carry the **incumbent's real conversation** for the
  same opening (`reference:`), and `--pairwise` asks the panel which one served the
  customer better — the question an absolute score cannot answer when you are replacing
  a system that already works. The judge never learns which transcript is Insika's, and
  every judge is asked twice with the sides swapped, so a preference that depends on
  presentation order is reported as such instead of counted. See
  [Evals](docs/EVALS.md).
- **Refinement** — an agent's own traffic read back as a ranked report of what broke:
  repeated tool errors grouped by their normalized signature, failed turns, customers
  repeating themselves, canned safe replies served instead of answers, and granted tools
  that never fired. Provenance is session ids; snippets go through the same redaction as
  a customer-facing turn. Fired by hand (`insika refine --agent <id>` or the Studio
  button) — the engine grows no scheduler. It calls no model and edits nothing.
  `exclude_sessions` keeps load-test and debug traffic from burying real findings, and
  reports what it dropped. See [Refinement](docs/REFINEMENT.md).
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

- **A prompt file could silently become a serialized object.** `Pack.from_h` normalized
  only the KEYS of `files`/`skills`, and both `WriteAgentFile` and `AgentFileStore#write`
  called `to_s` on whatever they were handed — so a pack shaped
  `{"files": {"AGENTS.md": {"content": "…"}}}`, or an entry read and written back, was
  stored as Ruby's `#inspect` of the object. The agent then received its whole prompt as
  one line of `{"content" => "…\n…"}`, escapes and all, on every turn, while the file
  looked perfectly healthy: present, non-empty, and the agent still answered. All three
  layers now refuse a Hash or an Array instead of coercing it, and `insika doctor` sweeps
  existing prompt files for the same shape.

### Security

- **The `/v1` surface is closed by default.** `POST /v1/commands/<type>` — the generic
  Command ingress, which dispatches **any** registered authoring Command
  (`write_agent_file`, `write_data_tool`, `upsert_llm_provider`, `update_settings`,
  `delete_agent`) — answered **without any Authorization header**, as did
  `POST /v1/sessions`, `POST /v1/messages`, `POST /v1/workflows/<name>`, and the
  `GET /v1/sessions/:id` · `/v1/tasks/:id` · `/v1/events` reads. Anyone who knew a
  deployment's URL could rewrite an agent's prompt, repoint a tool at their own host,
  swap the LLM provider's credentials, or read every conversation.

  The gate was each handler's job to call, and the generic route never did. It now runs
  in the router, before any dispatch, against an **allowlist** of public routes (`/up`,
  the opt-in onboarding surface, the A2A agent card) — so the next route added is closed
  until someone publishes it deliberately. With no token configured the whole surface is
  `503`, never open by omission. `/a2a` is now behind the same Bearer.

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
- **A data tool's parameters are no longer half-invented by the engine.** In the flat
  authoring form, a param typed `array` used to lift to `items: {type: "string"}` — an
  item type nobody wrote. So a param whose API takes a list of *objects*
  (`[{query, filters}]`) reached the provider declared as a list of *strings*: the model
  obeyed the schema it was given, the backend answered `200`, and the results were
  wrong with no error anywhere. Three changes close that loop:
  - bare `array` is refused at ingestion (the JSON Schema path already refused an array
    without `items`); the flat form now spells a list of scalars `array:string` /
    `array:number` / `array:integer` / `array:boolean`, and a list of objects is written
    as JSON Schema. **Breaking for authoring**; `insika doctor` reports any stored tool
    left behind and offers the meaning-preserving rewrite.
  - the Studio tool editor no longer flattens what it cannot render. A nested schema
    shows as JSON Schema and saves back unchanged — before, opening and saving a nested
    tool silently replaced its schema with the broken flat one.
  - a tool call's arguments are validated against the tool's own schema before the
    request is built, so a malformed call becomes an `{ error: }` naming the offending
    path (`query_filter_pairs[0]: expected an object, got a string`) that the model can
    act on. Structure is strict; scalars accept their lossless string form (`"2"`,
    `"true"`) and are never coerced.
- **`insika doctor` now sees broken data tools.** A stored definition that no longer
  builds is dropped by the tool overlay with only a stderr warning — the agent quietly
  loses the tool. The new `data-tools` check is that drop's report.
