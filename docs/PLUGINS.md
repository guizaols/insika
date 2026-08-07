---
title: Plugins
parent: Build an agent
nav_order: 7
permalink: /plugins/
---

# Plugins

Insika has **two tiers of extension**, and picking the right one is almost always
obvious once you ask a single question: *does this need Ruby to run in-process?*

| | **Tier 1 — data** | **Tier 2 — code** |
|---|---|---|
| What you write | JSON/YAML config | a Ruby gem (or a directory) |
| Ships as | a row in SQLite | a `.rb` file loaded at boot |
| Takes effect | **hot** — no restart | at the next restart |
| Can add | HTTP tools, MCP toolsets, skills, prompts | tools, workflows, capabilities, policies, middleware, hooks, context providers |
| Reach for it when | you are calling an external API | logic must run in-process, or you are extending the engine itself |

Tier 1 is the path for "the community adds integrations". Tier 2 is the path for
"the community extends the engine". Most integrations are tier 1, and you should
feel mildly suspicious of yourself when you reach past it.

## Tier 1 — extend with data

Nothing to install and nothing to deploy: a **data tool** is an HTTP call
described by config, and an **MCP import** turns a whole MCP server's toolset
into data tools in one call. Both are covered in [Tools](TOOLS.md) — the schema,
the `{{param}}` / `{{ctx.*}}` / `{{secret.*}}` placeholders, the four write paths,
and the egress guard.

Skills are the other half of tier 1: a `SKILL.md` is knowledge, not code, and it
can be authored in the Studio or shipped inside a pack. See [Skills](SKILLS.md).

## Tier 2 — extend with code

A code plugin is **a directory with a manifest**. The manifest is discovery
without execution: Insika reads and validates it first, and only then requires
your Ruby.

```
my-plugin/
├── insika.plugin.yml     # the manifest — always read first
├── plugin.rb             # the entry: defines a module with .register(api)
└── skills/               # optional: SKILL.md files shipped with the plugin
```

```yaml
# insika.plugin.yml
id: weather                     # unique; the id everything else keys on
name: Weather
description: Weather lookups. Ships the get_weather tool and a weather_report skill.
entry: plugin.rb                # required to register anything; omit for a skills-only plugin
module: WeatherPlugin           # must respond to .register(api)
contracts:                      # the PUBLIC surface — declared here or ignored
  tools: [get_weather]
  workflows: []
  capabilities: []
  channels: []
tool_metadata:
  get_weather:
    optional: false             # optional tools require per-agent opt-in
    side_effect: false          # true ⇒ not re-run on resume (checkpointed)
skills: [skills]                # directories, relative to the plugin root
prompts: []
```

```ruby
# plugin.rb
require "ruby_llm"

module WeatherPlugin
  class GetWeather < RubyLLM::Tool
    description "Looks up the current weather for a city"
    param :city, desc: "City name"

    def execute(city:) = { city: city, temp_c: 24, condition: "sunny" }
  end

  def self.register(api)
    api.register_tool("get_weather", GetWeather)
  end
end
```

