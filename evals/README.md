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
    transport.rb        SSE reducer + HttpTransport over /v1/responses
    runner.rb           replay driver (orchestration; injected transport + judge)
    judge.rb            LLM-judge — rubric scoring over an injected ask
  golden/<agent>/*.yml  the curated cases (DATA, not code)
  run.rb                CLI entrypoint
  baseline.json         accepted scores for gating            (Fase C)
  reports/              run outputs
```

## Running

The runner replays the golden set against a **running** harness over the same
`POST /v1/responses` surface as `scripts/loadtest.rb`. It's on-demand (not CI): it
needs a live provider key on the server + the target agents provisioned.

```bash
# 1. boot a harness (dev): DEEPSEEK_API_KEY=… ruby scripts/serve_real.rb
# 2. provision the target agent(s) from the real packs (client; POST /v1/agents):
HARNESS_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=local-demo \
BIA_INTERNAL_API_TOKEN=… \
  bundle exec ruby scripts/import_pack.rb openclaw/workspace/agent-store-<id>
# 3. run the evals:
OPENCLAW_GATEWAY_TOKEN=local-demo \
  ruby evals/run.rb --base-url http://localhost:9292 --mode both
```

Flags: `--base-url`, `--golden-dir`, `--agent <id>` (filter), `--mode eval|perf|both`,
`--out <file>`, `--timeout`. `--mode perf` reports TTFB/total p50/p95 over the real
corpus — that's the **#6b** real-traffic loadtest, since it's the same transport as
`loadtest.rb` but driven by real conversations. The runner **exits non-zero** if any
eval case fails (the seed of the Fase C pre-merge gate).

### LLM-judge (rubric scoring)

A golden's `rubric` is scored by an LLM-judge when a judge model is configured;
otherwise the case stays `judge_pending` (deterministic checks still run). The judge
runs at temperature 0 and, on a borderline case, a `--quorum` takes the median of N
samples. An unparseable judge reply scores 0 (fails) — never a silent pass.

```bash
DEEPSEEK_API_KEY=… OPENCLAW_GATEWAY_TOKEN=local-demo \
  ruby evals/run.rb --judge-model deepseek-chat --quorum 3 --mode eval
```

Judge flags: `--judge-model` (or `EVAL_JUDGE_MODEL`), `--judge-provider`, `--quorum`,
`--no-judge`. Mirrors the intent of the platform `utility_model` (#18) — a cheap
model for internal tasks.

### Gating against a baseline

`evals/baseline.json` is the accepted state of the set. A gated run blocks only on a
**regression** — a passing case that now fails, or a judge score that dropped past
`--tolerance` (default 0.05). Known-failing cases don't wedge the gate; a brand-new
case absent from the baseline shows in the report but never blocks.

```bash
ruby evals/run.rb --update-baseline     # accept the current run as the baseline
ruby evals/run.rb                        # gates against evals/baseline.json if present
ruby evals/run.rb --baseline other.json --tolerance 0.1
```

With no baseline file at all, the run falls back to "fail if any case failed".

**Tool status caveat:** the `/v1/responses` stream carries tool *names* but not
per-tool status, so over HTTP the `tool_error` detector only catches *turn-level*
failures (`response.failed`). Full per-tool status lives in the `ToolTraceStore`
(an in-process enrichment) — a later refinement.

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

- **Fase A** — engine (loader + deterministic asserts + report). Unit-tested offline.
  ✅ done.
- **Runner** — `run.rb` + `transport.rb`/`runner.rb` over `/v1/responses`
  (`--mode perf|eval|both`; shares the transport with `loadtest.rb`, so `perf` mode
  closes **#6b**). Provisioning via `scripts/import_pack.rb`. ✅ done (this PR).
- **Fase B — LLM-judge** — `judge.rb`: scores the `rubric` at temp 0 (median over
  `--quorum`); unparseable → 0. Configured via `--judge-model` (mirrors the intent of
  the platform `utility_model`, #18). ✅ done (this PR).
- **Fase C — gating** — `baseline.rb`: `--baseline` blocks only on a **regression**
  (a passing case that now fails, or a judge score that dropped past `--tolerance`);
  `--update-baseline` accepts the current run. Known failures don't wedge the gate.
  ✅ done (this PR).
