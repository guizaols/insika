---
title: Embedding
parent: Ship it
nav_order: 4
permalink: /embedding/
---

# Embedding

Insika does not have to be a service you stand up next to your app. It can be an
object inside the app you already have: a graph you build in an initializer and a
Rack app you mount in your router. This page is the contract for doing that —
what an embedded graph owns, what it still shares with the process, and what that
makes your responsibility.

---

## The short version

```ruby
# config/initializers/insika.rb
INSIKA = Insika.embed(backend: Insika::Stores::SQLite.new(path: Rails.root.join("storage/insika.sqlite3").to_s)) do
  agent "support" do
    model "deepseek-v4-flash"
    provider :deepseek
    api_key ENV.fetch("DEEPSEEK_API_KEY")
    instructions "You answer questions about orders. Be brief."
  end
end

# turns are born as children of a long-lived supervisor, not of the request
INSIKA.runtime.graph.executor.supervised = true
```

```ruby
# config/routes.rb — the transport is lazy: `require "insika"` never loads it
require "insika/server/rack_app"

mount Insika::Server.rack_app(INSIKA, token: ENV.fetch("INSIKA_TOKEN")), at: "/ai"
```

```ruby
# anywhere in your app — no HTTP involved
INSIKA.reply("support", "where is order 8123?", session: current_user.id)
```

`Insika.embed` takes the same block as [`Insika.system`](AGENTS.md) and adds one
obligation: **you name the store**. That single argument is what turns "one
program" into "one object" — see [why](#why-the-store-is-an-argument) below.

`Insika::Server.rack_app` returns a plain Rack app. It routes on `PATH_INFO`, so
Rails' `mount` (and `Rack::URLMap`, and anything else that moves the prefix into
`SCRIPT_NAME`) leaves every route intact: mounted at `/ai`, the drop-in API is at
`/ai/v1/responses`.

---

## Why the store is an argument

The engine was not always one process — it was one *program*. Two graphs
built in the same Ruby process shared things they never declared:

| What | What actually happened |
|---|---|
| LLM credentials | one process-wide slot **per provider**: two graphs on `deepseek` with different keys, and the second one won **for both**. No error, no warning — agent A simply called the provider with tenant B's key. |
| The store | `INSIKA_DB` unset → each graph got its own in-memory store and nothing persisted; `INSIKA_DB` set → every graph opened the **same file** and read the others' agents, sessions and tasks. |

Neither failure raised. That is the whole reason the embed contract is written
down rather than left to good sense.

---

## The contract

### 1. A graph owns its store

Every durable thing — sessions, tasks, checkpoints, the outbox, delegations,
memory — belongs to the backend the graph was built with. Two graphs given the
**same** backend share all of it, by your choice. Two graphs given **different**
backends share nothing.

```ruby
support = Insika.embed(backend: Insika::Stores::SQLite.new(path: "storage/support.sqlite3")) { … }
ops     = Insika.embed(backend: Insika::Stores::SQLite.new(path: "storage/ops.sqlite3"))     { … }
# a session created in `support` does not exist in `ops`
```

### 2. A graph owns its LLM credentials

