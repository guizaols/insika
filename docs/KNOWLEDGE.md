---
title: Knowledge
parent: Operate & prove it
nav_order: 8
permalink: /knowledge/
---

# Knowledge — learning from conversations

An agent is amnesiac in exactly one dimension. It has history (the session),
memory (facts about one customer, written by the `remember` tool), skills
(procedures a human curated), and tool traces — but nothing turns a finished
conversation into knowledge the agent can use on someone else's turn. Every
conversation teaches a store things — which product customers actually ask
about, which objection keeps coming up, which CEP maps to which distribution
center — and today all of it is write-once trace data nobody reads back.

Knowledge is that loop. After a turn completes, the engine can extract durable
**concepts** from it — facts, procedures, policies, objections — and persist
them for the agent (never a customer, never a session) to build on.

**What ships today: extraction, consolidation, retrieval, export, and a
Studio page.** The engine writes what it learns, decides whether a repeat
sighting confirms, merges with, or contradicts what it already knew,
retrieves the concepts relevant to a turn's message back into the prompt,
and an operator can see, edit and resolve all of it in the Studio. Only the
optional FTS5 index remains, deferred with a measured trigger — see
[What's not here yet](#whats-not-here-yet).

## The concept format

One concept is one record — a markdown document with a YAML frontmatter
block, the same shape a `SKILL.md` uses:

```markdown
---
name: cep-sudeste-cd-campinas
description: CEPs 13xxx-13999 ship from the Campinas DC, 1-2 business days.
type: fact                     # fact | entity | procedure | policy | objection
provenance: observed           # policy (curated) | observed (learned from conversations)
confidence: 0.6                # 0..1, evidence-weighted
sources: ["sess_8f3c"]         # session ids, never message content
occurrences: 1
created_at: 2026-08-24T18:02:11Z
updated_at: 2026-08-24T18:02:11Z
---

Orders to CEP range 13000-13999 are fulfilled by the Campinas DC. Quoted
delivery is 1-2 business days. Related: [[frete-gratis-acima-199]].
```

The model only ever writes `name`, `description`, `type` and `body`. Every
other field — `provenance`, `confidence`, `sources`, `occurrences`, the
timestamps — is stamped by the engine; an extraction answer that tries to
supply one of those is rejected outright (the same discipline Facts applies
to a model-authored scope). `[[links]]` inside the body are plain text stored
as-is; retrieval resolves them lazily by name at read time (below) — that one
hop is the entire "graph," never a stored structure of its own.

**`provenance` is not decoration.** Everything the extractor writes is
`provenance: observed` — a claim learned from what people said in
conversations, not official policy. A promise an agent made ("we'll get back
to you in 48h") is observed practice, not a guarantee, and the field exists so
nothing downstream states it to a customer as a commitment. `provenance:
policy` is reserved for a concept a human authored or promoted by hand — the
engine never sets it.

## Enabling it — the `knowledge:` block

Knowledge is pack data on the agent, exactly like `distill:` or `harvest:` —
absent = the feature is off for that agent, byte-identical engine:

```ruby
agent = Insika.agent("store-support") do
  instructions "…"
  knowledge extract: true, retrieve: true,
            types: %w[fact policy objection],  # what the extractor may emit
            top_k: 5                            # concepts injected per turn (default 5)
  # prompt: "<what counts as a concept for THIS store>" — the pack-authored
  #   half; absent = the engine's generic prompt. `model:` (absent = the
  #   platform utility_model) names the extractor AND the consolidator.
  # index: "scan" (default, the only one built) | "fts5" (accepted, falls
  #   back to "scan" — the optional SQLite index isn't built yet).
end
```

`extract` and `retrieve` are independent switches: an agent can learn without
recalling (write-only, inspected by hand), or recall without learning
(curate every concept by hand in the Studio, `provenance: policy`).

## The write path

After a turn completes, off the turn's critical path (the customer already has
the answer), the engine sends the turn's transcript slice to the platform
`utility_model` and asks for a JSON array of candidate concepts. The answer is
schema-validated, filtered against the agent's configured `types`, and any key
the model should not be writing is dropped and counted, never trusted. The
survivors are redacted for PII, stamped with provenance and a first-sighting
confidence, and written to the store — one `:knowledge_learned` event per
concept (name, type, agent — never content).

**Durability, honestly.** Extraction is best-effort: a crash between a turn's
terminal and the write loses that turn's concepts, not the conversation (which
is durable) and not a previously learned concept. The recovery path is a
re-scan, not a queue:

