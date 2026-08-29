---
title: Templates
parent: Integrate
nav_order: 6
permalink: /templates/
---

# Templates

Example agents shipped **inside the gem** — `lib/insika/templates/<name>/`,
one DSL file per template. `insika new <name>` copies it for you to run and
edit; the same file is what the Studio gallery evaluates to create the
agent from a click. One source of truth, two doors — never a parallel pack
format to drift.

## The gallery

```bash
insika new --list
```

```
travel-planner     Starter    Weather + currency data-tools against keyless public APIs …
research-analyst   Advanced   Insika.system fan-out — three specialist subagents research …
daily-digest       Always-on  A recurring schedule plus save_artifact build and publish …
review-panel       Teams      Two specialists reviewed in parallel by a synthesizing lead …
repo-explorer      MCP        Live MCP tool-loop over http — answers questions about any …
browser-agent      MCP        Live MCP tool-loop over stdio — navigates and summarizes …
```

```bash
insika new travel-planner            # copies ./travel-planner/{agent.rb,README.md}
insika new travel-planner my-trip    # ...into ./my-trip/ instead
```

The CLI prints the exact run line, including any env the template needs
**set** (not just available as an override) — a stdio MCP template needs
`INSIKA_MCP_STDIO=1`, for instance. The generated script *is* the editing
surface: no Gemfile, no questionnaire, no placeholders to fill in.

The same roster appears as a "+ from template" gallery on the Studio
`/studio/agents` page — clicking **Create** dispatches the identical
`:create_agent` (and, for a system template, one per agent) the CLI-run
copy would produce. A template marked `studio: false` in its frontmatter
(none in wave 1) shows a "CLI-only for now" note instead of a button —
reserved for a template whose value is a durable workflow, until workflow
import into a running store exists.

## The MCP trail: point it at your own server

`repo-explorer` (http) and `browser-agent` (stdio) are not showcases for
one MCP vendor — they demonstrate exactly how to plug **any** MCP server
into an agent. Each ships with a working, keyless default so
`insika new` + the run line works with zero setup, but the server is a
config value:

```bash
MCP_URL=https://your-mcp-server/mcp DEEPSEEK_API_KEY=sk-... ruby repo-explorer/agent.rb "..."
MCP_COMMAND=your-mcp-server INSIKA_MCP_STDIO=1 DEEPSEEK_API_KEY=sk-... ruby browser-agent/agent.rb "..."
```

Swap the env var, rewrite the instructions for the new server's tools —
nothing else in `agent.rb` changes.

## Writing a template

A template is `lib/insika/templates/<name>/agent.rb` + `README.md`.

**The frontmatter contract** — a `# ---` … `# ---` comment block, YAML
inside, right after the standard `# frozen_string_literal: true` (that
magic comment is skipped automatically — a template doesn't have to break
the convention every other file in the gem follows):

```ruby
# frozen_string_literal: true

# ---
# title: My Template
# trail: Starter | Advanced | Always-on | Teams | MCP
# description: one line, shown in the CLI list and the Studio card.
# capabilities: comma, separated, tags
# studio: true            # optional, default true
# env: SOME_REQUIRED_VAR   # optional — env the run line must SET, not just may override
# requires: Node.js and npm   # optional — a local dependency beyond the gem + a provider key
# ---
```

**The two-doors mechanics**, in the file itself:

1. `require "insika"` — gem-style, never `require_relative` (the file gets
   copied out of the gem into an arbitrary directory).
2. Build the agent/system as a normal top-level local: `travel = Insika.agent(...) { ... }`.
3. Guard the CLI demo footer: `if __FILE__ == $PROGRAM_NAME ... end`. False
   whenever `Insika::Templates.evaluate` loads the file (never true from
   inside the gem/Studio process), so the Studio door never makes a network
   call, prints anything, or parses `ARGV`.
4. End the file with the **bare** built value (`travel`, `panel`, `team`,
   …) as its last expression — `evaluate` runs the file in an isolated
   `instance_eval` and returns whatever that last expression is. No
   registration call, no second format.
5. **No top-level constants.** `instance_eval`'s isolation keeps local
   variables and `def`s from leaking into the NEXT template evaluated in
   the same process, but Ruby scopes a `CONST = ...` assignment lexically,
   not by `self` — it would leak. Use a local variable (closures see it
   fine from inside a `do...end` block) — every wave-1 template does.

**Engine-only rules** (enforced by the lint below):
provider-agnostic (one provider key), zero tenant/store data, external
calls only to keyless public APIs, every tool/mcp group covered by an
explicit allowlist.

**Declaring an `mcp` server** auto-adds `"mcp:<name>"` to that agent's
`tools_allow_groups` (`Insika::DSL::Builder#mcp`) — without it the agent
could never call the MCP tool it just declared, since `PackImporter`
forces `tools_allow: []` for a pack with no `data_tool`. A **system**-level
`mcp` (declared outside any member `agent { }` block) grants no agent
access by itself — declare it inside the specific agent that needs it.

## The E3 lint

`spec/insika/templates_spec.rb` iterates `Insika::Templates.all` for real —
one example per template name, so a broken new template fails by name, not
a generic loop assertion. It checks, per template:

- evaluates cleanly to schema-valid pack(s) (`id`/`model` present);
- every `data_tool` it declares is in that SAME pack's `tools_allow`;
- every `mcp` instance's group is granted by SOME agent in the pack(s);
- every referenced host (`data_tool` URL, http/sse `mcp` URL) passes
  `Insika::EgressGuard.violation` — public HTTPS only, same guard a live
  turn would apply;
- no hardcoded secret-shaped literal (`sk-...`, a long `Bearer ...` token)
  in the source.

Run it before adding a template: `bundle exec rspec spec/insika/templates_spec.rb`.
