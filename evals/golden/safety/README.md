# Safety suite — the generic, brand-free guardrail net

Domain-neutral, **bilingual (EN + pt-BR)** guardrail regression cases against a
fictional `example-agent`. Unlike the store corpora (`loja-cosmeticos/`,
`loja-chocolates/`, `loja-eletronicos/` — real pt-BR retail traffic with brands
anonymized, kept as real-world reference), this suite tests
the **guardrail itself**, not any business: prompt injection, system-prompt exfil,
verbal abuse, sexual content. Attacks are universal, so the cases carry no brand and
frame different domains (SaaS support, banking, generic shop).

## Why it's the OSS default

- **Brand-free + bilingual** — a contributor in any domain/language can relate to it,
  and it exercises both languages the deterministic detectors ship (EN + pt-BR).
- **Runs with NO provider key** — every `injection-*/abuse-*/sexual-*` case is blocked
  by the *deterministic* input guardrail before any LLM call, so the deterministic
  `must_not: pii_leak` checks pass offline (the rubrics stay `judge-pending` without a
  judge — never a silent pass). This is the guardrail smoke that can run in CI.
- **False-positive guards** — `benign-faq-*` are legitimate questions the guardrail
  must NOT block. These DO reach the LLM (need a provider key); a safe-refusal here
  would be a false positive.

## Running

```bash
# keyless: the deterministic block cases (no benign, no judge)
ruby scripts/serve_eval.rb &                       # seeds `example-agent`, guardrails on
OPENCLAW_GATEWAY_TOKEN=local-demo ruby evals/run.rb \
  --base-url http://localhost:9292 --agent example-agent \
  --golden-dir evals/golden/safety --mode eval

# full: add a key for the benign cases + the LLM-judge
set -a; . ./.env.local; set +a
ruby scripts/serve_eval.rb &
OPENCLAW_GATEWAY_TOKEN=local-demo ruby evals/run.rb \
  --base-url http://localhost:9292 --agent example-agent \
  --golden-dir evals/golden/safety --judge-model deepseek-v4-flash --mode eval
```

## Adding your own scenarios / tools / languages

The corpus is just data — the engine is a generic `/v1/responses` client:

- **New attack / language:** drop a `*.yml` here. If it's a language the deterministic
  detectors don't cover, enable the LLM moderator on the agent (`guardrails.moderator`)
  — it's language-agnostic. To harden the deterministic tier for a language, add
  patterns to `Insika::Safety::Detectors` (single source).
- **Tool scenarios:** point `--golden-dir` at your own corpus and provision an agent
  that has those tools; `tools_called` checks match tool *names* from the stream, so
  any toolset works.
- **Your business voice:** the safe replies are per-agent (`guardrails.responses`)
  — nothing here bakes in tone.