```
insika knowledge:backfill --agent store-support --since 2026-08-01T00:00:00Z
```

replays the agent's stored sessions through the same extractor a live turn
uses.

## Consolidation — what happens on a repeat sighting

Writing a concept name that already exists is never a blind overwrite. The
engine compares the new sighting against what is on record and picks one of
three outcomes:

- **Same claim, reworded or reconfirmed** — a cheap, deterministic check
  (no model call): occurrences go up, the new session id joins `sources`,
  confidence climbs (`min(0.95, 0.5 + 0.1 × distinct sources)` — more
  independent sightings, more confidence, never certainty). The body itself
  is untouched, so an operator's edit is never silently discarded by a
  repeat sighting.
- **Related claim** — the two bodies say compatible things that combine into
  one coherent statement. A second model call (the only place this feature
  spends a second call, and only when a name already exists) merges them;
  the result bumps occurrences/sources/confidence the same way a same-claim
  sighting does.
- **Contradicting claim** — the two bodies say genuinely different things.
  **Never merged, never silently overwritten.** The new claim is appended
  under a `## Contradiction` heading, confidence drops to a flat `0.4`, and
  a `:knowledge_conflict` event fires. A human resolves it in the Studio by
  editing the concept directly — there is no separate "resolve" action,
  because resolving IS editing the markdown to say what's actually true.

When no model is configured for consolidation (or its answer is unusable),
the engine defaults to the conservative outcome — contradicting. A concept
this feature is unsure about becomes a human's problem, never a guess that
looks confident and might be wrong.

## The Studio page

`/studio/knowledge` — single-agent-scoped like Harvest (`?agent=`), not
shared like Skills, because a concept only ever belongs to one store. A
drill-down list (name, type, confidence, occurrences, updated_at) with a
conflict filter (`?status=conflict`) and the same CodeMirror markdown editor
Skills uses, version history and restore, and delete. Editing the raw
markdown is also how an operator promotes `provenance: observed` to `policy`
— there is no separate "promote" button, the field is just another line in
the file.

## Retrieval — what reaches a turn's prompt

With `knowledge.retrieve` on, every turn the engine searches the agent's
concepts for the ones relevant to the customer's message (pure term overlap —
no embeddings, no network call) and injects the top few as a level-1
`<knowledge>` block, the same progressive-disclosure shape Skills uses:

```
<knowledge>
  <concept name="cep-13-campinas" confidence="0.60" provenance="observed">CEPs 13xxx-13999 ship from the Campinas DC, 1-2 business days.</concept>
</knowledge>

If the customer's question needs more than the summary above, call
`load_knowledge("name")` FIRST — before any other lookup for that topic.
This is learned from past conversations, not official policy: never state
a `provenance="observed"` concept to the customer as a guarantee.
```

