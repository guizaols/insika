---
title: Evals
parent: Improve
nav_order: 1
permalink: /evals/
---

# Evals

An agent has no unit test. The same prompt, the same tools and the same model can give
a different answer twice, so "does it still work?" cannot be answered by asserting on a
string. What you can do is keep a small set of **conversations you care about**, replay
them against a running deployment, and check two different kinds of thing:

- **deterministic** — did it call `search_voucher`? did the reply leak a CPF? did a
  tool error? No model involved, no flakiness, no token cost.
- **subjective** — did it actually resolve the doubt, without inventing a discount?
  That one needs a reader, so a model reads it against a **rubric you write**.

That is the whole idea. The rest of this page is the format, who grades, and how a run
becomes a gate.

## A case is data

```yaml
id: loja-chocolates-cupom
agent: loja-chocolates
turns:
  - user: "tem algum cupom de desconto ativo?"
expect:
  tools_called:
    - search_voucher        # a trailing "?" marks it optional
  must_not:
    - pii_leak
    - tool_error
  rubric: |
    Consults the active coupon with the tool and says what it is — does NOT invent a
    code or a percentage. If there is none, says so kindly.
  min_score: 0.7
```

Turns replay **in order** under one conversation, so a case can build context ("what
about the shipping?" after "I want the 70% bar"); the assertions run on the last turn.

### State — a case starts from a snapshot

Every case above starts from an **empty** conversation. To test "the customer already
saw three products and says *add the second one*", such a case would first have to
replay the search turn — which makes it depend on the model's first answer, costs a
turn, and cannot reproduce a messy state (a contradiction from six turns ago, a
stored preference). `state:` is the precondition, loaded into the conversation
**before turn 1**:

```yaml
id: loja-chocolates-add-seen
agent: loja-chocolates
requires:
  tools: [add_to_cart]
state:
  evidence:
    ids: ["SKU-70-DARK"]
    cards:
      - { type: card, url: "https://shop.example/70", id: "SKU-70-DARK", caption: "Dark chocolate" }
  memory: { facts: { preference: "dark chocolate" }, notes: [] }
  history:
    - { role: user, content: "quero chocolate amargo" }
    - { role: assistant, content: "O chocolate 70% é SKU-70-DARK." }
  briefing: { fields: { cep: "01311-000" } }
turns:
  - user: "adiciona uma unidade desse chocolate 70% no carrinho"
expect:
  tools_called: [add_to_cart]
  never_calls: [search_products]
  reply_omits: ["SKU-70-DARK"]
```

Only those four `state` keys are accepted by the case loader. A persona case may
carry `state` too. Adapt the tool names, arguments and briefing fields to the agent.

The evidence ledger is a runtime precondition, not a list shown to the model:
include the relevant product and ID in `history` or the user's request. `cards`
seeds the cards a search would have returned (each needs a `url` and an `id`; the
id counts as seen), so a presentation case needs no lookup in the turn.

With the HTTP transport, the eval stays a **client**: the runner never writes a
store. Seeding goes through
`POST /v1/conversations/:id/seed` (same Bearer as the turn, same id namespacing for a
tenant), and the deployment accepts it **only while the platform setting
`evals.seeding` is on** — off by default, because a seeded conversation is a
fabricated precondition, and the doctor warns while it is on. With the setting off
the replay Runner **skips** seeded cases with a reason; it also skips when its
transport has no seed support. Other seed errors fail the replay. In-process
`GraphTransport` dispatches `seed_session` directly and bypasses `evals.seeding`;
it needs a runtime exposing the graph. The persona
Simulator surfaces seed refusal as an error instead of the Runner's skip result.

A session with messages returns `409`. Replays default to `eval-<case-id>`; pass
`--conv-map FILE` with a JSON mapping such as
`{"loja-chocolates-add-seen":"eval-add-seen-run-2"}` to use a fresh ID on reruns.
Seeded memory may share a tenant cell even with fresh IDs; see
[the seed API](API.md#seeding-an-eval-conversation) for scope and payload details.

#### Graders — what a turn's calls and reply are checked against

The turn's SSE stream reports each tool call with its arguments and how it ended
(`ok`, `error`, or `blocked` plus the gate that held it), so the deterministic
layer can check more than "was the tool called". All optional; each is its own
check, and the report names the one that failed.

| Key | Checks |
|-----|--------|
| `tools_called: [name, name?]` | each required tool was called on the LAST turn (`?` = optional, never fails) |
| `turns[i].tools_called: [names]` | the calls one specific turn must make — a two-turn case where turn one claimed an action and turn two repaired the store passes the key above and fails this one |
| `never_calls: [names]` | none of these was called — the negative every `tools_called` needs |
| `calls_one_of: [names]` | at least one of these was called |
| `first_tool: name` | the first call's name |
| `max_tool_calls: N` | a ceiling on the turn's calls |
| `reply_includes: [substrings]` | each appears in the published answer (case-insensitive) |
| `reply_omits: [substrings]` | none appears — where an internal id, a CPF or a raw tag leaking into the customer's text is pinned |
| `blocked_gates: ["tool:gate"]` | each pair appears among the turn's blocked calls |
| `ui_components: [names]` | a presentation tool showed at least one card of each component (the `insika.ui` frames) |
| `no_ui: true` | the turn showed nothing — the negative of `ui_components` |
| `must_not: [detectors]` | the negative detectors (`pii_leak`, `tool_error`, `phantom_action`, …); a blocked call is not a tool error |
| `claims: { tool: pattern }` | what `phantom_action` reads — per mutation, the words a reply uses to say it did it (a regex, case-insensitive); the store's language, so it lives in the case |

**Every positive has a negative.** A case that only says `tools_called: [add_to_cart]`
passes an agent that also re-searched, or that echoed the SKU to the customer. Pin
what a correct turn does *not* do — `never_calls`, `reply_omits`, `max_tool_calls` —
in the same case. Snapshots avoid the model calls needed to reconstruct the setup;
use the simulator when later customer messages need to branch on the replies.

`tools_called` confirms an attempted call, not a successful backend mutation.

`must_not: phantom_action` reads the other direction: a reply that SAYS it did
something ("adicionei", "removi", "fechei o pedido") on a turn where the matching
tool never ran, errored, or was blocked. It is cumulative over the conversation, so
"já adicionei" on turn two is true when turn one did it, and it only pins the words
against the calls — a cart that ended up right by accident is still a lie to the
customer. The words come from the case's `claims:` map, in the store's own
language, past tense on purpose: "quer adicionar?" is a question.

```yaml
expect:
  must_not: [tool_error, phantom_action]
  claims:
    add_to_cart: '\b(?:adicion(?:ei|ad[oa]s?)|coloquei)\b'
    create_order: '\b(?:fechei|finalizei|pedido (?:criado|fechado))\b'
```
Arguments are collected for inspection; there is no generic argument or cart-state
grader. `blocked_gates` needs completion statuses from the HTTP transport. The
in-process `GraphTransport` records tool names and UI events, but not completion
statuses or arguments. Neither transport counts `load_skill` / `load_knowledge` as
tool calls. `ui_components` requires a nonempty selection; `no_ui`
accepts absent UI events and events with zero items.

### `requires` — a case that cannot run here is skipped, not failed

Deployments differ. Some stores have order tracking wired, some do not; some run
promotions, some do not. A case asserting `search_orders` is **not a failure** for a
store without it — it is a case that should never have run, and a red suite nobody
trusts is worse than a small one.

```yaml
requires:
  tools: [search_orders]        # must be available to the agent
  capabilities: [promotions]    # facts the operator declared about the deployment
expect:
  tools_called:
    - search_orders
```

The runner asks the deployment what that agent has (`GET /v1/agents/:id`, gated like
every `/v1` read) **before** spending a turn, and reports a third outcome beside pass
and fail: **skipped, with the reason**. The rule of thumb: a case that asserts a tool
should require it.

Capabilities are a flat list the operator writes on the agent — inferring "this store
has promotions" from data is how a suite starts lying:

```ruby
declares "promotions", "human_handoff"
```

Three deliberate edges:

- An agent with an **open** tool allowlist runs the case. "I could not rule it out" is
  not a reason to stop testing something.
- If the deployment cannot be read at all, cases with `requires` **run**, and the CLI
  says so once. A suite must not shrink in silence.
- The gate never blocks *on* a skip, and `--update-baseline` leaves skipped cases out
  of the baseline entirely. But a case that used to pass here and is now skipped **is**
  reported as a regression: it means the agent lost a tool.

### `policy` — how much the agent should ask before acting

One optional key, because this is the thing a rubric cannot carry alone. Whether the
agent should establish the objective before searching, or act on the first plausible
reading, is a decision **your store** makes — a universal rule would be wrong for half
of them. Declare it and two things happen: a check that costs nothing runs, and the
judge is told the rule instead of guessing it.

```yaml
expect:
  policy: ask_once                    # the strict reading: one question, full stop
  policy: { ask_once: { max: 2 } }    # a store that greets its customers
```

| policy | the check | the judge is told |
|---|---|---|
| `ask_once` | no reply asks more than `max` questions (default 1) | at most `max` per reply, and a greeting formula is courtesy rather than a question |
| `investigate_first` | turn 1 asks something and calls no tool | ask on a vague request, don't search immediately |
| `act_fast` | turn 1 calls a tool | asking what a search would answer is a failure |

Omit it and only the rubric decides. Unlike the other assertions, a policy is checked
on **every** turn — "one question per reply" is a rule about each reply, and in the
case that motivated this the violation was on the first one.

Question counting is deliberately crude: a run of `?` counts once, and URLs are dropped
so a tracking link's query string is not read as the agent asking something. It is a
policy signal, not grammar — and crude was enough to catch an agent breaking a rule
written in its own prompt, twice, with no model in the loop.

**`max` is the store's, and it matters more than it looks.** The default of 1 comes from
a real store's rule, quoted down to the punctuation: *"Máximo 1 pergunta principal por
mensagem = 1 ponto de interrogação no fim"*. A store that greets its customers spends
one of those on courtesy — measured across six harnesses answering the same "oi", `max:
1` failed every reply containing "tudo bem?" and passed every reply without it, and
nothing else. That grades a greeting habit, not the rule the policy exists for, which is
the form: *"qual seu nome? qual o número do pedido? e o motivo?"*. Set `max` to what
your store actually tolerates; the judge is told the same number, so the two halves
never grade different rules.

### `reference` — compared against the system you want to replace

`min_score: 0.7` says a reply cleared a bar you invented. It says nothing about
whether the system already answering your customers would have done better. If you are
replacing something, that is the only question that matters — and you have its
transcripts.

Give a case the incumbent's real conversation for the same opening, and a run with
`--pairwise` asks one judge one question: **which one served the customer better?**

```yaml
reference:
  source: "helpdesk chat 34403117"   # free text, so a reader can find the original
  messages:
    - role: user
      text: "tem creatina?"
    - role: assistant
      text: "temos sim! qual seu objetivo?"
    - role: assistant
      text: "segue o link do produto"
      origin: operator               # a HUMAN typed this one
```

```bash
ruby evals/run.rb --agent loja-chocolates --pairwise
```

Three outcomes — `better`, `comparable`, `worse` — and two more the panel can produce
and the report will not hide: `split` when the judges disagree, `unknown` when none of
them answered readably. **It never changes pass/fail.** "Worse than the incumbent" is
an answer about a replacement decision, not a regression in your suite, and it stays
out of the gate.

Three rules make the number worth quoting:

- **The judge is not told which one is yours.** It sees "A" and "B". Told, it would
  have an opinion about the new system instead of about the conversations.
- **Every judge is asked twice, with the transcripts swapped.** Preferring whatever was
  printed first is the classic failure of pairwise grading, so a verdict that flips is
  reported as `comparable`, marked `order-dependent`.
- **A person is not the incumbent's model.** `origin: operator` on any reference
  message labels the whole pair `vs: human-assisted`, and the summary counts those
  separately — comparing a model to a person and calling it a win is a lie in both
  directions. The judge is not told; the reader is, which is where it changes a
  decision.

Cost: **two provider calls per judge per case**, which is why it is opt-in and never
part of the gate.

## Simulated users — conversations the agent never had

A golden case fixes the user's turns in advance. Real customers branch — they answer
the agent's question, or ignore it, or send an order number three messages later. A
case with frozen turns can only ever test the path the author imagined.

A **simulated** case generates the conversation instead: a persona model (the cheap
platform `utility_model`) plays a customer with the persona as its **whole
instruction**, and the target agent answers through the same transport a replay uses.
They talk until the persona's `max_turns`, or until the persona emits a stop marker —
`<<goal_met>>` when its goal is served, `<<gave_up>>` when it abandons. Both are
recorded: "gave up at turn 3" is a finding.

```yaml
id: loja-objetivo-difuso
agent: loja-chocolates
persona:                          # the SIMULATED customer (alternative to `turns:`)
  goal: "descobrir o que comprar de presente; não sabe nomes de produto"
  style: "mensagens curtas, responde o que perguntam, desiste se tiver que explicar duas vezes"
  opens_with: "oi, queria um presente"
  knows:                          # the ONLY facts the persona may assert
    orcamento: "até R$ 100"
    ocasião: "aniversário"
  max_turns: 8
expect:
  policy: investigate_first
  rubric: |
    Descobre o objetivo antes de recomendar (uma ou duas perguntas, não um formulário),
    recomenda do catálogo real e fecha com um próximo passo claro. Reprova se despejar
    catálogo antes de entender, ou se ficar perguntando sem nunca buscar.
  min_score: 0.7
```

**The anti-invention rule is the soul of the feature.** The persona's prompt contains
only the `knows` facts and the rule that it may assert exactly those and nothing else
— asked about anything it does not have, it answers with ignorance ("não sei", "não
tenho isso aqui"), like a real customer without that fact. A simulator that invents an
order number produces a conversation the agent could never have had, and a case that
tests nothing.

```bash
insika evals:simulate --persona persona.yml --target loja-chocolates --staging
```

- `--target <agent|url>` — an agent id over the deployment's `/v1/responses`, or a full
  A2A URL (an agent that only speaks A2A rides the same Simulator through a thin A2A
  transport; it polls once per second, bounded by `--timeout`, since a remote agent
  takes seconds to finish a task).
- `--staging` or `--eval-profile` — **one is required**. A simulated conversation
  marks its transcript `simulated: true`; it does NOT disarm the agent's tools. So the
  Simulator only runs against (a) a target the operator declares is a staging
  deployment (`--staging`), or (b) an eval profile where the agent's side-effect tools
  are swapped for dry-runs (`--eval-profile`).
- `--eval-profile` is a **verified declaration, not a trust-me flag**. The CLI derives
  the target's side-effect tools — the deployment's own registry over
  `GET /v1/agents/:id` (`side_effect_tools`), or the local store when `INSIKA_DB`
  points at it — and refuses unless `--eval-tools <a,b,c>` names every one of them.
  The swap itself happens where the tools run (the deployment's eval profile; the
  in-process overlay for a local graph, as in `examples/agent-tester/`); the
  derivation is what keeps the client honest about what must be covered. An A2A target
  has no reachable registry, so the explicit `--eval-tools` list is required there.
- `--persona-model` — the model playing the customer (default: the platform
  `utility_model`). The judge that scores the transcript comes from the same
  panel configuration as a replay.
- `--conv` — the conversation id. The default is unique per run
  (`sim-<case id>-<random>`), because two runs on the same conv share the
  deployment session: the second inherits the first's history — including
  across the arms of an A/B comparison — and the grade stops measuring the
  agent. Pass `--conv` only when continuing a session is the point.

Every simulated run is **`simulated: true`** — the transcript carries the flag end to
end, so a report never mixes a generated conversation with real traffic. A simulated
case (`persona:`) is one of the two shapes of a case; the replay Runner **skips** it
(the turns do not exist until a Simulator generates them) and only the simulate CLI
drives it.

Cases live in two places, and it is the same YAML in both:

- **`evals/golden/**`** in the repo — the curated corpus, reviewable in a pull request,
  and the seed for a fresh deployment.
- **the store** — what a deployment actually runs, editable in **Studio → Evals**
  without a checkout. That matters because the rubric is the part of an eval a domain
  owner can write, and asking them for a git branch means it never gets written.

```bash
insika evals:import              # corpus -> store (a fresh deploy starts here)
insika evals:import --keep-existing   # don't overwrite what was authored in the Studio
insika evals:export --dir /tmp/cases  # store -> YAML, at the paths it came from
```

Export refuses to overwrite an existing corpus unless you pass `--force`: `YAML.dump`
drops the comments those files carry, and each one explains what its case is for.

A case whose stored YAML no longer validates is **listed as broken** on the Evals page
rather than skipped in silence — a test suite that quietly shrinks is worse than a red
one.

### `run_persona_eval` — a QA agent that tests other agents

A tool (`lib/insika/tools/run_persona_eval.rb`), not a CLI: a QA agent picks one of its
authored simulated cases and runs it **in-process**, against the case's declared
target agent — the same Simulator + Judge machinery `evals:simulate` drives over HTTP,
minus the network hop.

```ruby
tools %w[run_persona_eval save_artifact]
```

The model only sees `case_id`, enumerated with the ids the tool can actually run
(never a free string it could invent) — every **simulated** case in the store, the same
`persona:` shape as above.

**Side effects are replaced for local graph runs.** The tool derives the target's
reachable side-effect tools and builds a throwaway executor with recorder tools
under those names. Read-only tools and the other graph collaborators are shared.
If side effects are reachable but no graph was supplied, it refuses the run.
This substitution prevents real writes; it does not prove a backend mutation.

**Budget**: the persona model + judge model calls are the cost of running the eval,
charged to the **calling** agent's own turn — never the target's (the target's own
turns bill normally, through the ordinary edge limiter, exactly as a real customer's
would). A hard cap on the calling agent skips the run — visibly, in the tool's own
result (`{skipped: true, reason: "budget", window: "daily"|"monthly"}`) — before a cent
is spent; a soft cap just runs (the ledger's own alert already warns).

Each run gets a **fresh session** (`eval-<case>-<random>`), never a reused one — a
reused session lets the target agent "remember" earlier runs, which is not what a
persona case is testing. See `examples/agent-tester/qa_scheduled.rb` for the full
loop: `schedule` fires the QA agent, it calls `run_persona_eval`, then
`save_artifact` publishes the quality report.

**Tenant isolation.** A golden case carries a `tenant` (`platform` — the
single-tenant default — unless the case declares one, the same convention
`save_artifact` uses for its own binding tenant). `run_persona_eval` only ever
lists or runs cases in the *calling* agent's own tenant: a case authored for
another tenant is invisible, not merely refused — the model cannot even learn
its id from the enum, and running it by a guessed id gets the same "unknown or
invalid" error a nonexistent id would (the two must not be distinguishable).
This is what makes "one QA agent per store" an actual boundary
in a deployment where several stores' persona cases live in the same
`GoldenStore` — without it, `qa-store-a` could enumerate and run
`qa-store-b`'s persona and read its `knows` in the transcript.

## Running

```bash
ADMIN_TOKEN=… ruby evals/run.rb                       # cases from the store, else the corpus
ADMIN_TOKEN=… ruby evals/run.rb --source dir          # ignore the store (no database needed)
ADMIN_TOKEN=… ruby evals/run.rb --agent loja-chocolates --mode both
```

It is **on-demand, not CI**: it costs tokens, needs a live provider key and needs the
target agents provisioned. `--mode perf` reuses the same replay to report TTFB and
total latency over real conversations, so one harness answers both questions.

A run writes `evals/reports/<timestamp>.json` and prints a markdown summary.

## Who grades: a panel, not a voice

The judge reads (conversation, reply, rubric) and returns a score in `[0,1]` with one
sentence of reason. An unparseable judge reply scores **0** — a broken grader must
never look like a pass.

Configure the graders in **Studio → Settings → Evals**, one `provider/model` per line:

| Key | Meaning |
|---|---|
| `judges` | one entry per model. Empty = deterministic assertions only, and rubric'd cases read as `judge_pending` |
| `aggregate` | `median` (default), `mean`, or `min` — how the panel's scores become the one number the report and the baseline read |
| `min_agreement` | fraction of judges that must pass **on their own**. `0.5` = a majority, `1.0` = unanimous |
| `quorum` | samples per judge, on top of the panel |
| `tolerance` | max score drop before it counts as a regression |

Several models is the point. Sampling **one** model three times measures that model's
variance — at temperature 0 it mostly returns the same answer, including the same blind
spot. Two *different* models disagreeing about a rubric is the signal worth having, and
the report keeps each judge's score so a split panel is visible instead of hidden
inside an average.

`--judge-model` still overrides everything for a one-off run.

## The gate

A **baseline** (`evals/baseline.json`) is the accepted state of the corpus. A gated run
blocks only on a **regression** — a case that used to pass and now fails, or a judge
score that dropped past `tolerance` — so known failures don't wedge the gate while a
real drop does:

```bash
ruby evals/run.rb --baseline evals/baseline.json   # exits non-zero on a regression
ruby evals/run.rb --update-baseline                # accept the current state
```

That is what you run before merging a prompt, tool or model change. A case with no
baseline entry never blocks: it shows as failing in the report, but a brand-new case is
not a regression.

The same gate machinery guards the two automated loops — [Refinement](REFINEMENT.md)
(cloned-agent replay of a proposed edit) and [Harvest](HARVEST.md) (cloned-agent
replay of a mined skill). **Judges are mandatory for those gates** in exactly three
shapes: a gate without a recorded baseline refuses, an all-red
baseline refuses, and a baseline recorded WITH judge scores, replayed with no judge
configured, refuses — a rubric'd case with no verdict reads as a pass, so the
candidate would beat a measurement it never took. A store with no golden cases cannot
gate, and cannot promote.

## Honest limits

- **A judge is a model.** It has taste and it has bad days; that is why the
  deterministic layer carries the load and the rubric should be objective ("does not
  invent a code" beats "is friendly").
- **A green run is not a proof.** It says the cases you wrote still behave. Cases come
  from real conversations — see [Refinement](REFINEMENT.md) for reading production
  traffic back to find the ones worth adding.
- **The corpus is small on purpose.** Twenty cases covering the hot flows beat two
  hundred nobody curates.
- **A pairwise verdict is a judgement, not a measurement.** It is one model's opinion
  about two conversations. Read a batch of them by hand before quoting the number in a
  decision — if `better` tracks length or politeness rather than whether the customer
  got served, the comparison is measuring the wrong thing and should be dropped.
- **A pair the deployment's DATA cannot satisfy is not a loss.** `requires` resolves
  tools and capabilities; it says nothing about catalogue content. If the reference
  conversation found a product that does not exist where you are replaying, no query
  could have returned it, and the pair is unrunnable — exactly like a case needing a
  tool the agent does not have. Exclude it by hand and say so; counting it is the same
  lie `requires` exists to end.
- **A tool that delivers out of band scores as silence.** When a backend sends the card,
  the button or the support contact straight to the channel, the right behaviour is to
  publish nothing ([`halt_when`](TOOLS.md#halt_when-when-the-answer-is-already-out)) —
  and a comparison that only observes what *you* publish cannot tell that from an agent
  that said nothing. Compare conversations whose tools deliver the same way, or read
  those pairs by hand.
- **Reuse a conversation and you are judging the wrong transcript.** A replay continues
  whatever the conversation already holds, so a pair replayed into a conversation an
  earlier run touched carries both runs' turns. It shows up as a judge that flips when
  the transcripts are swapped — which is the swap-check earning its keep, but the run
  is spent. Mint fresh conversation ids for every pairwise run.

## Where it lives

The harness is `lib/insika/evals/*` — inside the engine, because the refinement gate
needs to score a candidate agent with the same judge, and a second copy of the judge
would be the worst possible outcome. It stays a **client** even so: it reaches a running
deployment over HTTP through `POST /v1/responses` and never reads a store directly.
`evals/run.rb` is a thin CLI over it.

## Parity — the shadow criterion

The shadow experiment's rule lives in a **deployment-side criterion file** —
the path `INSIKA_PARITY_CRITERION` points at, prose a human reads and a `yaml`
block the machine applies, in one file, so there is exactly one place to edit.
The file's whole bytes are hashed; every shadow pair records that hash,
and a window whose pairs disagree produces `:invalid`, never a verdict. Editing
the criterion mid-experiment is *caught*, not averaged away. The fold itself is
`lib/insika/parity/*` (see [Channels](CHANNELS.md#shadow-mode)).