Two runnable ones live in the repo:
[`plugins/weather`](https://github.com/guizaols/insika/tree/main/plugins/weather)
(the minimal shape) and
[`plugins/insika-code`](https://github.com/guizaols/insika/tree/main/plugins/insika-code)
(a real toolset: file read/write/edit, grep, shell — sandboxed, with the
side-effecting tools marked so an agent can gate them behind approval).

### What `register(api)` can register

| Call | Registers | Declared in `contracts`? |
|---|---|---|
| `register_tool(name, klass)` | a tool the model can call | **yes** — `contracts.tools` |
| `register_workflow(name, callable)` | a named workflow (see [Architecture](ARCHITECTURE.md)) | **yes** — `contracts.workflows` |
| `register_capability(name, tool:)` | an intent that resolves to a tool | **yes** — `contracts.capabilities` |
| `register_channel(name, instance)` | a way in and out for people (see [Channels](CHANNELS.md)) | **yes** — `contracts.channels` |
| `register_policy(name, klass)` | a policy for the resolution stage | no |
| `register_middleware(instance)` | a wrap around the turn pipeline | no |
| `register_context_provider(instance)` | a source of prompt context | no |
| `register_hook(:tool, before:, after:)` | alters one stage's input/output (`:task`, `:prompt`, `:agent`, `:tool`) | no |

Anything addressable by name must be declared in `contracts`; registering an
undeclared name logs a warning and is **ignored**, so a plugin cannot quietly
widen its own surface between versions. For a channel the name is also a URL
segment (`/channels/<name>/events`), so the declaration is what stops a plugin
from mounting a route nobody asked for.

`api.config` returns the manifest's `config` hash, frozen.

### Failure is contained, and quiet

Registration is staged and committed atomically: if `register(api)` raises
halfway through, everything it staged is rolled back and the plugin is
discarded. **Boot continues** — one bad plugin must not take the deployment
down.

> ⚠️ The cost of that choice: a broken plugin is a `warn` on stderr, not a crash.
> If a tool is missing, check the boot log and the `:plugin_loaded` events before
> suspecting the allowlist.

The same posture applies to config: if `config_schema` is present and `config`
fails it, the plugin is **skipped** (fail-closed) with the validation errors
printed. The validator is a deliberate subset of JSON Schema — `type`,
`properties`, `required`, `additionalProperties`, `enum` — and an unsupported
keyword is itself an error rather than being silently ignored.

### Discovery and enabling

Plugins come from three kinds of root, and they differ in **who has to say yes**:

| Root | How it is found | Enabled by default |
|---|---|---|
| **Gem** | the gem calls `Insika::Plugin.announce(__dir__)` when its `lib/` loads | **yes** — installing it is the consent |
| **Workspace** | a directory in the deployment's plugin roots | no — must be listed in `enabled:` |
| **Bundled** | `plugins/` in this repo | no — must be listed in `enabled:` |

`disabled:` is an absolute veto: an id listed there never loads, even if it is
also in `enabled:` (deny wins, the same rule as every allowlist in the engine).

A gem announces itself explicitly — Insika never scans the load path or your
installed gems:

```ruby
# lib/insika-plugin-acme.rb
require "insika/plugin"
Insika::Plugin.announce(File.expand_path("../..", __dir__))
```

Discovery details worth knowing: the manifest may be named `insika.plugin.yml`
(preferred) or `plugin.yml` (deprecated — it warns); one manifest per directory,
with `insika.plugin.yml` winning if both exist; and if two roots ship the same
`id`, the **first root wins** and the second is skipped.

### Secrets

Put the *name* of the environment variable in the manifest, never the value:

```yaml
config:
  api_key_env: ACME_API_KEY
config_schema:
  type: object
  required: [api_key_env]
  properties:
    api_key_env: { type: string }
```

The manifest is committed; the secret is not. This mirrors how data tools handle
`{{secret.*}}`.

## Publishing a plugin

- **Name it `insika-plugin-<thing>`.** The convention *is* the registry for now:
  a predictable RubyGems prefix plus a curated list here beats a hub nobody has
  had a reason to build yet.
- **Announce in your gem's entry file** (above), so installing it is enough.
- **Treat `contracts` as your public API.** Renaming a tool, changing its
  parameters, or adding a `required` config key are breaking changes for the
  agents that allowlist them by name. Version accordingly.
- **Do not require `insika` at load time** if you can avoid it —
  `insika/plugin` is deliberately dependency-free so a plugin gem can announce
  itself before anything else of ours is loaded.

> **Compatibility, stated honestly:** Insika is pre-1.0 and nothing is tagged
> yet. The manifest keys and the `register(api)` surface above are what a plugin
> depends on; changes to them are listed in
> [`CHANGELOG.md`](https://github.com/guizaols/insika/blob/main/CHANGELOG.md).
> Until 1.0, pin the engine version you tested against.

## Choosing a tier

| You want to… | Tier |
|---|---|
| call a REST API the model can invoke | **1** — data tool |
| adopt an existing MCP server's tools | **1** — MCP import |
| add domain knowledge or a procedure | **1** — a skill |
| touch the filesystem, run a subprocess, hold state in-process | **2** |
| add a policy, a middleware, or a context provider | **2** |
| package the above for other deployments to install | **2**, as a gem |

## See also

- [Tools](TOOLS.md) — data tools, MCP ingestion, allowlists, and the egress guard.
- [Skills](SKILLS.md) — `SKILL.md`, progressive disclosure, and skill packs.
- [Sandbox](SANDBOX.md) — confining a code plugin that touches the filesystem or shell.
- [Architecture](ARCHITECTURE.md) — where plugins hook into the turn pipeline.
