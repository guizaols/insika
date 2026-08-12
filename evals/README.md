# Evals — the quality harness

Behavior tests for the agent, end-to-end. Where RSpec (`spec/`) is the
deterministic unit net and `scripts/loadtest.rb` measures perf, **evals** answer
"did the agent still behave well?" after a prompt/tool/model change — the net that
was missing.

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
  reports/              run outputs (gitignored)
  internal/             deployment-specific material (gitignored — see below)
```

The repo ships **no accepted baseline**. A baseline is per-deployment data — it
says how *your* agents scored against *your* golden set — so it is captured from
a real green run (`--update-baseline`), never hand-authored, and never committed:
`evals/baseline.json` and `evals/internal/` are gitignored. Keep your documented
baseline (prose: number, date, pack, per-case justification) in
`evals/internal/BASELINE.md` and any store-specific golden sets under
`evals/internal/golden/`.

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
corpus — that's the real-traffic loadtest, since it's the same transport as
`loadtest.rb` but driven by real conversations. The runner **exits non-zero** if any
eval case fails (the seed of the pre-merge gate).

### LLM-judge (rubric scoring)

A golden's `rubric` is scored by an LLM-judge when a judge model is configured;
otherwise the case stays `judge_pending` (deterministic checks still run). The judge
runs at temperature 0 and, on a borderline case, a `--quorum` takes the median of N
samples. An unparseable judge reply scores 0 (fails) — never a silent pass.

```bash
DEEPSEEK_API_KEY=… OPENCLAW_GATEWAY_TOKEN=local-demo \
  ruby evals/run.rb --judge-model deepseek-v4-flash --quorum 3 --mode eval
```

Judge flags: `--judge-model` (or `EVAL_JUDGE_MODEL`), `--judge-provider`, `--quorum`,
`--no-judge`. Mirrors the intent of the platform `utility_model` (#18) — a cheap
model for internal tasks.

### Gating against a baseline

`evals/baseline.json` (gitignored — captured, not committed) is the accepted state
of the set. A gated run blocks only on a
**regression** — a passing case that now fails, or a judge score that dropped past
`--tolerance` (default 0.05). Known-failing cases don't wedge the gate; a brand-new
case absent from the baseline shows in the report but never blocks.

```bash
ruby evals/run.rb --update-baseline     # accept the current run as the baseline
ruby evals/run.rb                        # gates against evals/baseline.json if present
ruby evals/run.rb --baseline other.json --tolerance 0.1
```

With no baseline file at all, the run falls back to "fail if any case failed".

**The baseline also lives in the store, per agent.** The pre-merge gate above reads
the file, which is right for a checkout. The [refinement gate](../docs/REFINEMENT.md)
does not have one — it runs inside a deployment — so the accepted state is also a
record per agent, and the file is its export:

```bash
insika evals:baseline import     # split baseline.json into per-agent records
insika evals:baseline show       # what each agent's accepted state covers
insika evals:baseline export     # back to one file, for a pull request
```

`import` resolves each case's agent through the golden store, so run
`insika evals:import` first. A case the store does not know is **reported, not
guessed at** — silently dropping it would shrink the accepted state, and a smaller
baseline is a weaker gate.

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
requires:                    # what the DEPLOYMENT must have, else the case is SKIPPED
  tools:                     #   resolved against GET /v1/agents/:id (allowlist − deny)
    - search_products
  capabilities:              #   flat strings from the agent's `capabilities_declared`
    - promotions
expect:
  tools_called:              # required tools; a trailing "?" = OPTIONAL (never fails)
    - search_products
    - recommend_products?
  must_not:                  # named negative detectors
    - pii_leak               #   CPF/CNPJ/credential in the output
    - tool_error             #   any failed tool call in the turn
  policy: ask_once           # how much this store wants the agent to ask (optional)
  rubric: |                  # LLM-judge criterion
    Com o CEP em mãos, busca no catálogo e apresenta opções coerentes…
  min_score: 0.7             # judge threshold
reference:                   # the INCUMBENT's real conversation, same opening (optional)
  source: "helpdesk chat 3440…"
  messages:
    - role: user
      text: "meu CEP é 01310-100…"
    - role: assistant
      text: "temos sim, segue…"
      origin: operator       #   a HUMAN typed this one ⇒ the pair is `vs: human-assisted`
```

### `requires` — the third outcome

A case that asserts `search_orders` is not a failure for a store without order
tracking; it is a case that should never have run. The runner asks the deployment
(`GET /v1/agents/:id`) before spending a turn and reports **skipped, with the reason**.

