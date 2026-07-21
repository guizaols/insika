# Quality baseline — `loja-chocolates` (real-traffic set, #6b)

> **Accepted baseline: 4/7 passing.** Set: `golden/loja-chocolates/` (7 cases).
> Pack: anonymized from `agent-store-cacau-show` (real OpenClaw corpus, pt-BR retail).
> Judge: `deepseek-chat`, temp 0, `--quorum 3`, `min_score 0.7`.
> Source run: **2026-07-20** against achei-b2b **dev** (`localhost:3000`) with the real
> toolset, plus the `status-pedido` gold fix landed with this doc (2026-07-21).

This is the **documented baseline** that FOLLOWUP §12 **G2** allows in place of a hard
7/7 ("rerun até 7/7 — **ou baseline menor documentado com justificativa**"). The
plumbing was declared **GO** on 2026-07-20 (tools hit achei-b2b and return 200, 40/40,
0 errors; prompt-cache engages at the real ~27k identity; conc=8 clean). None of the
open failures is a harness defect — they are gold or **pack** issues, and pack quality
is owned by achei-b2b, not the harness (product decision, §11/§12).

## Per-case state

| # | Case | Verdict | Owner | Justification |
|---|------|---------|-------|---------------|
| 1 | `saudacao` | ✅ pass | — | Cordial opening, no invented catalog. |
| 2 | `produto-sem-cep` | ✅ pass | — | Correctly asks for the CEP before searching (CEP gates the CD). |
| 3 | `escalacao-humano` | ✅ pass | — | Escalates via `call_support`, no invented SLA. |
| 4 | `status-pedido` | ✅ pass *(after gold fix)* | harness (fixed) | **Was a gold defect, not a miss.** The deterministic `tools_called: [search_orders]` contradicted the case's own rubric, which explicitly permits asking for the order number first; the judge scored the ask-first turn **1.0**. Fixed here → `search_orders?` (optional), mirroring `produto-sem-cep`. The rubric carries the quality judgment. |
| 5 | `cupom` | ❌ known-fail | **achei-b2b pack** | The agent has **no voucher tool in its allowlist**, so `search_voucher` can't be called. The gold is *correct* (the store should be able to report an active coupon) — left failing on purpose so the gap stays visible. **Fix = add a voucher tool to the agent's allowlist** (pack side); do **not** weaken the gold. |
| 6 | `faq-troca` | ❌ known-fail | **achei-b2b pack** | `search_faq` returns 200, but the agent **escalates to a human** instead of presenting the policy. Prompt-quality gap in the Cacau Show pack. |
| 7 | `produto-com-cep` | ❌ known-fail | **achei-b2b pack** | With the CEP in hand the agent calls `search_products` ~4× and **gives up**, even though the catalog *does* contain a matching item ("Tablete laCreme Zero Lactose"). Prompt/tool-loop quality gap in the pack. |

**4/7** is the accepted harness+gold baseline. The 3 open cases (5–7) are all
achei-b2b-owned and do **not** touch the critical path of a production conversation
(they are quality/coverage, not correctness of the engine).

## What this baseline is NOT

- It is **not** a machine gate yet. `evals/baseline.json` (the Fase-C regression gate,
  see `README.md` §"Gating against a baseline") is intentionally **absent** — it must be
  captured from a real green run via `ruby evals/run.rb --update-baseline`, not
  hand-authored (hand-writing scores would be fabricating eval results). Capture it at
  the **G8 shadow** step, once the harness is pointed at the production achei-b2b. Until
  then a run with no baseline falls back to "fail if any case failed" — expected, given
  the 3 documented known-failures.
- Numbers 1–4 above reflect the **2026-07-20** run; case 4 is asserted from that run's
  data (judge 1.0, only the strict tool-assert failed) plus the gold fix — a confirming
  rerun belongs to G8.

## Reproduce (real-traffic)

See `README.md` §"Running" and `docs/internal/BENCHMARKS.md` §4d. In short: boot
`scripts/serve_real.rb` with a provider key + the EgressGuard allow vars
(`HARNESS_EGRESS_ALLOW_HTTP/PRIVATE/HOSTS` — see the localhost-tools gotcha), provision
the agent via `scripts/import_pack.rb`, create real sim-chats and map them with
`--conv-map` (the tool contract needs a real Chat UUID as `X-Chat-Id`), then:

```bash
DEEPSEEK_API_KEY=… OPENCLAW_GATEWAY_TOKEN=local-demo \
  ruby evals/run.rb --base-url http://localhost:9292 \
    --agent loja-chocolates --judge-model deepseek-chat --quorum 3 --mode eval
```

**Hygiene:** any sim-chats created for a run must be deleted afterward (children in the
FK tables first). The #6b sim-chats were cleaned up on 2026-07-20; verified **0**
residual `simulation = true` chats in `achei_b2b_development` on 2026-07-21.
