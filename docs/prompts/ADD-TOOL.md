---
title: Prompt — add a tool or skill
parent: Build an agent
nav_order: 11
permalink: /add-tool/
layout: default
render_with_liquid: false
---

# Add a tool, MCP server, or skill to my agent

> **You are a coding agent** (Claude Code, Codex, Cursor, …) reading this because a
> developer pasted a prompt pointing here. Treat this file as a **skill**: follow the
> steps in order and apply the RULES literally.

Your job: extend **one existing agent** with **one new capability** and prove it works
with one turn. Nothing more.

## Step 0 — Gather context (silently)

- **Which agent?** Find its `Insika.agent { … }` block (or its pack). If the developer
  has no agent yet, stop and build the minimal first agent instead — this file assumes
  one exists. Do not mix onboarding with capability.
- **A provider key in the environment**; ask if none is set.
- Read [`docs/TOOLS.md`](../TOOLS.md) (also served at `GET /docs/tools.md`) and, for
  skills, [`docs/SKILLS.md`](../SKILLS.md) before writing anything.

## Step 1 — Pick the kind (RULES, not taste)

| The need | The kind | Where it lives |
|---|---|---|
| Call an external HTTP API | **data tool** (`data_tool` in the DSL block) | a row in SQLite, editable at runtime |
| Logic must run in-process | **code tool** (a Ruby class `< RubyLLM::Tool`) | the deployment image |
| Adopt a whole external MCP server | **`mcp` instance** | durable config; its tools appear tagged `mcp:<name>` |
| Teach a procedure (no data fetching) | **skill** (`skill "name", description:, instructions:`) | loads on demand via `load_skill` |

Exactly one kind. A skill is not a tool; an MCP server is not five data tools.

## Step 2 — Build the smallest version

Data tool, via DSL (shape from
[`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/)):

```ruby
data_tool(
  "name"        => "convert_currency",
  "description" => "Latest reference exchange rate between two currencies.",
  "parameters"  => {
    "type" => "object",
    "properties" => {
      "from" => { "type" => "string", "description" => "source currency code" },
      "to"   => { "type" => "string", "description" => "target currency code" }
    },
    "required" => %w[from to]
  },
  "request"  => { "method" => "GET",
                  "url"    => "https://api.example.com/latest?from={{from}}&to={{to}}" },
  "response" => { "extract" => "body_raw" }
)
```

Skill, via DSL (from
[`examples/skills/`](https://github.com/guizaols/insika/tree/main/examples/skills/)):

```ruby
skill "refunds",
      description: "How to handle a refund request",
      instructions: <<~MD
        When a customer asks for a refund:
        1. If you don't have the order number, ask for it first.
        …
      MD
```

RULES:

- `parameters` is JSON Schema (safe subset — no `oneOf`/`$ref`); it reaches the model
  verbatim and arguments are checked against it at call time.
- Author the FINAL url: the HTTP client does not follow redirects, and the egress guard
  cleared that host only.
- Do not add a second capability "while we're here".

## Step 3 — Make sure it enters the tool-loop

Registered is not enough — the agent's policy allowlist decides. The DSL auto-enables
the allowlist policy, and the three-state rule applies (`nil` = all, `[]` = none,
`[names]` = exactly those; deny wins):

```ruby
tools %w[convert_currency]   # or tools_allow: [...] on the pack
```

A code tool can never be shadowed by a data tool of the same name — pick another name
instead of fighting it.

## Step 4 — Prove it with ONE turn

Run one `reply()` whose message forces the call ("how many BRL is 1 USD right now?").
The reply must use what the tool returned — if the model answers from imagination, the
tool did not run: re-check Step 3 before touching the prompt.

## Step 5 — Self-check

- [ ] One agent, one new capability, one proving turn with real output.
- [ ] The tool/skill is named in the allowlist (or absence was a deliberate "all").
- [ ] No secret in any file — keys live in the environment.
- [ ] No new gem dependency was added without asking.

## Hard constraints

- **Secrets stay in the environment.** `{{secret.*}}` resolves ONLY on the manifest
  write path (`POST /v1/tools/manifest`); written via DSL or Studio it fails
  registration. Tools authored outside a manifest ship literal values (masked on read).
- **The egress guard refusing a URL is a feature**, not a bug to disable globally.
  Report it; open an allowlist exception deliberately.
- **Config over code**: everything above is data the DSL generates (`to_pack`). If it
  seems to require reaching past the DSL, the answer is a DSL method you have not used
  yet — re-read the docs first.