Provider keys and bases resolve through the graph's own
[`RubyLLM.context`](https://rubyllm.com) — an isolated dup of the configuration.
An embedded graph never mutates the global `RubyLLM.config`, and never reads
another graph's credentials. That holds for the turn itself *and* for everything
else in the graph that asks a model: the content-safety moderator and the output
validator ask on the same context the turn does.

It also holds for runtime reconfiguration. Editing a provider key in the Studio
(or dispatching `:upsert_llm_provider`) applies to **that graph only** — the
change is real, takes effect without a restart, and stops at the graph boundary.

### 3. The process still owns signals and the reactor

Draining in-flight turns on SIGTERM ([the process model](DEPLOY.md)) is a process
concern, not a graph concern: `Signal.trap` keeps only the last handler, so a
shutdown installed once per graph would drain the last graph and let the others
die mid-turn. An embedded graph therefore installs **nothing** behind your back.
You install it once, naming every graph:

```ruby
Insika::Shutdown.install(executors: [SUPPORT, OPS].map { |g| g.runtime.graph.executor })
```

One signal closes every graph's intake first, then waits — up to
`INSIKA_DRAIN_TIMEOUT` (default 20s) — for the in-flight turns of all of them.
Whatever outlives the deadline stays `:running` and is replayed by the next
boot's recovery sweep.

The reactor is yours too, and this one has teeth:

> **The mounted app needs an async server.** `rack_app` is a value — nothing in it
> starts a server or a reactor. A turn is a fiber, so the routes that start one
> (`POST /v1/responses`, `/v1/messages`, `/v1/commands`, `POST /channels/:id/events`)
> must be called from inside a running reactor. Under **Falcon** you already are.
> Under Puma or Unicorn they answer `500 {"error":{"message":"No async task
> available!"}}` — the read-only routes (`GET /v1/agents/:id`, `/v1/tasks/:id`, `/up`)
> are fine either way. Serve an embedded Insika from Falcon, or reach the graph
> in-process with `INSIKA.reply(...)`, which builds its own reactor.

And once you are inside one, set `supervised = true` (as in the quickstart): it
makes a turn a child of a long-lived supervisor instead of a child of the
request, so the turn survives a client disconnect. Without it the runtime cancels
the turn when the connection drops.

### 4. The Studio is not part of the embeddable surface

`rack_app` returns the `/v1` transport and nothing else. `Studio::App.configure`
freezes its collaborators on the **class**, which makes it one operator UI per
process: a second graph configuring the Studio replaces the first's wiring, for
both. So a host that wants the UI does a plain `require "insika/studio/app"`,
calls `Studio::App.configure` with exactly one graph's collaborators, and mounts
the class — accepting that the UI shows that graph and no other.

This is a stated limitation, not an oversight. Making the Studio instantiable is
its own change, and it needs its own reason.

### 5. ENV is a default, never a requirement

Anything an embedded graph reads from the environment has an injectable
equivalent, and the injected value wins. `INSIKA_DB` still works — it is the
default for the DSL quickstart and for `config.ru` — but an embedded graph that
was given a backend never looks at it.

---

## What you are responsible for

| Concern | Who |
|---|---|
| Which store each graph gets | You, via `backend:` |
| Which credentials each graph gets | You, via the agent's `api_key`/`provider` |
| Who may call the mounted app | You. `token:` is one shared Bearer for the whole mount — see below |
| Signals and the drain | You, once per process (`Shutdown.install(executors:)`) |
| The reactor / `supervised` | You, matching your server |
| Recovery of orphaned turns at boot | You, if you want it — the sweep is `Insika::Recovery`, wired by `Insika::Server::Boot` for the standalone deployment, not by `embed` |

### Embedding is not multi-tenancy

Two graphs stop corrupting each other. That is all this contract says. **Who is
allowed to talk to which graph** is authorization, and it is not here: `token:` is
a single Bearer gating the whole mounted app, exactly as it does for the
standalone server — the written decision is [one deployment, one token;
multi-tenancy belongs to the host](SECURITY.md#the-bearer-gate). If your app has
users, put the mounted app behind your own authentication and pass `session:`
yourself — do not hand the mount point to the browser.

---

## What this is not

- **Not a Rails engine.** `insika-rails` would be a separate gem; this is the Rack
  app such a gem would mount. The core has no Rails knowledge and takes no Rails
  dependency.
- **Not a second assembly path.** `Insika.embed` is a front door over the same
  pipeline `Insika.agent`/`Insika.system` use — the profile it produces is
  identical, and there is a spec that holds it to that.

---

## See also

- [Architecture](ARCHITECTURE.md) — how a turn actually runs.
- [Deploy](DEPLOY.md) — the standalone process model (N workers of *one*
  deployment), which is a different question from N graphs in one process.
- [Agents](AGENTS.md) — the DSL block `embed` takes.
