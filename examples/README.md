# Examples

One small, self-contained, runnable project per capability. Each is a few lines of
the public `Insika.agent { … }` DSL — the examples *are* the integration docs.

**Starting a new agent?** `insika new --list` shows a gallery of app-shaped
templates (travel planner, research team, daily digest, review panel, two
MCP demos) — one command gets you a running, editable agent. See
[Templates](../docs/TEMPLATES.md). The examples below stay focused on
*capabilities* (how the egress guard works, how a schedule fires) rather
than a finished app.

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
| [relay-channel/](relay-channel/) | Bring your own WhatsApp/Slack stack: the engine runs the turn, you deliver the reply | `ruby examples/relay-channel/support_agent.rb` |
| [scheduled-report/](scheduled-report/) | Recurring schedule (`schedule`) + `save_artifact` | `ruby examples/scheduled-report/report_agent.rb` |

| [agentic-workflows/](agentic-workflows/) | The five composition patterns: sequential, routing, parallel, evaluator, delegation | `ruby examples/agentic-workflows/sequential.rb` |
| [analytics/](analytics/) | MCP over http against a real, **key-authenticated** server ([OpenSEO](https://github.com/every-app/open-seo)) | `ruby examples/analytics/seo_agent.rb` |

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

## Several agents in one script

`Insika.agent` builds one agent; `Insika.system` builds a set of them sharing one
runtime — which is what delegation and every fan-out pattern need, since a child
must be resolvable in the same graph:

```ruby
system = Insika.system do
  agent("security")    { instructions "Review code for security issues." }
  agent("performance") { instructions "Review code for performance issues." }

  agent "reviewer" do
    instructions "Delegate to the specialists, then synthesize."
    subagents "security", "performance"
  end
end

system.reply("reviewer", code)   # target agent is always explicit
system.serve                     # all of them on /studio + /v1
```

Workflows are declared in the same block — `workflow "name", input:, output: do
|input, ctx| … end` — and every one of them is durable, schema-validated and
exposed over HTTP when served. See [Workflows](../docs/WORKFLOWS.md).
