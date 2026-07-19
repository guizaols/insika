# Evals — the quality harness

Behavior tests for the agent, end-to-end. Where RSpec (`spec/`) is the
deterministic unit net and `scripts/loadtest.rb` measures perf, **evals** answer
"did the agent still behave well?" after a prompt/tool/model change — the net that
was missing (FOLLOWUP §9 / #10). Design: **RFC-0008**.

It lives OUTSIDE the core: nothing under `lib/harness/**` requires it. Like the
loadtest, it talks to the engine only through the public API (`POST /v1/responses`).

## Layout

```
evals/
  lib/evals/          the engine (pure, unit-tested in spec/evals/)
    golden.rb           golden loader + validation
    assertions.rb       deterministic checks (tools_called, must_not) over a TurnResult
    report.rb           JSON + markdown report
  golden/<agent>/*.yml  the curated cases (DATA, not code)
  runner.rb             replay driver over /v1/responses      (slice 2 — in progress)
  baseline.json         accepted scores for gating            (Fase C)
  reports/              run outputs
```

## Golden format

```yaml
id: frete-cep          # unique case id
agent: demo-store             # target agent (must be provisioned in the harness)
turns:                       # the conversation to replay, in order
  - user: "qual o frete pro 01310-100?"
expect:
  tools_called:              # required tools; a trailing "?" = OPTIONAL (never fails)
    - shipping_quote
    - search_products?
  must_not:                  # named negative detectors
    - pii_leak               #   CPF/CNPJ/credential in the output
    - tool_error             #   any failed tool call in the turn
  rubric: |                  # LLM-judge criterion (Fase B — deferred)
    Deve cotar o frete sem inventar prazo…
  min_score: 0.7             # judge threshold (Fase B)
```

The raw material is the **179 real user messages** extracted from the OpenClaw
session logs (`openclaw/agents/*/sessions/*.jsonl`); curation turns a handful into
goldens with an `expect` block. Start ~15–20 cases over the hot flows (produto,
frete, objeção, fora-de-escopo) and grow. The same corpus feeds the real-traffic
loadtest (#6b) — one replay, two purposes.

## Two evaluation layers

- **Deterministic (Fase A — here):** `tools_called` / `must_not` are pure checks
  over the turn's tool events + output text. Zero tokens, zero flakiness — catches
  the gross regressions (a tool stopped being called, a secret leaked, a tool
  errored).
- **LLM-judge (Fase B):** a rubric-scored pass using the `utility_model` (Settings,
  #18) at temperature 0. A golden with a `rubric` reads as **judge-pending** until
  then — never a silent pass.

## Phasing (RFC-0008 §5)

- **Fase A** — engine (loader + deterministic asserts + report) + this README.
  Unit-tested offline in `spec/evals/`. ← this PR.
- **Fase B** — `runner.rb` over `/v1/responses` (`--mode perf|eval|both`; shares the
  transport with `loadtest.rb`, so `perf` mode closes #6b) + LLM-judge + agent
  provisioning via PackImporter from `openclaw/workspace/agent-store-<id>/`.
- **Fase C** — `baseline.json` + `--tolerance` gating; the pre-merge gate for
  prompt/tool/model changes.
