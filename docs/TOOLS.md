---
title: Tools
parent: Build an agent
nav_order: 2
permalink: /tools/
---

# Tools

A **tool** is a function the model can call inside a turn. Insika has three
kinds, and the distinction that matters is **who can change one at runtime**:

| | **Code tool** | **Data tool** | **MCP tool** |
|---|---|---|---|
| What | a Ruby class (`< RubyLLM::Tool`) | an HTTP call described by config, no Ruby | an MCP server's tool, ingested |
| Lives | in the deployment image | as a row in SQLite | as data-tool rows in SQLite |
| Editable at runtime | no (shipped in the image) | **yes** (DSL / API / manifest / Studio) | **yes** (re-ingest) |
| Reach for it when | logic must run in-process (file edit, shell, subagent) | calling an external HTTP API | adopting a whole MCP toolset at once |

**MCP tools are not a separate runtime type.** An MCP ingestor discovers an MCP
server's tools and turns each into an HTTP **data tool** that posts a JSON-RPC
`tools/call`, tagged with a `group` naming the source instance. (Only
HTTP-transport MCP servers are ingestible; stdio is rejected.)

Code tools **win name collisions** — you cannot register a data tool whose name
shadows a code tool.

## Data tools: a tool is a row

A data tool is defined entirely by config — this is the operator-facing kind, and
the one you create and change without a rebuild. See
[`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/) for a runnable one.

```jsonc
{
  "name": "search_products",              // /\A[a-z][a-z0-9_]*\z/
  "description": "Search the catalog",     // required — this is what the model reads
  "parameters": { /* JSON Schema, safe subset */ },
  "request": {
    "method": "POST",                       // GET | HEAD | POST | PUT | PATCH | DELETE
    "url": "https://api.example.com/search",
    "headers": { "X-Session": "{{ctx.chat_id}}",
                 "Authorization": "Bearer {{secret.api_token}}" },
    "query": {}, "body": "…"
  },
  "response": { "extract": "json_path", "path": "$.results" },
  "secret_headers": ["Authorization"],
  "side_effect": true, "timeout": 30, "group": "catalog", "tags": []
}
```

### Parameters: the schema is the contract

`parameters` is **JSON Schema**, and it reaches the provider verbatim — it is the only
thing telling the model what shape to send. The engine never fills a gap in it.

For simple params there is a flat sugar (what the Studio's textarea and a hand-written
manifest accept), one line per param:

```
cep      | string       | required | The ZIP code to look up
tags     | array:string | optional | Labels to filter by
quantity | integer      | required | How many
```

Types are `string`, `number`, `integer`, `boolean`, and `array:<scalar>` for a list.
There is **no bare `array`**: a list without an item type is an incomplete declaration,
and it is rejected instead of being guessed at. A list of **objects** — the common
`[{query, filters}]` shape — cannot be written in the flat form at all; write the JSON
Schema, which is what the Studio field reads when the text starts with `{`:

```jsonc
{ "type": "object",
  "properties": {
    "query_filter_pairs": {
      "type": "array",
      "items": { "type": "object",
                 "properties": { "query":   { "type": "string" },
                                 "filters": { "type": "object", "properties": {} } },
                 "required": ["query"] } } },
  "required": ["query_filter_pairs"] }
```

**Arguments are checked against the schema at call time.** A call the schema does not
allow never becomes a request: it returns an `{ error: … }` naming the path
(`query_filter_pairs[0]: expected an object, got a string`), which the model reads and
retries against. Structure is strict; a scalar may arrive in its lossless string form
(`"2"`, `"true"`) and is never coerced — what the model sent is what the request carries.

**Placeholders** are resolved at turn time:

- `{{param}}` — a declared top-level parameter, filled from the model's call.
- `{{ctx.*}}` — turn context set **server-side, never by the model**: a closed set
  of `chat_id`, `store_id`, `agent_id`, `tenant`, `image_url`. This is how a tool knows *which*
  session/agent it is acting for without trusting the model. `image_url` is the
  first image part on the message (a photo for analysis outside the prompt);
  absent when the turn carried none.
- `{{secret.*}}` — allowed **only** inside a header named in `secret_headers`.
  A secret placeholder anywhere else is rejected (it would leak unmasked). The
  real secret value is injected at provision time and never lives on disk.

**Validation** happens on ingestion. Common rejections:

- `url` must be `http`/`https` — anything else is a 422.
- `parameters` is a **safe subset** of JSON Schema
  (`object/array/string/number/integer/boolean`); `oneOf`/`anyOf`/`allOf`/`$ref`/
  `if`/`then`/`else` are forbidden (not every provider supports them).
- `side_effect` defaults from the method (GET/HEAD → false, else true) and drives
  checkpoint/replay semantics (a completed side-effecting tool is not re-run on
  resume — see [Architecture](ARCHITECTURE.md#durability-checkpoints-and-resume)).

### `halt_when`: when the answer is already out

Some tools do the work **and** deliver the news. A backend that subscribes a customer
and sends its own confirmation over the channel has already said everything there is to
say: if the model then writes "all set, you're subscribed!", the person gets the message
twice. The usual patch is to ask the model to stay quiet in the tool's instructions —
which works until the turn it doesn't, and the failure lands in front of a customer.

`halt_when` moves the decision from the prompt to the engine. It reads the tool's own
**response**, and when it matches, the turn ends right there — no further provider call:

```jsonc
{ "name": "subscribe_to_learning_path",
  "request": { "method": "POST", "url": "https://app.example/subscribe" },
  "halt_when": { "json_path": "tool_result.status", "equals": ["SUBSCRIBED"] } }
```

By **result**, not by tool. The same call that goes silent on `SUBSCRIBED` must let the
model explain a `SUBSCRIPTION_FAILED` ("you are already enrolled") — one tool, two
endings, decided by what the backend actually returned.

- `json_path` is a dotted path into the parsed response body, and `equals` a list of
  values compared **as strings** (a status is a label; JSON types vary by backend).
- It reads the **body**, independently of `response.extract` — which shapes what the
  *model* sees, not what the engine decides on.
- It only fires on a **2xx**. An error response that happens to carry the value is a
  failure, and a failure must reach the model.
- A non-JSON body or a missing path simply does not match: a turn never ends on a guess.

A halted turn keeps whatever the model had already streamed *before* the call (usually a
"let me get that for you") and adds nothing after it.

#### `say`: what the customer gets when the model wrote nothing first

The model does not always introduce the call. Then the lead-in is empty, and the turn
used to publish **nothing** — measured on a real store, two escalation turns in a row
delivered silence to the customer. `say` is the answer for that turn, and only that
turn: when there **is** a lead-in it still wins, because two messages for one
escalation is what `halt_when` exists to prevent.

It cannot be inferred. `json_path` + `equals` cannot supply it either — the matched
value is by definition one of the `equals` tokens, so publishing it would ship
`SUBSCRIBED` to a person as often as it ships a sentence. So you name it, in one of two
shapes:

```jsonc
// the sentence the backend itself returned
"halt_when": { "json_path": "tool_result.status", "equals": ["SUBSCRIBED"],
               "say": { "json_path": "tool_result.message" } }

// a literal the CHANNEL knows how to resolve
"halt_when": { "json_path": "tool_result", "equals": ["…"],
               "say": { "text": "CALL_SUPPORT" } }
```

The literal form replaces the usual workaround: instructing the model to emit a control
token and parsing it downstream. The token now comes from the **tool's contract**,
deterministically, instead of depending on the model complying with a sentence in a
prompt.

- Exactly one of `text` or `json_path` — two answers to "what does the customer get" is
  a configuration nobody can read, so both (or neither) is refused at load.
- A `json_path` that does not resolve to a **string** publishes nothing: a hash or a
  number reaching a customer as the answer is never what someone meant.
- Omit `say` and the behaviour is unchanged — a halt with no lead-in completes empty,
  which is what a channel consumer drops.

`say` is declared on the **tool**, because what a backend answers is a property of that
backend, not of whoever calls it. Every agent sharing the tool gets the same value.

> The Studio's tool editor does not render this field (nor `group`/`tags`), but a save
> there **preserves** it — the form carries the stored values through instead of
> replacing the record with only what it shows.

## Evidence: the lean envelope and grounding (RFC-0029)

A catalog tool returns products; the model should only ever quote the ones the tool
actually returned — the store dies of a SKU the model invented. `evidence` is the
declaration that makes "no claim without a tool ID" an engine rule instead of a
prompt convention. One declaration does **both** jobs: the engine strips the result
down to what the model sees (the lean envelope) **and** records every returned id on
the session's evidence ledger. There is no "lean but not evidence" mode.

```jsonc
{ "name": "search_products",
  "response": { "extract": "evidence_envelope" },
  "evidence": "products" }                        // bare kind

{ "evidence": { "kind": "products",               // full form
                "items": "results",               // non-default paths
                "attachments": "cards" } }
```

- `evidence_envelope` is the canonical extract: the raw response body arrives under
  an engine-only key, the envelope parses `items`/`attachments` out of it, and
  **nothing re-fattens** — the transcript and the tool trace record only the lean
  result. It **requires** the `evidence` declaration (refused at load otherwise).
- **Wire contract** — the lean result the model sees is always
  `{ "items": [ { "id": "…", "line": "…" } ] }` (≤ 16 items; `line` truncated to
  200 chars). A tool whose result has no valid items yields `{ "items": [] }`,
  never a null. A malformed evidence result becomes `{ "error": … }` back to the
  model — a correctable tool answer, exactly like a malformed call.
- **Attachments** are the optional second half: `[{ "type": "card"|"image",
  "url": "…", "caption": "…" }]` (≤ 16, url ≤ 500 chars, malformed dropped). They
  **never** reach the model context or the transcript — they ride the channel
  delivery as an additive `attachments` key on the outbox payload, and the channel
  (or its consumer) decides what a card looks like.
- A **code tool** opts in the same way: it either returns `{ items, attachments }`
  directly and declares `evidence` in its registry metadata, or exposes an
  `evidence` reader. No declaration = today's tool behavior, byte for byte.

### Grounding: policing claims against the ledger

With the ledger fed, the pack declares how claims are policed — data on the agent,
not a separate code path (see [Agents](AGENTS.md)):

```ruby
grounding mode: :flag, matcher: { sku: '\b[A-Z]{2,4}\d{4,8}\b' }
```

- `mode` is `flag` (the default — audit), `enforce` (cut), or `off`. Absent = off.
- `matcher.sku` is a regex for the store's SKU shape, applied to the final answer;
  every match that is **not** in the evidence ledger is an ungrounded claim.
  Grounding is **SKU-only** by design: a name-based half cannot flag anything
  without a "this is a product name" signal, so the ledger grounds ids, and the
  model quoting a returned product by its *name* is simply outside the check
  (the SKU path is the claim detector). A `sku` that does not compile is refused
  at build; a matcher with no `sku` builds but matches nothing — `insika doctor`
  warns about it.
- **`flag`** appends an `:ungrounded` flag (category `ungrounded`, source
  `evidence`) to the existing `:guardrail_flagged` event — audit after the fact,
  like every other output flag.
- **`enforce`** *cuts the sentence* containing an ungrounded claim from the content
  the turn persists and delivers, and the flag carries `action: "cut"` so the audit
  can tell a cut from a flag. It is honest about streaming: on a streaming surface
  the already-streamed bytes are the channel's reality, which is exactly why the
  default is `flag` — ship `enforce` only after a matcher audit proves precision.
- Grounding is **independent of the guardrails opt-in**: an agent with guardrails
  off and `grounding.mode: :flag` still gets the check.

## Registering a tool

A tool appears in the Studio panel and enters an agent's tool-loop when it is
**registered** in the catalog **and** allowed by the agent's policy allowlist.
Four ways to write a data tool into the store — all **hot** (registry and catalog
reload, no restart):

1. **DSL** — `data_tool(name:, …)` in a `Insika.agent { … }` block.
2. **Studio** — the Tools panel editor.
3. **Manifest** — `POST /v1/tools/manifest`. Partial failure is isolated: one
   malformed tool becomes an `errors[]` entry; only a structural manifest error
   fails the whole request. The response reports `{ version, created, updated, errors }`.
4. **MCP ingestion** — import a server; each of its tools becomes a data tool.

### The one gotcha: env templating is manifest-only

`{{env.*}}` (and `{{secret.*}}`) are substituted **at ingestion, on the manifest
path**. Other write paths do **not** resolve `{{env.*}}` — a literal
`{{env.API_URL}}` there fails the `http`/`https` URL check and 422s. Rule:
**manifest tools may template the URL with `{{env.*}}`; tools written any other
way must ship a literal URL.** `{{ctx.*}}` and `{{param}}` work everywhere (they
resolve at turn time, not ingestion).

## Making it appear — and enter the tool-loop

1. **Panel visibility** = registered in the catalog. Data tools are marked
   editable; code tools are allow/deny only.
2. **Per-agent exposure** is set from the same panel, or by the agent's allowlist.
3. **Entering the tool-loop** is decided by the **policy allowlist**, not by tool
   type: deny wins, otherwise the agent sees `tools_allow ∪ tools_allow_groups`
   (or all, when both are absent). See [Agents](AGENTS.md#the-allowlist-convention).
4. **Deferred tools** (`tools_deferred`) are *not* offered directly — they appear
   as a short "available tools" list and the model must call `tool_search` to
   enable one. This is progressive disclosure for large toolsets — see
   [Context](CONTEXT.md).

## Parallel tool calls

A model can ask for several tools in one step. By default the engine runs them one
at a time. Set `limits[:tool_concurrency]` above 1 (see
[Agents](AGENTS.md#tool_concurrency--parallel-tool-calls)) and the calls in that
batch run concurrently, **at most N in flight**, on the turn's own reactor — so
the wall-clock of a batch of slow data tools approaches the slowest call rather
than their sum. The cap covers every enveloped tool of the turn, including the
ones `tool_search` promotes mid-turn.

It applies only to what the *model* fans out. Two primitives already parallelize
deterministically and are unaffected: `spawn_subagents` (capped at 8 children) and
`Insika::Tools::Concurrency.gather` (fan-out inside one tool). System tools —
`tool_search`, `load_skill`, `remember`, `spawn_subagent` — are not enveloped and
so are not gated by the cap; they are trivial or capped on their own.

Turning it on changes three things, all of them worth knowing before you do:

- **`max_tool_calls` becomes approximate.** The limit is checked per call, but a
  call that trips it does not stop its siblings — the whole batch finishes and the
  turn then fails. With a cap of 4, up to 3 extra tools may have executed. The turn
  still fails at the right boundary; the count is just no longer exact.
- **The transcript records results in completion order.** Providers key results by
  `tool_call_id`, so the wire stays valid and persistence is faithful to what was
  sent — but a replayed transcript no longer reads in call order.
- **`turn_timeout` can overrun by up to `tool_timeout`.** A turn deadline does not
  cancel a tool call already in flight in a sibling fiber; it waits for it. Each
  call is still bounded by its own `tool_timeout`, which is what bounds the
  overrun. Serial execution is unaffected (there, the deadline lands directly in
  the fiber running the tool).

Approvals and concurrency are mutually exclusive per turn — the approval gate wins
and the turn goes serial. That is a deadlock avoided, not a preference.

## Egress: the SSRF guard (and its silent failure)

Data tools make outbound HTTP, so every call passes through the **EgressGuard**, a
Server-Side Request Forgery defense. The default posture is **strict: public
`https` only.** Three env vars widen it:

| Env | Effect |
|-----|--------|
| `INSIKA_EGRESS_HOSTS` | allowlist of hosts (CSV). The safe way to permit a specific backend. |
| `INSIKA_EGRESS_ALLOW_HTTP=1` | permit plain `http` — **loopback dev only** |
| `INSIKA_EGRESS_ALLOW_PRIVATE=1` | permit private/loopback IPs — **dev only** |

> ⚠️ **Egress failures are silent.** When a tool targets a blocked host (e.g. a
> plain-`http` localhost backend without the opt-ins), the guard turns the block
> into a `{ error: … }` returned **to the model** — the request never leaves the
> process, yet the stream still emits a tool call, so the model narrates a
> plausible failure and the conversation *looks* like it worked. You will not see
> an exception.
>
> **Always verify by the trace, never by the reply:** open the Studio session
> viewer — a healthy call shows the request, args, and the backend's `200`; a
> missing or errored call is almost always egress (host not in the allowlist, or
> `http`/private without the opt-in).

Egress is **orthogonal** to registration and allowlisting: a tool can be
registered, allowed, offered to the model, and still blocked at call time.

## Troubleshooting: "the tool is missing"

Work down this checklist:

1. **Registered?** Is it in the catalog (Studio Tools panel)? If not, the write
   or import failed — check the manifest `errors[]`, and run `insika doctor`: a stored
   definition that no longer validates is dropped from the catalog, and the
   `data-tools` check is the only place that says so.
2. **Allowed for this agent?** In `tools_allow` (or an allowed group), and not in
   `tools_deny`?
3. **Egress?** If it *appears and is called* but "fails", open the trace — a
   blocked call is ~99% egress.
4. **URL literal?** For non-manifest tools, an unresolved `{{env.*}}` would have
   422'd at import — re-check the definition.

## The `save_artifact` built-in

`save_artifact` is a **registry tool** — it obeys the same per-agent
`tools_allow` as any data tool, and an agent that did not name it cannot call
it (`tools_allow: %w[save_artifact]`). The agent hands in `title` + `content`
and gets the URL back; the tenant is bound from the turn, never a parameter the
model types. See [Artifacts](ARTIFACTS.md) for the tool contract, the serving
routes, the signed link and the retention/LGPD reach.

## See also

- [Agents](AGENTS.md) — allowlists, groups, and per-agent tool exposure.
- [Artifacts](ARTIFACTS.md) — the report destination: the tool, the routes, the signed link.
- [Plugins](PLUGINS.md) — where a code tool comes from, and how to package one.
- [Security](SECURITY.md) — egress, sandbox, and approval gating together.
- [Architecture](ARCHITECTURE.md) — the tool-loop and side-effect checkpointing.
- [`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/) — a runnable data tool + the egress note.