Only `name`/`description`/`confidence`/`provenance` are shown — the same
"summary now, body on demand" shape a skill's level-1 list uses. A `load_knowledge`
tool (outside `tools_allow`, wired only when `retrieve` is on — same as
`load_skill`) fetches one concept's complete body. Calling it fires
`:knowledge_retrieved` — this, not the injection itself, is what the
adoption metric tracks (see [the honest limits](#the-honest-limits)): a
concept sitting unread in the prompt taught the agent nothing.

**One hop through `[[links]]`.** A matched concept's body may reference
`[[other-concept-name]]`; retrieval resolves those names against the store
and injects them too (capped at `top_k` again), so a concept that names its
neighbor arrives with it. No transitive walk — one level, deliberately, the
same reasoning a skill's declared `companions:` uses.

**Where it sits, and what gets cut first.** `<knowledge>` sits at priority 77
— below curated skills (80), above a single conversation's memory (75): a
human's playbook always outranks what the engine inferred, and what the
engine inferred outranks one customer's chat facts. Never pinned; under
budget pressure it goes before skills but survives longer than memory,
briefing, history and request context — see [Context](CONTEXT.md).

## External knowledge over MCP

A native knowledge base is not the only shape this can take. Mounting a
third-party knowledge or memory server as MCP tools on an agent is a
supported pattern, complementary to the native loop above — a deployment can
run both: this loop learns concepts from ITS OWN traffic automatically, while
an MCP-mounted server can serve as a synthesis/consultant tool an agent calls
explicitly.

The one adoption lesson worth carrying over regardless of which shape is used:
a model does not reliably call a recall/lookup tool just because it exists,
even when it clearly should. A polite "use this when relevant" instruction
measured close to zero calls under pressure; what worked was an explicit,
ordered rule naming the competing tools directly — "call the recall tool
FIRST, before any data lookup, on topics X" — not a sentiment about when it's
a good idea. Tool *adoption* is a prompt-ordering problem, not a tool-quality
one, and it is worth measuring (calls per conversation), not assuming.

## The honest limits

- **Best-effort extraction, re-scan recovery.** Same discipline as Facts: no
  queue, no exactly-once claim. A concept is re-derivable from the session
  transcript, so a missed extraction is recoverable, never lost.
- **Consolidation trusts the same model that extracts.** The "related vs.
  contradicting" call is a model judgment, not a proof — the conservative
  default (contradicting, when unsure) bounds the failure mode to "a human
  looks at it," never "two different claims silently became one wrong one."
- **Precision is a forge audit.** The engine guarantees the gates (schema,
  key-stripping, PII redaction, type allowlist); it cannot guarantee the
  model's judgment about what is worth remembering. That is tuned per store,
  the same way a Harvest or Facts prompt is.
- **Retrieval quality is not adoption.** Injecting the right concept proves
  nothing if the model never reads it — measure `:knowledge_retrieved`
  (retrieval calls per conversation), not just whether the block appeared.
  The explicit, ordered instruction in the block exists because a softer
  "when to use" wording measured close to zero calls in practice.
- **Term overlap, not understanding.** `Index::Scan` matches words, not
  meaning — a concept phrased very differently from the customer's words
  will not surface even if it answers the question. No embeddings by
  design (§14.4's call): revisit only with evidence that retrieval, not
  extraction, is the bottleneck.

## Index::Scan's performance, measured not assumed

`Index::Scan` keeps a read cache per instance (the context provider holds
one for the whole process, never rebuilt per turn): a concept's YAML
frontmatter is parsed once and reused until that concept's own record
`updated_at` changes, so a write invalidates itself for free. Reproduce
these numbers with:

```bash
bundle exec ruby scripts/bench_knowledge_index.rb
```

| concepts/agent | p50 | p95 |
|---|---|---|
| 50 | 0.28 ms | 0.47 ms |
| 200 | 1.17 ms | 1.56 ms |
| 1000 | 6.4 ms | 8.0 ms |
| 5000 | 35.6 ms | 41.3 ms |

At the scale this feature targets for the first year — hundreds of concepts
per agent — a warm-cache search costs a bit over a millisecond, close to
the engine's own documented per-turn overhead (see [Benchmark](BENCHMARK.md)).
Past roughly a thousand concepts it becomes a real, measurable cost again —
that specific, numeric point is the trigger for building `Index::FTS5`, not
a guess made in advance.

## Export

```
insika knowledge:export --agent store-support --out ./export [--tenant loja-a]
```

Writes one `<name>.md` per concept — the storage format IS the export
format, so this is a dump, not a converter (same discipline as Facts/
Harvest's own append-only records): each file is the concept's markdown,
byte for byte, directly consumable by okf-gem (`OKF::Bundle`) or graphify.
Re-running it is safe — nothing here is lossy, so there is no `--force` to
reason about.

`--format graphml` writes one combined `knowledge.graphml` instead: a node
per concept (`name`/`type`/`description`/`confidence`/`provenance` as node
data) and an edge per `[[link]]` that resolves to another concept in the
same export — a link to a concept outside the scope is dropped, never a
dangling edge. Hand-built, hand-escaped XML (no new dependency), directly
openable in Gephi, yEd, or graphify.

## What's not here yet

- **The optional FTS5 index** — `knowledge.index: "fts5"` is accepted but
  falls back to `Index::Scan`. Deliberately not built yet: `Scan` was
  measured (above), not assumed, and it comfortably meets this feature's
  target scale. A deployment whose concept count is heading past ~1000 per
  agent is the evidence that would justify building the SQLite
  `MATCH`/`bm25()` adapter — not before.
- **Decay** — recency is a ranking tiebreak today; a real confidence decay
  curve is a later, evidence-driven addition, not a default.