House rule applied to this corpus: **a case that asserts a required tool declares it**
— the seven cases with a non-optional `tools_called` now carry the matching `requires`.

Edges, all deliberate: an OPEN allowlist (`tools: null`) runs the case; an unreadable
deployment runs it too and the CLI warns once; the gate never blocks on a skip and
`--update-baseline` omits skipped cases, but **pass→skipped IS a regression** — the
agent lost a tool.

### `policy` — how much the agent should ask before acting

Per STORE, not universal: sometimes the agent should establish the objective before
searching, sometimes asking again is the failure. Omit it and only the rubric decides.

| policy | deterministic check | the judge is told |
|---|---|---|
| `ask_once` | no reply contains more than one question | two questions in one message is a failure |
| `investigate_first` | turn 1 asks something and calls no tool | ask on a vague request, don't search immediately |
| `act_fast` | turn 1 calls a tool | asking what a search would answer is a failure |

Both halves fire: the check costs nothing and cannot flake, and the same policy goes
into the judge's prompt (a judge that is not told the store's rule guesses it).
Question counting is crude on purpose — a run of `?` counts once and URLs are dropped
first — and it already caught a real violation of a rule written in a store's own
prompt: *"é pra você ou tá pensando em presentear alguém? E qual seu tamanho?"*

Unlike `tools_called` and `must_not`, the policy is checked on **every** turn, not
only the last: "one question per reply" is a rule about each reply.

### `reference` — pairwise against the incumbent

`--pairwise` compares the replayed conversation against the reference one: same
opening, two transcripts, one question — *which served the customer better?*
`better` / `comparable` / `worse`, plus `split` (judges disagree) and `unknown`
(nobody answered readably). It **never** changes pass/fail and never enters the gate:
that verdict answers "can we replace it", not "did something regress".

Three rules, each of them the difference between a number worth quoting and one that
is not: the judge sees "A" and "B" and is never told which is ours; every judge is
asked **twice with the sides swapped** and a verdict that flips is reported as
`comparable` + `order-dependent`; and any reference message carrying
`origin: operator` labels the pair `vs: human-assisted`, counted separately in the
summary. The judge is not told a human typed it — it grades the conversation as the
customer received it — the READER is, which is where the fact changes a decision.

**Nothing in this corpus declares a `reference` yet, on purpose.** A real pair is a
real customer's transcript; the ones we have belong to a production store and are not
committable. They are authored where the import runs. Same discipline as `policy`:
the format is here, an invented example would not be evidence of anything.

Cost: 2 provider calls per judge per case.

### The committed set

Two layers, by intent:

- **`golden/safety/` — the generic guardrail net (OSS default).** Brand-free,
  **bilingual (EN + pt-BR)** adversarial cases against a fictional `example-agent`:
  prompt injection, system-prompt exfil, verbal abuse, sexual content, plus
  false-positive guards. Tests the **guardrail**, not any business — the
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
  — see also the brand-free `golden/safety/` suite.
- **loja-eletronicos** — notebook/tablet discovery, greeting.

> **Agent ids:** goldens target `loja-chocolates` / `loja-cosmeticos` /
> `loja-eletronicos`. Provision the matching agents (see below) or adjust the
> `agent:` field to your ids. The same corpus + replay also serves the real-traffic
> loadtest — one replay, two purposes.

## Two evaluation layers

- **Deterministic:** `tools_called` / `must_not` / `policy` are pure
  checks over the turn's tool events + output text. Zero tokens, zero flakiness —
  catches the gross regressions (a tool stopped being called, a secret leaked, a tool
  errored, the agent asked three things at once).
- **LLM-judge:** a rubric-scored pass using the `utility_model` (Settings)
  at temperature 0. A golden with a `rubric` reads as **judge-pending** until
  then — never a silent pass.

## Layers

- **Deterministic engine** — loader + deterministic asserts + report. Unit-tested
  offline.
- **Runner** — `run.rb` + `transport.rb`/`runner.rb` over `/v1/responses`
  (`--mode perf|eval|both`; shares the transport with `loadtest.rb`). Provisioning
  via `scripts/import_pack.rb`.
- **LLM-judge** — `judge.rb`: scores the `rubric` at temp 0 (median over
  `--quorum`); unparseable → 0. Configured via `--judge-model` (mirrors the intent of
  the platform `utility_model`).
- **Gating** — `baseline.rb`: `--baseline` blocks only on a **regression**
  (a passing case that now fails, or a judge score that dropped past `--tolerance`);
  `--update-baseline` accepts the current run. Known failures don't wedge the gate.

## Where the code and the cases live

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
