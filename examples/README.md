# Examples

One small, self-contained, runnable project per capability. Each is a few lines of
the public `Insika.agent { … }` DSL — the examples *are* the integration docs.

All of them need a provider key (the demo uses DeepSeek):

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/<name>/<file>.rb
```

| Example | Capability | Run |
|---------|------------|-----|
| [hello-agent/](hello-agent/) | The smallest agent; one turn, or `serve` as a server | `ruby examples/hello-agent/hello.rb` |
| [data-tool/](data-tool/) | A tool defined as **data** (declarative HTTP) + the egress guard | `ruby examples/data-tool/currency_agent.rb` |
| [skills/](skills/) | Progressive skill loading (`load_skill`) | `ruby examples/skills/skill_agent.rb` |
| [memory/](memory/) | Cross-session memory (`remember`) | `ruby examples/memory/memory_agent.rb` |
| [guardrails/](guardrails/) | Content-safety guardrails, opt-in per agent | `ruby examples/guardrails/guarded_agent.rb` |

Plus the flagship:

- [insika-code/](insika-code/) — a Claude-Code-style coding agent built entirely
  *on top of* the engine (FS/shell tools behind the human-approval gate, sandbox,
  the `/v1/responses` contract). A full deployment, not a one-file DSL script.

And the top-level [quickstart.rb](quickstart.rb) — the ≤10-line version from the
README.

## The pattern

Every example uses the same DSL, and the DSL only ever **generates data**:
`Insika.agent { … }.to_pack` is the same portable pack the control UI and
`POST /v1/agents` consume. Nothing here is a special path — a hand-written pack
produces a byte-identical agent.

Swap `.reply(msg)` for `.serve` in any of them and you get the control UI
(`/studio`) plus the drop-in `/v1/responses` API for that same agent.

## Not yet shown (DSL surface in progress)

`subagents` (fan-out delegation) and exposed `workflows` are engine capabilities
that don't yet have a DSL setter, so they aren't one-file examples here. Until
then, see the full deployment wiring in `config/deployment.rb`.
