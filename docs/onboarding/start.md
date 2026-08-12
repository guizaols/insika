# Insika — build your first agent

> **You are a coding agent** (Claude Code, Cursor, an IDE assistant, …) reading this
> on behalf of a developer who just pointed you at a running Insika. Treat this file
> as a **skill**: follow the steps in order, apply the RULES literally, and stop at the
> self-check. Do **not** improvise beyond it.

Insika is a Ruby runtime for LLM agents in production. Your job here is the smallest
possible one: get the developer a **first working agent**, defined in Ruby with the
public DSL (`Insika.agent { … }`), talking to a real model — nothing more.

The machine-readable list of models this engine already knows about is at
**{{MODELS_URL}}** — fetch it before you write any `model`/`provider` line. The full
docs are mirrored as raw markdown under **{{DOCS_URL}}**.

---

## Step 0 — Gather context (do this first, silently)

RULES — verify, do not assume:

- **Ruby ≥ 3.3.** Run `ruby -v`. If lower, stop and tell the developer; do not try to
  upgrade Ruby for them.
- **The gem/library must be loadable.** In a project that already depends on Insika,
  `require "insika"` works. Otherwise add it to the `Gemfile` (or `bundle add`) — do
  not vendor or copy source files.
- **A provider key must come from the developer, via the environment.** Look for one
  already exported (e.g. `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`). If none is set, **ask
  the developer for the provider and confirm the env var is exported.** See the hard
  constraint on keys below.
- **Fetch {{MODELS_URL}}.** It tells you which providers and model ids this engine is
  configured for, the platform default, and the valid `thinking` levels. Use those
  exact ids.

## Step 1 — Decide (RULES, not taste)

| Question | RULE |
|---|---|
| How many agents? | **Exactly one.** A first agent is a single `Insika.agent`. Resist adding a second. |
| Which model/provider? | Use an id from **{{MODELS_URL}}**. If it lists a `default`, use that. Never guess a model id. |
| Where does it live? | One new Ruby file (e.g. `my_agent.rb`), or extend `examples/quickstart.rb` if present. One file. |
| Tools / skills / memory? | **None yet.** Ship a plain conversational agent first; add capability only after it replies. |
| Reply or serve? | Start with `reply` (one in-process turn). Only switch to `serve` once `reply` works. |

## Step 2 — Build (exact shape)

Write **one** file. This is the whole program:

```ruby
require "insika"

assistant = Insika.agent("assistant") do
  provider :deepseek            # ← the provider slug from {{MODELS_URL}}
  model "deepseek-v4-flash"         # ← a model id from {{MODELS_URL}}
  instructions "You are a concise, friendly assistant. Answer briefly."
end

puts assistant.reply(ARGV.join(" ").empty? ? "hi, what can you do?" : ARGV.join(" "))
```

Notes that are RULES, not options:

- The block is **config that generates data** — `assistant.to_pack` is a plain
  provisioning pack. Do not reach past the DSL into internal classes; everything a
  first agent needs is a DSL method (`model`, `provider`, `instructions`, `tools`,
  `skill`, `memory`, `temperature`, …).
- The provider key is read from the environment by name (`<PROVIDER>_API_KEY`). Do
  **not** write it into the file, the DSL, or a committed config.

## Step 3 — Run it

```bash
bundle install
DEEPSEEK_API_KEY=sk-... ruby my_agent.rb "hi, what can you do?"
```

Once that prints a reply, turning the same agent into a server is one line — swap
`reply` for `serve`:

```ruby
assistant.serve   # control UI at /studio  +  drop-in POST /v1/responses on :9292
```

Over the drop-in API the `model` field is the **agent id**:

```bash
curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" \
  -H "Content-Type: application/json" \
  -d '{"model":"assistant","user":"chat-1","stream":true,"input":"hi"}'
```

## Step 4 — Self-check before you report done

- [ ] `ruby -v` is ≥ 3.3.
- [ ] The `model`/`provider` you wrote appear in **{{MODELS_URL}}**.
- [ ] The provider key is exported in the environment, **not** written into any file.
- [ ] Running the file printed a real model reply (not an auth/model error).
- [ ] Exactly one agent, one file. No tools, skills, workflows, or extra agents added
      "to test things".

If any box is unchecked, fix that one thing — do not add scope to work around it.

---

## Hard constraints (known failure modes — never do these)

- **Never invent, guess, or hard-code an API key.** If no key is available, ask. A
  placeholder like `sk-xxxx` is not a fix — it produces a confusing auth failure.
- **Never guess a model id.** Use only ids from {{MODELS_URL}}. A wrong id fails at
  the provider, not in the engine, and wastes the developer's time.
- **Do not create a workflow, tool, or second agent just to test the first one.** The
  test is `reply` / one `curl`. Extra machinery is scope you were not asked for.
- **Do not bypass the DSL / config-over-code.** If something seems to need a private
  class, it is almost certainly a DSL method you have not used yet — check the docs at
  {{DOCS_URL}} before reaching deeper.
- **Keep secrets in the environment.** No keys in source, in the pack, or in commits.

## Where to go next

- **{{MODELS_URL}}** — live list of configured models, the default, and `thinking` levels.
- **{{DOCS_URL}}** — the docs index (README, running locally, deploy, guardrails, …), raw markdown.
- Add capability only after the first reply works: `tools`, `skill`, `memory`,
  `temperature`, `data_tool` — each is a DSL method documented in the README.

This is `rails new` reimplemented as a prompt — and you are the generator.
