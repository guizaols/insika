# guardrails

Content safety, **opt-in and configured per agent** — no code. Guardrails run on
two sides of a turn:

- **Input** — deterministic detectors (prompt-injection, abuse) run *before* the
  model. A flagged input gets a safe refusal **without burning a model turn** — a
  flood or an injection can't even reach the provider. An optional LLM moderator
  can be added on top.
- **Output** — moderation plus PII/secret redaction on what the model streams
  back, and a post-turn validator.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/guardrails/guarded_agent.rb
```

Expected output (normal wording varies; the refusal is exact):

```
── normal ──
A good first language is Python — readable syntax and huge community …
── injection attempt ──
I can't help with that request.
```

## Configuration

`guardrails` is declarative and merges:

```ruby
guardrails input: true, output: true,
           strictness: "medium",             # low | medium | high
           moderator: "deepseek/deepseek-v4-flash",  # optional LLM moderator; omit for detectors only
           responses: { "injection" => "…", "default" => "…" }
```

- **Opt-in with a safe default.** An agent that configures nothing still gets the
  conservative default (deterministic detectors on, LLM moderator off).
- **Strictness → categories.** `low` = injection only; `medium`/`high` add sexual
  and abuse.
- **`responses` is config-over-convention.** The engine ships neutral refusals,
  but you override the reply per category (or a single `default`) so tone and
  language are yours — important for an OSS runtime used across businesses and
  locales.
