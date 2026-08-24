# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
it is released. Entries land with the pull request that makes the change.

## [Unreleased]

### Added

- **Knowledge consolidation + the Studio page** — a repeat concept name no
  longer blindly overwrites. The engine now decides same claim (bumps
  occurrences/sources/confidence — `min(0.95, 0.5 + 0.1 × distinct_sources)`,
  no model call), related claim (one extra model call merges the two
  bodies — `Insika::Knowledge::Consolidator`/`ConsolidatorFactory`), or
  contradicting claim (never merged — appended under a `## Contradiction`
  heading, confidence dropped to `0.4`, `:knowledge_conflict` emitted). No
  consolidator configured, or an unusable answer, defaults to contradicting —
  the conservative choice. `/studio/knowledge` (single-agent-scoped like
  Harvest) lists every concept with a conflict filter, the same CodeMirror
  editor Skills uses (also how an operator hand-promotes `provenance:
  observed` to `policy`), version history/restore, and delete — all through
  three new bus commands (`write_concept`/`delete_concept`/`restore_concept`,
  wired through every composition root).

- **Knowledge, layer 1 (extraction)** — the engine can now learn durable
  **concepts** (facts, procedures, policies, objections) from finished
  conversations, opt-in per agent via `knowledge extract: true`. After a turn
  completes, off the critical path, the platform `utility_model` proposes
  candidate concepts; the engine schema-validates the answer, drops any
  model-authored `provenance`/`confidence`/`sources` (stamped by the engine
  instead — every extracted concept is `provenance: observed`, never
  `policy`), redacts the body for PII, and persists it as a markdown+
  frontmatter record in the new `KnowledgeStore` (`Insika::KnowledgeStore`,
  scoped per agent/tenant like `MemoryStore`, versioned like `SkillStore`).
  Emits `:knowledge_learned` (name/type/agent only, never content). The
  recovery path is `insika knowledge:backfill --agent ID [--since DATE]`,
  replaying stored sessions through the same extractor. No retrieval into a
  turn's prompt yet — see `docs/KNOWLEDGE.md` for what's shipped and what's
  still planned.

- **Plugin loading is on in every root** — `Server::Boot`'s `load_plugins`
  step was a no-op in both composition roots, so the tested
  `Insika::Plugin::Loader` never ran outside the `insika-code`
  example. It now runs at boot in the minimal wiring, the demo deployment
  and DSL-run agents, via a shared `Wiring::Graph.load_plugins`. Discovery
  roots: announced gems (default-enabled), `INSIKA_PLUGIN_DIR` (workspace)
  and the repo's `plugins/` — the latter two gated by `INSIKA_PLUGINS`,
  with `INSIKA_PLUGINS_DISABLED` as the absolute veto. Plugin skills and
  prompts join the catalogs at the lowest precedence (a workspace or
  authored skill still wins). The dead `OPENCLAW_PLUGIN_DIR` env spec
  (nothing ever read it) is replaced by the three new keys.

