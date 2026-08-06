# Evals — the quality harness

Behavior tests for the agent, end-to-end. Where RSpec (`spec/`) is the
deterministic unit net and `scripts/loadtest.rb` measures perf, **evals** answer
"did the agent still behave well?" after a prompt/tool/model change — the net that
was missing (FOLLOWUP §9 / #10). Design: **RFC-0008**.

It lives OUTSIDE the core: nothing under `lib/insika/**` requires it. Like the
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
  BASELINE.md           documented quality baseline (#6b / G2) — number+date+pack
  baseline.json         machine gate — captured from a real green run (Fase C)
  reports/              run outputs
```

The accepted quality baseline for the real-traffic set lives in **`BASELINE.md`**
(prose: number, date, pack, per-case justification). The machine gate `baseline.json`
is captured from a real green run (`--update-baseline`), not hand-authored.

## Running

The runner replays the golden set against a **running** engine over the same
`POST /v1/responses` surface as `scripts/loadtest.rb`. It's on-demand (not CI): it
needs a live provider key on the server + the target agents provisioned.

```bash
# 1. boot the engine (dev): DEEPSEEK_API_KEY=… ruby scripts/serve_real.rb
# 2. provision the target agent(s) from the real packs (client; POST /v1/agents):
INSIKA_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=local-demo \
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
id: loja-chocolates-produto-com-cep  # unique case id
agent: loja-chocolates       # target agent id (must match the provisioned agent)
turns:                       # the conversation to replay, in order
  - user: "meu CEP é 01310-100. quero um chocolate ao leite sem lactose até R$ 50"
expect:
  tools_called:              # required tools; a trailing "?" = OPTIONAL (never fails)
    - search_products
    - recommend_products?
  must_not:                  # named negative detectors
    - pii_leak               #   CPF/CNPJ/credential in the output
    - tool_error             #   any failed tool call in the turn
  rubric: |                  # LLM-judge criterion (Fase B)
    Com o CEP em mãos, busca no catálogo e apresenta opções coerentes…
  min_score: 0.7             # judge threshold
```

### The committed set

Two layers, by intent:

- **`golden/safety/` — the generic guardrail net (OSS default).** Brand-free,
  **bilingual (EN + pt-BR)** adversarial cases against a fictional `example-agent`:
  prompt injection, system-prompt exfil, verbal abuse, sexual content, plus
  false-positive guards. Tests the **guardrail** (RFC-0009), not any business — the
  deterministic block cases run with **no provider key** (CI-able smoke). See
  `golden/safety/README.md`. Provision the target with `ruby scripts/serve_eval.rb`.
- **`golden/loja-*/` — real-world reference corpus (ANONYMIZED).** Curated from the
  **real** OpenClaw corpus (pt-BR retail). The conversations are real; the store
  BRANDS were removed for OSS — generic ids/rubrics (`loja-cosmeticos` /
  `loja-chocolates` / `loja-eletronicos`), never the real names. Reference of real
  traffic, not the OSS face.

The real store set — tool names grounded in each store's `TOOLS.md`
(`search_products` / `recommend_products` / `search_faq` / `search_voucher` /
`search_orders` / `call_support`):

- **loja-chocolates** — greeting, CEP-gated search (with/without CEP), FAQ, order
  status, voucher, human handoff.
- **loja-cosmeticos** — product discovery, order-status (angry), **and real adversarial
  turns**: a base64 prompt-injection/exfil, a fabricated-discount social-engineering
  attempt, verbal abuse, an inappropriate request. These double as guardrail evals
  (§9 / #11) — see also the brand-free `golden/safety/` suite.
- **loja-eletronicos** — notebook/tablet discovery, greeting.

> **Agent ids:** goldens target `loja-chocolates` / `loja-cosmeticos` /
> `loja-eletronicos`. Provision the matching agents (see below) or adjust the
> `agent:` field to your ids. The same corpus + replay also serves the real-traffic
> loadtest (#6b) — one replay, two
> purposes.

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

## Where the code and the cases live (RFC-0013 §3.7)

The harness moved to **`lib/insika/evals/*`** (`Insika::Evals::…`) so the engine can
call it — the refinement gate has to score a candidate agent with the SAME judge, and a
second copy of the judge would be the worst possible outcome. It is still a CLIENT of a
running deployment (HTTP through `POST /v1/responses`, never a store read), and
`run.rb` is a thin CLI over it.

The cases moved too, in the sense that a DEPLOYMENT reads them from its store:

- `evals/golden/**` (here) — the curated corpus: reviewable in a pull request, carries
  the comments that explain each case, and is the seed for a fresh deployment.
- the store — what a run uses when there is one, editable in **Studio → Evals**. The
  rubric is the part of an eval a domain owner can actually write, and asking them for
  a git branch means it never gets written.

```bash
insika evals:import                    # corpus -> store
insika evals:import --keep-existing    # keep what was authored in the Studio
insika evals:export --dir /tmp/cases   # store -> YAML, at the paths it came from
ruby evals/run.rb --source dir         # ignore the store entirely
```

`evals:export` refuses to overwrite this directory without `--force`: `YAML.dump` drops
the comments, and they are half of why the corpus is readable.

The **judges** are configuration now (Studio → Settings → Evals, or
`settings["evals"]`): a panel of distinct models, with `aggregate` and
`min_agreement`. `--judge-model` still overrides for a one-off. See `docs/EVALS.md`.
