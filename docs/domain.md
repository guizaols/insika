---
title: The domain-free core
parent: Operate & prove it
nav_order: 9
permalink: /domain/
---

# The domain-free core — what ships, what a deployment declares, and how to clear it

The engine is domain-free by construction (RFC-0036): the gem carries no store
vocabulary, no persona, and no fixed conversation language. This page is the
removability map — for every artifact that could make a deployment look like
"the Brazilian store harness", here is what ships, what the doctor reports, and
how to clear it.

## What ships and what does not

One selection function owns the gem payload: `Insika::Packaging.payload_files`
— the gemspec and the audit spec (`spec/insika/domain_boundary_spec.rb`) call
the same function, so the boundary is a fact the suite asserts on, never a
prose promise. It ships:

- `lib/` — the engine, the server, the Studio (the compiled JS only);
- `docs/` — the public documentation;
- `README.md`, `LICENSE`, `CHANGELOG.md`, `bin/insika`.

It never ships: `deploy/`, `packs/`, `examples/`, `plugins/`, `evals/`,
`scripts/`, `spec/` — even a tracked pack cannot ship. Packs, personas and
deployment wiring are checkout material, and that is the point: the reference
deployment is not the gem.

The proof command is `insika doctor --domain`: a read-only inventory of what a
deployment declares, plus the built-in corpora still in effect. A bare install
with no agents names nothing; an install that boots an agent reports the
built-in pt-BR guardrail corpus as `source: gem-default` — the removability
surface, not a store. The section never fails the doctor's exit code: it is
informational, the RFC's proof surface.

## The guardrail corpus — clear the shipped pt-BR content

The deterministic guardrail patterns ship as language-tagged data
(`Safety::Corpus`). A deployment clears a language by config, per agent:

```jsonc
// pack: agent.config.json
{ "guardrails": { "corpora": { "languages": ["en"] } } }
```

```ruby
# DSL
agent = Insika.agent("store-support") do
  instructions "…"
  guardrails corpora: { languages: ["en"] }
end
```

- `languages` filters the shipped families: `nil` = all (the default),
  `[]` = none, `["en"]` = the EN-only corpus. An EN-only deployment drops the
  pt-BR input heuristics **and** the CPF/CNPJ output redaction — a documented
  consequence: the tax-id formats are pt-BR data, and the universal "secret"
  redaction is never cleared.
- `extra` adds source-string patterns per family:

```jsonc
{ "guardrails": { "corpora": { "extra": { "abuse": ["/\\bdupa\\b/i"] } } } }
```

- `guardrails.responses` replaces the built-in pt-BR fallback replies (the
  safe refusals). Set a `default` to clear every category at once.

See [Security](SECURITY.md) for the guardrail layers; the doctor's domain
section enumerates any agent still running the built-in pt-BR corpus or the
built-in replies, with the clear path in each entry. An unknown language or
family, or a malformed pattern, is refused at boot — `insika doctor` reports it
as an error and the agent never turns with a broken corpus.

## Marking a deployment — declare, never infer

The engine never guesses a store. Domain markers are data a deployment
declares, and the doctor reads only those declarations:

- **Personas/packs** — `metadata.domain` on the agent profile:

```jsonc
{ "metadata": { "domain": "e-commerce-pt-BR" } }
```

```ruby
metadata domain: "e-commerce-pt-BR"
```

- **Outcome funnel** — `funnel:` on the profile (see
  [Outcomes](AGENTS.md#outcomes--business-results-over-real-traffic-ws7)).
  Vocabulary note: in the gem and the doctor output it is an **outcome
  funnel**, never "conversion" — the stage names are the deployment's, and a
  bare install shows no funnel and no stage names at all.
- **Evidence** — the `evidence:` declaration on a tool manifest (see
  [Tools](TOOLS.md)); the kinds are the deployment's vocabulary, never gem
  constants.

`insika doctor --domain` enumerates all four with their source —
`deployment` for declared data, `gem-default` for the built-in corpus still in
effect — and a bare boot names none.

## The conformance claim — model-visible means logged

"Every byte that reaches the provider is reconstructable from checkpoints +
traces" is a spec, not a promise. For each (task, turn) the engine records the
model-visible payload at the provider boundary — the system text, the tool
schemas, and the full message stream (`ModelVisibleTraceStore`) — next to the
durable transcript (the checkpoint). The conformance suite
(`spec/insika/conformance/model_visible_spec.rb`) drives real turns on a
capturing chat and asserts a three-way byte identity: what the chat held ==
the checkpoint transcript == the model trace. A path whose bytes are not
logged is a fix in the engine, never a waiver in the suite.