- **Media parity** — three transport gaps closed, all additive:
  `generate_image` can now EDIT as well as generate — `source_image_urls`
  (or, absent those, the turn's own inbound photo by default) ride
  `RubyLLM.paint(with:)`, an optional `mask_url` rides `paint(mask:)`; a
  fourth inbound part type, `document` (`{ "type": "document", "url": … }`,
  capped at 10 MB), attaches to the ask like an image and deposits
  `{{ctx.document_url}}` for data tools; and audio transcription now carries
  a vocabulary `prompt:` (per-agent `stt_prompt`, falling back to the
  deployment-wide `INSIKA_STT_PROMPT`) so domain terms (product names, brand
  terms) transcribe correctly instead of phonetically. Text-to-image and
  plain audio transcription stay byte-identical when neither feature is used.
- **Demo data** — `insika demo:seed` (and a matching "Seed demo data" button
  under Studio Settings) provisions a bundled `demo-store` agent and writes
  enough realistic data to see every loop working at once: a funnel with a
  frozen baseline, follow-ups in all four states, refinement runs across the
  lifecycle, pending and resolved approvals, distillation proposals and a
  memory fact, and a golden set with a mixed-result baseline. One code path
  (`Insika::Demo::Seeder`) behind both front doors, same discipline as every
  other Studio button. Fixed two pre-existing gaps this surfaced: `config.ru`
  never wired `proposal_store`/`budget_ledger` into the Studio (the Facts page
  and the funnel's spend pill were unreachable in production), and
  `scripts/serve_real.rb` never wired the outcome/funnel/follow-up/proposal
  stores at all.

## [0.3.0] - 2026-08-19

The proof-and-consultant wave: shadow parity against a frozen criterion, the
72h soak, perceived latency (progressive delivery), the session briefing,
evidence grounding, the layered identity cache, customer memory in the Studio,
the conversion ledger, `schedule()` with consent, human-gated facts, the gated
skill harvest — and a domain-free core: the e-commerce defaults are removable,
and what ships in the gem is asserted by the suite.

### Added

- **Shadow mode** — the relay channel can run every turn end to end and deliver
  nothing: the incumbent keeps answering, the engine records what it *would*
  have answered, and the two replies are judged pairwise against a **frozen,
  pre-registered criterion** (the file `INSIKA_PARITY_CRITERION` points at; its
  SHA-256 stamps every pair, and editing it mid-window turns the verdict
  `invalid`, never stale). A panel of judges scores each pair twice with the
  sides swapped, so a preference that flips with presentation order is recorded
  as comparable, not as a preference. The Studio's Parity page folds the
  running verdict on demand. No criterion, no shadow: boot refuses.
- **The 72h soak** — `insika soak` sustains a declared arrival rate for days and
  asks whether the *process itself* degrades with uptime. A deployment-side
  envelope freezes the load shape and the gated ceilings before the first hour
  (its hash stamps every snapshot); `--preflight` refuses to start on a missing
  precondition; the runner appends hourly vitals as they happen, so a crash at
  hour 60 leaves 60 usable hours; `--verify` recomputes the whole verdict
  offline from the raw records. A fail means *find the leak* — never cut, and
  never loosen the envelope.
- **Progressive delivery** — the relay can flush the outbox one balloon per
  paragraph (`INSIKA_RELAY_DELIVERY=progressive`), with the first balloon
  posted as soon as the answer exists; the default `:at_end` is byte-identical
  to before. Every channel turn records `first_balloon_ms` (inbound receipt →
  first outbox flush) so the target is measured, not assumed.
- **Session briefing** — the pack can declare `briefing_fields`; the engine
  keeps the session's working state as data (known fields, still-missing list,
  next step), a tool updates it, and the context provider injects it into the
  turn — the consultant stops re-asking what it already knows.
- **Grounding** — an `evidence:` contract on the tool envelope: a model claim
  must cite ids that came out of a tool call, with `:enforce` / `:flag` / `:off`
  modes and a per-turn ledger. A claim without evidence is refused or flagged —
  never silently passed through.
- **Layered identity + observable cache** — context providers are split into
  identity/volatile layers behind a byte-stable cache prefix; the per-agent
  cache-hit series is recorded (`CacheSeriesStore`) and shown on the Studio
  agent detail. Invalidations and hits are measurable, not guessed.
- **Customer memory in the Studio** — a Customers drill reads and edits the
  per-customer memory cell, with an append-only operator-mutation audit trail
  (content-free digests), provenance metadata, expiry, the LGPD export
  (`/v1/commands/export_customer_memory`) and the existing right to be
  forgotten.
- **The outcome funnel** — outcomes fold into a store-declared stage funnel
  (`funnel:` on the pack) on the tick: idempotent cumulative counts, an
  attribution window carried as data, a frozen baseline (`:freeze_funnel_baseline`)
  and a Studio page per agent. The stage vocabulary is the deployment's; a bare
  install shows no funnel at all.
- **Follow-ups** — the agent can book a future contact: `schedule()` and
  `cancel_followup()` tools, a durable per-customer contact state
  (`granted | revoked | unavailable`, where silence is not a refusal), a policy
  engine over the tick (quiet hours, frequency ceilings, dedup, opt-out
  keywords) and a Studio page per agent. A customer who opted out can never be
  rescheduled; blocking happens at fire time, never at schedule time.
- **Distilled facts** — finished conversations are read back as proposed
  customer facts; a human approves/rejects/dismisses each on the Studio Facts
  page, with a latched dedup ledger (a dismissed tuple is never proposed again),
  optimistic CAS writes and LGPD-friendly retention. Nothing is ever applied
  automatically.
- **Gated skill harvest** — finished traffic can be mined for skill proposals
  behind a versioned negative list and an evidence ledger (product claims must
  reference ids the origin sessions actually saw); promotion requires the eval
  replay **and** the store's conversion ruler not to regress, with an
  append-only log and snapshot rollback. Nothing is ever applied automatically.
- **A domain-free core** — the gem payload is a spec-asserted boundary
  (`lib/` + `docs/` + the four root files; `deploy/`, `packs/`, `examples/`,
  `evals/`, `scripts/` and `spec/` never ship, even when tracked). The pt-BR
  guardrail corpus is language-tagged removable data, and `insika doctor --domain`
  inventories what a deployment declares. A bare install names no store.
- **Model-visible conformance** — every byte that reaches the provider is
  reconstructable from checkpoints + traces, proven byte-for-byte by the
  conformance suite (`spec/insika/conformance/`): what the chat held == the
  checkpoint transcript == the model trace, across plain, tool-calling, steered,
  subagent, scheduled and resuming turns.
- **Intent routing** — `AgentProfile#routes` classifies the turn's
  message into one configured route with a cheap model before the ask, from a
  prompt auto-generated out of the route descriptions. The route rides the
  turn (`state.route`, the `:route_classified` event, the terminal event), its
  provider cost is counted in the usage, and a route can `delegate` to an
  existing agent (its answer becomes the parent's) or end the turn with the
  stuck outcome (`stuck: true`). Deterministic `default` fallback;
  classifier failure leaves the turn unrouted (additive).
- **Outcomes** — `POST /v1/outcomes` records a conversation's business
  outcome (`conversion`/`escalation`/`deflected`/…, optional monetary value)
  from the operator or the integration — additive, outside the response
  contract, tenant-stamped. `GET /v1/outcomes` serves the last outcome
  per agent + per-day series; the Studio's agent grid shows the last-outcome
  pill and the agent detail shows the per-day series.
- **Customer-scoped memory + right to be forgotten** — a message
  carrying a `customer` key moves the memory scope to the `[tenant:]customer`
  cell: two customers under one tenant never read each other (phase 1), and
  the `<request_context>` merchant label stays untouched. Facts gained an
  optimistic CAS write (`replace_if_revision`, microsecond revisions).
  `POST /v1/commands/forget_customer` (phase 2, LGPD) purges one customer's
  memory cell, their sessions and per-session traces — nothing else's.
- **Tenant deletion + retention** —
  `POST /v1/commands/delete_tenant_data` purges everything the engine holds
  about one tenant (sessions, traces, every memory cell under the tenant and
  its outcome records); the `retention_days` settings key turns on the tick's
  daily age-based sweep (sessions + traces, terminal tasks + checkpoints,
  memory cells and outcomes — OFF by default). The KV store contract gained
  an additive `scopes(prefix)` enumeration.
- **Media in the message contract** — messages accept
  additive content parts (`text`/`image`/`audio` with a URL). Audio is
  transcribed via RubyLLM STT (model/language via `INSIKA_STT_MODEL`/
  `INSIKA_STT_LANGUAGE`) and the text enters the turn marked
  `source: "voice"` on the terminal event; images attach to the model's ask
  (provider-billed, usage flows) and the first image URL is
  `{{ctx.image_url}}` for data/HTTP tools; media URLs pass the egress guard. The
  OpenAI multimodal `input` array shape works on `/v1/responses`.
- **Generated media as outputs** — the turn can produce an
  image or a voice clip when BOTH gates agree: the agent opts in
  (`AgentProfile#outputs` — per-kind model/voice/size config) and the request
  declares the channel can receive it (`channel.capabilities`, one of
  `image_output`/`audio_output`; unknown values are a 422 — the abstraction
  admits only what leaks). The `generate_image`/`tts` system tools are wired
  only then, the media rides the envelope additively (`output_parts` on the
  terminal event and the `/v1/responses` completed frame — base64 parts, never
  the answer text), image tokens merge into the turn's usage and every call
  adds an honest `usage.media` counter (the speech API reports no tokens; the
  part carries the model for consumer-side pricing). Generators are injectable
  seams; the defaults are lazy (RubyLLM paint; a thin POST to the
  OpenAI-compatible `/audio/speech` using the same provider config).

## [0.2.0] - 2026-08-13

The workstreams between the first release and the one the gem actually became:
multi-tenancy at the edge, calendar budgets, provider reliability, the stuck
signal, operator alerts + live TTFB, and the failure-classification core — plus
the two fix rounds that made them safe to ship.

### Added

- **Multi-tenant at the edge** — `INSIKA_TENANCY=multi_tenant` resolves the
  Bearer to a principal before the routes: per-tenant + operator tokens stored
  only as SHA-256 hashes, a tenant's sessions/tasks/streams living under its own
  `<tenant>:` namespace (fail-closed: another tenant's reads as `404`), and every
  authoring/config surface refused to a tenant.
- **Calendar budgets** — `AgentProfile#budget` caps the billed spend
  (input + output + cached + cache-creation) per calendar day/month and
  (tenant, agent): HARD (default) fails the turn with the typed
  `Insika::BudgetExceeded` + `retry_after`; `soft: true` runs the turn and warns
  once per window — with the `alert_at` (`0.8`) crossing and the real cap
  crossing as separate events.
- **Reliability** — retries with backoff, mid-turn rotation to the
  fallback chain, a per-`(tenant, provider/model)` circuit breaker with
  half-open trials (a failed trial reopens), and a per-attempt `timeout`
  (default 30s) counted as retryable. A `:fatal` provider error is never
  retried.
- **Stuck signal** — an agent declared stuck ends its turn with
  `outcome: "stuck"` on the envelope and a dedicated `:turn_stuck` event — the
  deterministic point a consumer escalates on.
- **Operator alerts + live TTFB** — `budget_warning`, `breaker_open` and
  `delivery_failed` POSTed to a per-agent `alerts.webhook` over the at-most-once
  outbox pipeline (boot-recoverable); under `INSIKA_TURN_TIMING` the first
  content chunk emits a live `:ttft` on the streaming envelope.
- **Failure classification** — provider/transport failures classified by
  action (`:fatal` / `:retryable` / `:rate_limited_*`) and wrapped with the
  provider's `retry_after`; mechanical tool-output dedupe back-references a
  byte-identical repeat only when the reference is genuinely shorter.
- **The periodic tick** — durability no longer waits for a reboot. Serving
  workers run a tick every `INSIKA_TICK_INTERVAL` (default 60s, `0` disables)
  as a child of the turn supervisor: it re-drives outbox records left `:pending`
  and sweeps orphaned `:queued`/`:running` tasks untouched past
  `INSIKA_TICK_STALE_AFTER` (default 900s) — the orphans of a worker respawned
  mid-generation are recovered without a deploy. One worker per window sweeps (a
  single transactional claim); a task someone alive owns is skipped, never
  failed. `:waiting`/`:paused` stay boot recovery's.

### Fixed

- **Budget/reliability/alerts criticals** — the budget alert marker no longer returns inside
  the store transaction (a leaked `BEGIN IMMEDIATE` locked SQLite on the 2nd
  over-threshold turn); the monthly reset is December-safe and UTC-aligned; an
  unset reliability timeout is 30s, not 1s, and a timeout retries/rotates
  instead of dying as "fatal"; a failed half-open trial reopens the circuit;
  webhook deliveries pass the egress guard (SSRF); `:ttft` is emitted once per
  turn; webhook channels pre-register so the boot sweep recovers pending alerts;
  the alert dispatcher subscribes typed and re-subscribes on overflow.
- **Tenancy** — `#revoke` rides the store transaction; a `tenant_id` containing
  `:` is refused (the session-namespace delimiter); `POST /v1/sessions` mints a
  tenant's session under its own prefix.
- **Budget and reliability softs** — a failed turn's consumed tokens count against the budget;
  `:breaker_open` alerts only on the closed→open transition; the fallback chain
  dedupes `"model"` vs `"provider/model"` spellings.

## [0.1.0] - 2026-08-10

The first release: `gem install insika`.

### Added

- **A publishable core** — `gem install insika` gives every shape: `reply`
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
  panel against real traffic: the gate reported *6/6, no regression* against a
  baseline the same corpus had just scored *2/6*, and both candidates cleared. With the
  judge configured, the same two candidates were correctly rejected on judge-score
  drops. Third member of the same family as the missing and all-red baseline refusals.
- **The refinement budget counts the prompt cache** — the engine's `total_tokens` is
  input + output and excludes the cached prefix (a 27 KB pack reports `88` total against
  `26624` cached), so a ceiling built on it alone let a run send hundreds of times what
  it said. Cost now bills `total + cached` and records the cached share, which on a real
  run was 95% of the spend. A run that cannot be gated is also refused **before**
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
