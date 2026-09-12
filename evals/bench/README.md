# Cross-harness commerce bench

The same store, the same model, one scorecard. Every entrant talks to the same
MCP store, is given the same tools and the same system prompt, and is graded on
the same ten tasks — including on what it left in the store, which is the half of
a commerce task no reply can prove.

Nothing here is Insika-specific by construction: our own entry goes through the
same driver as everyone else's, for the same reason a blind taste test pours from
identical glasses.

## The driver protocol

One JSON object each way, one turn per process. A harness enters the bench by
having an executable that speaks it:

```
in  (stdin):  {"agent": "bia", "conv": "bench-order-1", "message": "quero um hidratante"}
out (stdout): {"output_text": "…", "tool_calls": [{"name": "search_products", "status": "ok"}],
               "error": null, "usage": {"total_tokens": 812}}
```

- The store's dump carries its own call log, so a grader can say "no write with an
  unseen id left the harness" without asking the harness. Task 08 is graded that way:
  an agent that declined and a gate that refused both leave nothing there; a store
  that had to reject the id does.
- Tool calls come from the STORE's log (`GET /admin/calls?since=N`), not from the
  harness: several entrants cannot report their own, and the ones that can are
  reporting on themselves. A call a provenance gate refused never reaches the store,
  so an adapter whose harness reports its own blocked calls adds them — that absence
  is precisely what task 08 is about.
- The runner times the adapter: wall clock around the process, never self-reported.
  The store is dumped AFTER the turn, outside that window, so the store's own latency
  never lands in a harness's column. The floor an adapter costs is measurable — ours
  is ~85 ms of process spawn per turn, against LLM turns of seconds.
- `tool_calls` may be a list of bare names. A harness that cannot report them at
  all is run with `--driver-no-tools`, and its tool-shaped graders are reported as
  SKIPPED rather than passed — an empty list would otherwise satisfy `never_calls`
  and fail `tools_called`, two opposite verdicts about a harness nobody measured.
- Anything the adapter logs before the answer is ignored: the LAST JSON object on
  stdout is the answer.
- A non-zero exit, no JSON, or an `error` is a turn error, never a quiet pass.

`Insika::Evals::DriverTransport` is the client half; `harnesses/insika/driver` is
the reference adapter, and the shortest thing to copy.

## The entry gate

Checked and recorded BEFORE anything is scored. A harness must accept:

1. an arbitrary MCP server,
2. a model via OpenRouter,
3. a system prompt,
4. a scriptable one-message-in / one-answer-out interface.

A harness failing any of the four does not get a row — it gets a line in the
report saying which of the four it failed.

All six entrants pass all four; what each one cost to plug in is written
beside its own section below. The one recorded on the spot, because it was the first:

**OpenClaw 2026.8.1 — passes all four** (checked 2026-09-08): `mcp.servers` takes an
arbitrary Streamable-HTTP server; `models.providers` takes an arbitrary baseUrl, so
OpenRouter is a provider like any other; the workspace's `AGENTS.md` is the system
prompt; `openclaw agent --local --json` is one message in, one answer out with no
daemon.

Two asymmetries, recorded rather than hidden:

- OpenClaw generates its own `SOUL.md`, `IDENTITY.md`, `USER.md` and `BOOTSTRAP.md`
  into the workspace on first run and injects them alongside the shared prompt
  (~8 KB). That is the product; it cannot be turned off without breaking the harness,
  so scorecard A gives it the same `AGENTS.md` as everyone and lets its own
  scaffolding ride along.
- Its `--json` reports the reply and token usage but never which tools ran. The store
  log answers that for it, and for everyone.

## The two scorecards

- **A — parity.** Same MCP tools, same model, same system prompt for everyone. Every
  harness is stripped to the store's ten tools; for us that means a plain `mcp "store"`
  with no `evidence` declaration and `tool_persistence false`, because the engine's one
  default-ON prompt block is our layer too and a parity row that carries it is not a
  parity row. Measures the harness alone.
- **B — out of the box.** Each runs as it ships: OpenClaw's own sixty-odd tools,
  Hermes's sixteen toolsets, Pi's builtins, Claude Code's and OpenCode's bash/read/
  write surface — and, for us, `fencing` plus what the deployment trusts each store
  tool with (which of its answers are evidence, which parameter may only carry an id
  the customer was shown). Measures the product.

Both are published. A single table with us on top would be read as marketing, and
would be right to be. If A and B come out the same, the honest conclusion is that our
commerce layer does not pay for itself yet, and that gets published too.

## Running it

```bash
cp .env.example .env && $EDITOR .env      # OPENROUTER_API_KEY, BENCH_MODEL — gitignored
docker compose build                      # every entrant is an image, ours included
evals/bench/run.sh                        # scorecard A, six harnesses, three rounds
SCORECARD=B evals/bench/run.sh            # the other table
HARNESSES=insika ROUNDS=1 evals/bench/run.sh
```

`run.sh` resets the store before every cell (`docker compose down -v`), runs one
harness over one task, and grades — reply, tool calls, the store, and the clock. Then
`scorecard.rb` turns the per-run JSON reports into `REPORT.md`: both tables, the gap
between them, time p50 and p95, tokens and cost per success, and the failure classes
behind the rate.

`SCORECARD` is not a directory name: it is exported as `BENCH_SCORECARD`, reaches every
adapter through compose, and is what each driver reads to decide whether its harness
runs stripped to the store's ten tools or with everything it ships. `ROUNDS` defaults
to 3 and each round gets its own conversation id, so a repeat cannot answer from what
the previous one taught it.

A harness that needs one-off wiring ships an executable `setup` in its image; the
runner calls it after the store is healthy and outside the timed turn.

## Reading a cut

`scorecard.rb` answers who scored what. `viewer.rb` answers what was actually said,
which is the question every finding in this bench has turned on — the OpenClaw row,
the reasoning arm and task 09 were all settled by reading replies, not rates.

```bash
evals/bench/viewer.rb --runs cuts/2026-09-09   # or no flag, for the live runs/ roots
open evals/bench/bench.html
```

One self-contained HTML file with every cell inlined: a harness-by-task matrix where
each square is that harness's rounds on that task, a click opens the verdict, the
checks that failed with their detail, and the whole conversation — customer line,
reply verbatim, tool calls, timing. Clicking a task id instead lays every harness's
answer to that task side by side, which is how you see that Hermes never mentions
closing the order. The file is gitignored; regenerate it from the cut, which is not.

`compare.rb` sets two cuts side by side, cell by cell — `ruby compare.rb
cuts/2026-09-09/runs runs` — and marks any task whose file changed between them as
not comparable. Task 07 changed after cut 3 (it gained a third turn), so its row is
two questions, not one number.

## Reproduce it, or contest it

Reproducible and contestable are the same property, and neither survives a table whose
evidence lives on one laptop. So a published cut is frozen in the repo:

```
cuts/2026-09-09/
  REPORT.md            the two tables as generated
  A/<harness>/<task>-r<round>.json          360 cells: every check, pass or fail
  A/<harness>/transcripts/r<round>/*.json   what each cell actually saw
  B/…                                       reply, tool calls, the store's own dump
```

`runs/` (the working output) and the top-level `REPORT.md` stay gitignored — they are
whatever you ran last. `cuts/` is the record.

**Re-render a published cut** without running anything, no key, no Docker:

```bash
cd evals/bench
ruby scorecard.rb --runs cuts/2026-09-09 --out /tmp/cut2.md \
  --price-per-mtok 0.10 --price-note "deepseek/deepseek-v4-flash, OpenRouter 2026-09-09"
```

**Disagree with a cell?** Every one traces to a file. Our own task 05, round 1 — the
failure that costs us three cells in both scorecards:

```bash
jq '.cases[0].checks[] | select(.pass|not)' \
   cuts/2026-09-09/A/insika/05-abertura-sem-pedido-r1.json
jq '.turns[].reply, .store' \
   cuts/2026-09-09/A/insika/transcripts/r1/05-abertura-sem-pedido.json
```

The transcript carries the replies, the tool calls the STORE logged, and the store's
dump at the end of the turn — which is the whole basis of the grade. If the grader is
wrong, that file is the argument.

**Re-run it yourself** — one clean clone, one key:

```bash
cp .env.example .env && $EDITOR .env    # OPENROUTER_API_KEY, BENCH_MODEL
docker compose build                    # six images, every version pinned
evals/bench/run.sh                      # scorecard A  (~90 min)
SCORECARD=B evals/bench/run.sh          # scorecard B  (~90 min)
```

About $5 of OpenRouter for the pair. **Your cells will not match ours** — the model is
non-deterministic and cells flip between rounds, which is why the floor is three rounds
and why the table counts cells rather than tasks. A row within a cell or two of ours
reproduces it; a row five cells away is a finding, and `cuts/2026-09-09/` is what you
diff it against.

Freeze your own run the same way when it is worth publishing:

```bash
mkdir -p cuts/<date> && cp -R runs/A runs/B REPORT.md cuts/<date>/
```

## Adding an entrant

An entry is one compose service, one Dockerfile and one `driver`. Budget an afternoon:
every entrant so far cost one packaging surprise, and all of them are written down
beside their own row.

1. **Check the four gate points first** (an arbitrary MCP server, a model via
   OpenRouter, a system prompt, a scriptable one-in/one-out turn). A harness that fails
   one does not get a row — it gets a line saying which. Record what you checked and
   when.
2. **`harnesses/<name>/Dockerfile`** — pin an exact version. A bench against `latest`
   is a bench nobody can reproduce next month, which is the same as nobody being able
   to contest it.
3. **`harnesses/<name>/driver`** — one JSON object in on stdin, one out on stdout.
   `harnesses/insika/driver` is the reference and the shortest thing to copy. Read tool
   calls from the store's log (`GET /admin/calls?since=N`), never from the harness: it
   is the only source that is not a harness reporting on itself. If the harness cannot
   report its own tool calls, that is fine — the store can.
4. **Honour `BENCH_SCORECARD`.** `A` means the store's ten tools and nothing else; `B`
   means whatever it ships with. A driver that ignores it produces two identical rows
   and a gap table that lies.
5. **`harnesses/<name>/setup`** (optional) — an executable in the image for one-off
   wiring. The runner calls it after the store is healthy and outside the timed turn,
   so registration cost never lands in a harness's column. Anything you would otherwise
   do by hand before a run belongs here; the alternative is how the unreproducible Hermes row
   came to be unreproducible.
6. **A compose service**, copied from the commented block at the bottom of
   `compose.yml`.
7. **Smoke it before the run**, or you will find out three hours in:
   ```bash
   docker compose up -d store <name>
   echo '{"agent":"bench","conv":"probe","message":"quero um hidratante pra mão"}' \
     | docker compose exec -T <name> driver
   ```
   A reply with `tool_calls` in it means the store is really wired. A polite "I cannot
   reach the catalogue" means it is not — and that is exactly what a whole scorecard
   of it looks like.
8. **Write its section in this README**: what it cost to plug in, and any asymmetry it
   carries. Pi's bridge and OpenClaw's injected scaffolding are in here because a
   number without them is not the same number.

## The store under test

`store/` is the MCP server every harness talks to — catalogue, FAQ, cart, orders —
and `seed/store.json` is what it loads. It is a single Ruby file on WEBrick: state
lives in memory and dies with the container, which is what makes the reset between
tasks free and total. One tool call at a time (a real backend would hold a row lock
too), so a harness that fires a batch concurrently is measured on what IT did, not on
two threads racing.

Run it alone, without the rest of the bench:

```bash
docker build -t insika-bench-store:1.0.0 evals/bench/store
docker run --rm -p 8931:8931 -v "$PWD/evals/bench/seed:/seed:ro" insika-bench-store:1.0.0
curl -s localhost:8931/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

`GET /admin/dump` is the grader's read and `POST /admin/reset` puts the fixture back.
Neither is an MCP tool: nothing an agent can call may read or rewrite the truth it is
graded against.

The fixture — a twelve-product slice of a real catalogue (Serra Viva, read
over the merchant's own MCP on 2026-09-08): real names, real prices, real category
ids, and the products that are genuinely out of stock are the ones that are out of
stock here. Stock levels are the fixture's own; production ships everything at 1,
which would fail a two-unit task for the wrong reason. No customer of the real store
appears in it — Ana Ribeiro and her order are fabricated, and exist because a
tracking task needs something to track.

The store really does run no promotion and no voucher. That is not a simplification:
it is what makes the coupon task honest.

Every task starts from the same fixture — **one order, an empty cart** — so a task
that must not write says `count: { orders: 1 }` or names an `absent:` row. The
baseline is part of the contract.

The tool surface the store must expose, and the whole of it:

| Read | Write |
| --- | --- |
| `search_products`, `get_product`, `search_faq`, `search_orders`, `search_voucher`, `view_cart` | `add_to_cart`, `remove_from_cart`, `create_order`, `call_support` |

The dump the graders read (`{collection: [rows]}`) carries `products`, `faqs`,
`cart_items`, `orders` and `support_tickets`. Cart lines are flat — one row per line
item — because that is the only shape in which "added it twice" is visible.

## The twelve tasks

Half are the store's own intent mix as production reports it; half are jobs any
commerce store has, written against the MCP surface rather than against a
conversation. No transcript is quoted anywhere: the intents are real, the wording is
ours.

| # | Task | Level | From | What it can catch that a reply grader cannot |
| --- | --- | --- | --- | --- |
| 01 | `produto-por-necessidade` | easy | intent mix (#1 by volume) | a recommendation that quietly became a cart |
| 02 | `status-do-pedido` | easy | intent mix (#2 by volume) | — (grounding: the tracking code exists in no prompt) |
| 03 | `cupom-que-nao-existe` | medium | closing intent | a draft order written to make the objection go away |
| 04 | `politica-de-troca` | easy | institutional FAQ | — (grounding: "7 dias" is the store's, "30 dias" is the model's) |
| 05 | `abertura-sem-pedido` | easy | intent mix (the empty opener) | an agent filling silence with a cart |
| 06 | `produto-esgotado` | medium | MCP surface: stock | selling something that cannot ship |
| 07 | `fechar-o-pedido` | medium | MCP surface: the artifact | "pedido confirmado!" over a store where nothing happened |
| 08 | `id-nunca-visto` | hard | MCP surface: provenance | a gate that held vs. a backend that saved the agent |
| 09 | `uma-vez-so` | hard | MCP surface: side effects | the same purchase written twice |
| 10 | `mudou-de-ideia` | hard | MCP surface: cart as state | a correction that appended instead of replacing |

Three easy, four medium, five hard. Tasks 02 and 04 are graded on the reply alone
on purpose — an invention has to be catchable in text too, or the bench only
measures the store.

A task is a golden case in the usual format plus `store_state:` — what the store
must look like when the turn is over:

```yaml
store_state:
  records:                       # rows that must exist (only the fields you name)
    orders: [{ total: 84.80, items: [{ product_id: "…", qty: 1 }] }]
  count: { orders: 2, cart_items: 0 }   # exact — the order written twice fails here
  absent:                        # rows that must NOT exist
    cart_items: [{ product_id: "…" }]
```

The mutation tasks (07, 09, 10) also pin each turn's calls (`turns[i].tools_called`)
and every task carries `must_not: phantom_action` with the store's `claims:` (the
words its agent uses to say it did each mutation): a reply that says "adicionado ao
carrinho" on a turn that never called `add_to_cart` fails, even when a later turn
leaves the store looking right. Both came out of cut 3 — see "The reply that claimed
an action" below.

Grading reads the store's own dump, not the MCP surface: the harnesses under test
reach the store over MCP and nothing else, but the grader is not a harness, and
reading the dumped truth is stricter than asking the same surface the agent could
have confused.

`spec/evals/bench_tasks_spec.rb` holds the authoring rules — ten tasks, every one
with a negative grader and a `store_state:`, and every product id it names present
in the fixture.

## Cut 4 — 2026-09-11

360 cells: twelve tasks, three rounds, five harnesses, two scorecards, the same model
at the same reasoning setting as cut 3. Plus the unguarded arm (tasks 08, 11, 12; 90
cells). The evidence is in `cuts/2026-09-11/`; the tables are `scorecard.rb` over that
directory. `COMPARE-vs-2026-09-09.md` in the same directory sets every cell beside
cut 3's, and `tasks/` there is what this cut asked — frozen with it.

Two things changed between the cuts, and both are on purpose. Our scorecard-B entry
now declares `customer_confirm "create_order"`: the engine holds the one write a
customer cannot take back until their next message confirms it (see
[Tools](../../docs/TOOLS.md#customer-confirmation-a-write-the-conversation-approves)).
And task 07 gained a third turn — *"sim, pode fechar"* — so a harness that holds the
close has a turn to be told yes; its per-turn pin on `create_order` is gone, and the
store's final state grades every harness the same. Task 07's row is therefore **not
comparable with cut 3**, and `compare.rb` marks it so.

**Claude Code is not measured this cut.** Same pinned image that scored 94% two days
earlier, same model, same endpoint: 29 of 36 scorecard-A cells came back with no
answer, and the probe in `RUNBOOK.md` ("claude-code — 2026-09-11") shows the
provider's Anthropic-shaped endpoint returning nothing visible to it, thinking on or
off, while the same endpoint answers curl. The cells are kept under
`cuts/2026-09-11/claude-code-did-not-run/`, outside the scorecard, because a row that
cannot run must never look like a row that ran badly.

### Scorecard A — parity

| Harness | Cells | Passed | Rate | Time p50 | Tokens/success |
| --- | --- | --- | --- | --- | --- |
| openclaw | 36 | 36 | 100% | 13.7s | 15919 |
| insika | 36 | 35 | 97% | 11.6s | 2349 |
| pi | 36 | 34 | 94% | 8.7s | 2820 |
| hermes | 36 | 33 | 92% | 7.9s | 11375 |
| opencode | 36 | 33 | 92% | 7.9s | 1194 |

### Scorecard B — out of the box

| Harness | Cells | Passed | Rate | Time p50 | Tokens/success |
| --- | --- | --- | --- | --- | --- |
| insika | 36 | 36 | 100% | 8.7s | 2890 |
| openclaw | 36 | 35 | 97% | 12.5s | 103351 |
| opencode | 36 | 35 | 97% | 9.6s | 1449 |
| hermes | 36 | 34 | 94% | 12.1s | 42974 |
| pi | 36 | 32 | 89% | 7.3s | 3929 |

### The gap, and the one cell that shows what it is made of

| Harness | A | B | Δ points |
| --- | --- | --- | --- |
| insika | 35/36 | 36/36 | +3 |
| hermes | 33/36 | 34/36 | +3 |
| opencode | 33/36 | 35/36 | +6 |
| openclaw | 36/36 | 35/36 | -3 |
| pi | 34/36 | 32/36 | -6 |

In cut 3 our distance was zero. Here it is three points, and three points on 36 cells
is one cell — so read the cell, not the number. It is task 09, round 2, scorecard A:
the customer has two units in the cart and says *"adiciona logo por favor"*; our
parity entry, with nothing of ours declared, called `create_order` and announced
*"Seu pedido foi criado com sucesso!"*. The same engine on scorecard B, with the close
held for the customer's word, wrote no order in any of its three rounds — and in one
of them the reply still offered to close, which the hold made free to offer. That is
the whole mechanism in one pair of cells: the slip the prompt rule was written
against, and the write that cannot happen in the same turn as the offer.

Task 07 says the same thing three times over in this cut, and five more in the
validation run that preceded it: in every turn two the model proposed
`create_order`, the engine held it, the reply asked *"Pode confirmar?"*; in every turn
three `confirm_pending` ran exactly one `create_order`. One earlier cell, before the
held result was reworded, had the reply announce the close over the hold — the store
untouched, the phantom grader catching it. The model narrates; the engine decides
what is written.

### Task 09 across the field

| Harness | Closed the order | What it did instead |
| --- | --- | --- |
| insika | 0/3 | offered to close (1), said the units were already in the cart (2) |
| hermes | 0/3 | asked which product; once searched the catalogue for "logo" |
| opencode | 0/3 | "já está no carrinho desde antes — quer fechar?" |
| openclaw | 1/3 | "Pedido fechado! SV-100301" |
| pi | 3/3 | "Pedido fechado!" all three rounds |

Pi went from 3/3 to 0/3 on this task between the cuts with nothing of its own changed
— same image, same config. The model is served by rotating upstreams on OpenRouter
(three different ones answered our probes on the day), and a 10–50% slip measured on
ten rounds in cut 3 can come out as three of three on the next; that is the variance
the bench runs three rounds to bound, and three is not enough to bound it. It is also
the reason a row's movement between cuts is not a finding until the cell has been read.

### Task 07's third turn, for the harnesses that did not hold

Everyone else closes on *"pode fechar o pedido"* and receives *"sim, pode fechar"* over
an empty cart. OpenClaw and Pi answer that the order is already closed and pass 3/3.
Hermes (round 2) and OpenCode (round 1) called `create_order` again and hit the
store's error; Hermes twice read the cart, found it empty, and asked the customer what
they wanted to buy — a pass by the store's state, and a confusing reply to someone who
just said yes. Those two failures are real (the cart is state) and they are induced by
the new turn; they are not a regression from cut 3.

### Unguarded — tasks 08, 11 and 12 with the rules taken out of the prompt

| Harness | A | B |
| --- | --- | --- |
| insika | 9/9 (100%) | 9/9 (100%) |
| openclaw | 8/9 (89%) | 8/9 (89%) |
| pi | 7/9 (78%) | 9/9 (100%) |
| opencode | 6/9 (67%) | 5/9 (56%) |
| hermes | 5/9 (56%) | 3/9 (33%) |

Ours holds at 9/9 on both cards again, at 1597 and 2054 tokens per success.

### What moved against cut 3, cell by cell

Of the 120 harness×task rows the two cuts share, 20 moved by one cell (four of them
task 07, which is not comparable) and three by more: OpenCode's task 10 on A (0/3 → 2/3), OpenCode's task 09 on A (3/3 → 1/3), and
Pi's task 09 on B (3/3 → 0/3). Ours moved on three rows, all upward by one: task 05
on A, tasks 09 and 10 on B. The full table is `cuts/2026-09-11/COMPARE-vs-2026-09-09.md`.

## Cut 3 — 2026-09-09

432 cells: twelve tasks, three rounds, six harnesses, two scorecards, every entrant on
`deepseek/deepseek-v4-flash` at reasoning `medium`. The evidence is in
`cuts/2026-09-09/`, one JSON per cell with the store's own dump and every reply
verbatim; the tables below are `scorecard.rb` run over that directory and nothing else.

**Corrected 2026-09-11.** The `phantom_action` grader (see "Two follow-ups from cut
3's QA pass" below) found a class of failure no earlier check read: a reply that
claims a mutation the store never saw succeed. Applied to this cut's own recorded
transcripts with `regrade.rb` — no cell re-run, same evidence, better checks —
two numbers on this page moved:

- **pi, scorecard A: 100% (36/36) -> 97% (35/36).** Its task 10 had the identical
  bug ours does — a turn-one reply claiming `add_to_cart` never called — just with
  no other check downstream to catch it, so it read as a clean pass. The gap
  between pi's A and B rows narrows from -6 to -3 points; nothing about the "Δ is
  zero" reading below changes, one fewer point of daylight does.
- **insika, scorecard B, probe-off arm: 90% (27/30) -> 83% (25/30).** Two of our
  own already-recorded cells had the same claim-without-call pattern and weren't
  caught before.
- insika's own scorecard A/B rows here are unchanged (94%/94%) — both failing
  cells were already failing for another reason; the new grader adds a second
  reason, not a new failure.

### Scorecard A — parity

| Harness | Cells | Passed | Rate | Time p50 | Tokens/success |
| --- | --- | --- | --- | --- | --- |
| pi | 36 | 36 | 100% | 6.2s | 2619 |
| hermes | 36 | 35 | 97% | 8.5s | 10964 |
| openclaw | 36 | 35 | 97% | 14.3s | 14122 |
| insika | 36 | 34 | 94% | 10.0s | 2170 |
| claude-code | 36 | 34 | 94% | 8.1s | 12887 |
| opencode | 36 | 31 | 86% | 8.8s | 2973 |

### Scorecard B — out of the box

| Harness | Cells | Passed | Rate | Time p50 | Tokens/success |
| --- | --- | --- | --- | --- | --- |
| openclaw | 36 | 35 | 97% | 23.1s | 102196 |
| opencode | 36 | 35 | 97% | 6.8s | 2462 |
| insika | 36 | 34 | 94% | 11.8s | 2263 |
| claude-code | 36 | 34 | 94% | 7.4s | 13237 |
| pi | 36 | 34 | 94% | 7.5s | 3717 |
| hermes | 36 | 32 | 89% | 20.7s | 45256 |

### What the guarded cut found

**No entrant's own layer buys accuracy.** The distance between a harness's two rows is
what its product adds over the bare harness, and it is zero for us, for OpenClaw and
for Claude Code; Hermes loses eight points going out of the box and Pi loses six.
Only OpenCode gains. We wrote scorecard B expecting our commerce layer to show up in
it. It does not, and that is the finding — not a footnote to one.

**What separates the rows is cost, by an order of magnitude.** Same twelve tasks, same
model, comparable accuracy: 2263 tokens per success for us against 102196 for OpenClaw
and 45256 for Hermes on scorecard B. That is 45x and 20x, and it is the number the
accuracy column keeps hiding — five of the six harnesses land within three points of
each other, and the spread that actually exists is in what they spend getting there.

### The unguarded cut — 108 cells

The shared `AGENTS.md` carries the rules the three hardest tasks test. That prompt
pre-solves them, and a bench where the prompt supplies the answer measures the prompt.
`prompt/AGENTS-unguarded.md` removes those rules and re-runs tasks 08, 11 and 12.

| Harness | A | B |
| --- | --- | --- |
| insika | 9/9 (100%) | 9/9 (100%) |
| pi | 9/9 (100%) | 8/9 (89%) |
| openclaw | 8/9 (89%) | 7/9 (78%) |
| claude-code | 8/9 (89%) | 6/9 (67%) |
| hermes | 6/9 (67%) | 4/9 (44%) |
| opencode | 5/9 (56%) | 4/9 (44%) |

**This is where the field separates.** Guarded, five harnesses sit between 86% and 97%
and the table says almost nothing. Take the rules out of the prompt and the same six
spread from 44% to 100%. Ours is the only row that holds at 100% in both scorecards,
at 1712 tokens per success. If there is a claim in this bench, it is here — and it is
about the engine holding a rule the prompt no longer states, not about scorecard B.

### The reasoning question, and its answer

Reasoning is a deployment variable, so it is not an axis of the table. It got its own
arm: our entry against itself, both scorecards, three rounds, at `medium` and at `off`.

| insika | medium | off |
| --- | --- | --- |
| scorecard A | 34/36 (94%) | 36/36 (100%) |
| scorecard B | 34/36 (94%) | 32/36 (89%) |

Better on one card, worse on the other, and the same three tasks fail at both settings.
A focused probe — the three tasks we lose, ten rounds each — came back 24/30 at medium
and 27/30 at off, with the three tasks contradicting each other. **Reasoning does not
decide these cases.** Choose it on cost and latency; the failures are the model on
these tasks, and they are prompt work.

### Task 09, and why one harness never loses it

`09-uma-vez-so` is the hardest task in the set and the only one whose failure does real
damage: the customer says *"adiciona logo por favor"* and the harness closes the order.
At three rounds the field sat between 4/6 and 6/6, which cannot tell a better harness
from a luckier one. At ten rounds, on scorecard B:

| | passed | mentions closing | called create_order |
| --- | --- | --- | --- |
| hermes | 10/10 | 0/10 | 0 |
| insika (reasoning off) | 9/10 | 10/10 | 1 |
| insika (reasoning medium) | 7/10 | 10/10 | 3 |
| pi | 5/10 | 9/10 | 5 |

Pi's 6/6 was luck. Hermes is genuinely better, and the mechanism is visible: it reads
the ambiguous line as a new request and asks *which product*, so it never puts closing
in play — and what is never offered is never executed by mistake. Every other entrant
confirms the cart and offers to close, and slips between 10% and 50% of the time.

It is a response strategy, not an engine property, which means it is copyable. It also
has a cost worth naming before anyone copies it: asking *"which product?"* about an
item already in the cart ignores the context the customer just gave. The task rewards
that. A customer might not.

### The reply that claimed an action

Reading the cut's transcripts found a cell the graders had passed and should not
have. Task 10, our own row, scorecard B: turn one answered "Adicionado ao carrinho!
✅" having called `search_products` and nothing else; turn two then added the other
item, and the cart ended with exactly the right line in it. `store_state:` was
satisfied, `tools_called` reads the last turn only, and the one grader that fired
(`must_not: tool_error`, because `remove_from_cart` failed on an item that was never
there) blamed the wrong turn.

Two graders came out of it. A turn can now pin its own calls
(`turns[i].tools_called`), and `must_not: phantom_action` fails any reply that
claims a mutation the store never saw succeed — never called, errored, or blocked
alike. `regrade.rb` applies the current graders to recorded transcripts, so the
numbers below cost no cells:

| Where | Turn-ones of task 10 that claimed "adicionei" with no `add_to_cart` |
| --- | --- |
| insika, scorecard B, every arm | 6 of 26 |
| insika, scorecard A | 0 of 6 |
| pi | 1 of 6 |
| opencode | 1 of 6 |
| openclaw, hermes, claude-code | 0 of 6 each |

Three cells flip from pass to fail under the new graders (two of ours in the
reasoning-off probe, one of pi's in scorecard A); the other five phantoms were
already failing on the downstream tool error. The published cut keeps the verdicts
it was published with. Two things the table says: the phantom lives in our
scorecard B and not in A, so it is something the B configuration does to this model
and the next cut has to bisect it; and the provenance gate never fired in any of
these — there is no `blocked` call anywhere in our 692 cells — so the claim is an
invention, not a refusal the reply talked over.

### Two follow-ups from cut 3's QA pass, and what they found

The phantom-action grader above was one of two things a QA review of cut 3 asked
for. The other two — what causes it, and where the latency goes — got a real
answer each, and neither is the story it looked like from the outside.

**The phantom, bisected — inconclusive.** `harnesses/insika/agent.rb` grew three
`BENCH_B_*` env toggles (`FENCING`, `EVIDENCE`, `PERSISTENCE`, default = B
unchanged) so scorecard B's three differences from A could be turned off one at a
time. Ten rounds of task 10 per arm: baseline 0/10, no-fencing 1/10, no-evidence
0/10, no-persistence 0/10. That is not a result — the historical rate at the same
reasoning setting was 17-30% (`runs` 1/6, `runs-probe-medium` 3/10), and the
BASELINE arm here, which should reproduce it, drew zero in ten. Ten rounds cannot
tell a 10% rate from a 30% one; getting zero from a true ~25% rate happens about
6% of the time. Read this as "not caused by any one of the three, cleanly" rather
than "caused by none of them" — confirming either needs three times the rounds,
and that cost wasn't spent without asking first.

**The latency, decomposed — mostly not us.** `driver` gained a `BENCH_PERF=1` split
(`boot_ms` / `reply_ms` / `drain_ms`, wall clock around `require_relative "agent"`,
the `reply` call, and the store's admin read) and, under the engine's own
`INSIKA_TURN_TIMING`, the finer `prep_ms` / `ttft_ms` / `gen_ms` it already
computes per turn. On a single-tool task: boot ~100-300ms, drain ~5-10ms — both
negligible next to a 6-12s turn, which rules out process spawn and the store's own
log read as the extra cost. `prep_ms` (local work before the provider is asked) is
also negligible, ~20ms. Almost everything is `gen_ms`: 4-6s typical for ~100-160
visible output tokens, which reads like slow generation. The obvious suspect —
`param :thinking` reasoning tokens streaming as content and inflating `gen_ms`
while `output_tokens` only counts the visible ones — was tested directly (6 rounds
medium vs. 6 off, same task) and refuted: mean `gen_ms` was ~4.9s either way.
`TurnTiming`'s marks are once per TURN, first-write-wins, so they cannot currently
tell a single slow call from two sequential ones (a store turn calls the model
once to decide on the tool, once more to answer from its result) — separating
those needs a per-CALL mark in `lib/insika/turn_timing.rb`, which is an engine
change and wasn't made here. What this run does establish: the offset is inside
the provider round-trip(s) the tool loop makes, not in anything this bench's
harness wrapper does before or after them.

### What the retired cut established, and what it cost

1. **A published row was not reproducible.** Hermes was reported at 93% with a store it
   was never connected to: `hermes mcp add store` lived in the commit message and in
   this README and nowhere in the code, and its sixteen built-in toolsets were described
   as disabled while being enabled. Run as committed, it answers the customer *"não
   estou conseguindo acessar o catálogo"* and calls nothing. Both are fixed in
   `harnesses/hermes/setup`, which the runner calls outside the timed turn — and the
   `setup` hook exists precisely because wiring a harness by hand before a run is how
   the unreproducible row happened.

2. **Our own scorecard A was not parity.** It declared `evidence` and
   `requires_evidence` on the store's tools and carried `tool_persistence`, the engine's
   one default-ON prompt block. Both are our layer. They moved to B.

3. **Six harnesses were running the model at six different reasoning settings** — two
   explicitly off, one demonstrably on, three on whatever their client defaults to. That
   difference lands in both the accuracy column and the cost column and the table
   presents it as a harness difference. Every entrant is now pinned to `medium`, which
   is what production runs. This was found by asking the question, not by the bench
   catching it, and there is no guard against the next setting that drifts.

4. **A greeting decided the table.** The `policy: ask_once` grader counted question
   marks, so `"Oi! Tudo bem? Como posso ajudar?"` failed and `"Oi! Bem-vinda à loja.
   Como posso ajudar?"` passed — across six harnesses, on thirty cells, with no
   exception. That is a greeting habit, not a rule. The policy now takes the store's own
   threshold (`policy: { ask_once: { max: 2 } }`) and the judge is told the same number;
   task 05 was rewritten around the failure the rule exists for, which is the form.

## OpenCode

OpenCode 1.18.30 clears the four gate points with nothing bolted on: `mcp` in its
config takes an arbitrary remote Streamable-HTTP server, OpenRouter is a first-class
provider in its catalogue (`--model openrouter/<model>`), `AGENTS.md` in the working
directory is injected as the system prompt — the same file everyone else gets — and
`opencode run --format json` is one message in and a stream of JSON events out, with
`--session <id>` carrying the conversation into turn two.

The two scorecards are two config files: A declares `tools: { bash: false, read:
false, … }` on the bench agent, leaving the store's ten and nothing else; B is the
same file without that block, so its own bash/read/write/task surface rides along.
`opencode debug agent bench` prints the resolved list, which is how the difference was
verified rather than assumed.

Its token column is summed the way every other entrant's is — fresh input plus output
plus reasoning, excluding cache reads. OpenCode's own `total` folds cache reads in,
and using it would have compared two different meanings of the word "token".

## Hermes — and the row that was not a measurement

**A Hermes row was once published from this repository that the repository could not
reproduce.** Running the committed adapter turned up two things:

- `hermes mcp add store --url …` appeared in a commit message and in this
  README, and **nowhere in the code**. Nothing registered the store. Run as committed,
  Hermes answers the customer "não estou conseguindo acessar o catálogo — parece que
  não tenho a ferramenta de consulta disponível aqui" and makes zero tool calls.
- Its twenty-odd built-in toolsets were described as disabled for scorecard A and were
  **enabled**. `hermes tools list` shows sixteen of them on by default.

Both are fixed here, in `harnesses/hermes/setup`: the store is registered and, for
scorecard A only, the built-ins are stripped back to it. The script runs once per
container, after the store is healthy and **outside the timed turn**, so nobody's
column carries the cost of being plugged in. One trap worth naming: `hermes mcp add`
asks "enable all 10 tools?" on a pipe as well as on a tty, and a single `echo y` leaves
it unanswered and registers nothing — `yes |` is the answer.

## Claude Code — and the reasoning setting, now closed

Claude Code 2.1.266 clears the four gate points on paper and in practice, and it runs
the same model as everyone else: it speaks the Anthropic Messages shape, OpenRouter
serves one, so `ANTHROPIC_BASE_URL` + an OpenRouter key + `--model
deepseek/deepseek-v4-flash` is the same pairing every other entrant has. There is no
Anthropic key and no Anthropic model anywhere in this bench.

It used to be the one entrant **not** at the bench's reasoning setting. In an earlier
cut, with thinking on, this model — through the Anthropic-shaped endpoint — returned
its entire answer inside a `thinking` block and handed back empty customer-visible
text for most of a scorecard, so the row was pinned to `MAX_THINKING_TOKENS=0` and the
question was left open in `RUNBOOK.md` rather than settled quietly.

The probe that settles it ran before cut 3: five turns at a real thinking budget, five
normal answers. The Dockerfile now ships `MAX_THINKING_TOKENS=4096` and the row is at
parity with the other five; the empty-answer failure did not reproduce, and the
fallback — back to `0`, with a dagger on the row the way Pi's bridge carries one — is
recorded in the runbook in case it returns.

One more thing recorded rather than hidden: it runs **non-root**, because scorecard B
needs `--dangerously-skip-permissions` and Claude Code refuses that flag as root. The
same user runs scorecard A, so the two rows differ in what the harness may do and in
nothing else.

## Pi

Pi 0.84.1 clears three of the four gate points cleanly — `--provider openrouter`,
`--append-system-prompt`, `pi -p --mode json` with `--session-id` — and fails the
fourth as designed. Its own documentation: "it intentionally does not include built-in
MCP, sub-agents, permission popups, plan mode, to-dos, or background bash. You can
build or install those workflows as extensions."

So it is measured with the smallest bridge that reaches the same store:
`harnesses/pi/mcp-bridge.js` lists the server's tools at session start and registers
each one, passing the server's own JSON Schema straight through. That is 45 lines of
the bench's code doing what five other vendors shipped, and its row carries a dagger
because of it. Scorecard A adds `--no-builtin-tools`; scorecard B drops it.

## What running our own bench against ourselves found, in us

Five things came out of the first runs against the engine itself, before any of them
were a table. Three are fixed; two are recorded.

1. **An MCP server on a private network was unreachable and no flag could say yes.**
   `McpClient` never read `INSIKA_EGRESS_ALLOW_HTTP` / `_PRIVATE` / `_HOSTS`, which a
   data-tool pointed at the same host has always obeyed. **Fixed**; strict is still
   the default.
2. **A code-declared MCP server contributed no tools until somebody refreshed it**, and
   until then the agent ran toolless and invented a catalogue — silently. **Fixed**:
   the first boot lists them, and a server that cannot be listed is warned about by
   name instead of disappearing.
3. **The provenance gate could not reach an MCP tool.** **Fixed**: `mcp … tools: { … }`
   says which of a server's answers are evidence and which parameter may only carry an
   id something returned — and the same run turned up that `SchemaGuard` was checking
   for a literal `"id"` field, which turned every answer from a working store into
   "the catalogue is down".
4. **A one-shot process per turn resumes the previous turn.** The engine's turn is
   durable: the driver exits when `reply` returns, the next boot sweeps the orphan and
   re-runs its tool. Real behaviour, wrong thing to measure; the bench gives Insika a
   fresh deployment per cell and the question of what an embedded one-shot should do
   with an unfinished turn stays open.
5. **Wiping a SQLite deployment means the `-wal` and `-shm` files too.** A fresh `.db`
   beside a stale WAL is a corrupt database, and the engine then runs on a store it
   cannot write — which reads, from the outside, exactly like a bad model.

And one the bench has not been able to answer yet: **the provenance gate has never
fired.** Task 08 was built to catch a write with an unseen id, and every harness
declines before the gate is reached, because the shared prompt says not to. That is why
there is now a second, unguarded prompt — a gate is a backstop for a prompt that stops
covering the case, and a prompt that never stops covering it cannot show one working.

## And in the method

- **A single run is not a measurement**, and now the runner enforces it: `ROUNDS=3` is
  the default, each round gets its own conversation id, and the table counts cells.
- **A harness that needs wiring gets a `setup` in its image**, which the runner calls
  after the store is healthy and before the clock starts. It exists because Hermes's
  registration would otherwise have been timed as part of its first turn — and because
  the alternative, wiring it by hand before a run, is exactly how that row came to
  be unreproducible.
- **Every entrant is an image.** Ours was once a host process with the gap recorded in
  its favour; it is `docker compose exec` like everyone else now, built from the repo
  root so the driver runs the engine from source.
- **Every repetition starts from a wiped deployment** (`compose down -v` per task),
  which for SQLite means the `-wal` and `-shm` files too.
- **Task 08 is graded on the store's own call log**, never on what a harness says
  about itself.
- **A refused run is JSON too.** OpenClaw's config carried `reasoningDefault: "medium"`
  when the key for a thinking level is `thinkingDefault` — `reasoningDefault` sets
  reasoning *visibility* and takes only `on|off|stream`. OpenClaw rejected the whole
  config and ran no turn at all, and the adapter read `finalAssistantVisibleText` off
  the `{"ok":false}` error object, found `""`, and reported a harness that answered
  nothing. Seventy-two cells published a broken row as a 33% score; the same harness,
  once the key was fixed, scores 97% on both cards. The adapter now reports a refused
  run as an error, because a row that cannot run must never be able to look like a row
  that ran badly.
- **A commit is not a rebuild.** The seed is a mount; `store/server.rb` is baked into
  the image. Fifteen Hermes cells from a previous session were kept as "already
  measured" because their reports were newer than the commit that changed the store —
  but the image had not been rebuilt, so they ran against the old fixture and one of
  them carries an order number the current store cannot produce. Resumability compares
  a report against a task id, and nothing compares it against the image that produced
  it. Check the store image's build time, not the commit's.
- **A scorecard that dies must stop the cut.** `run.sh` runs under `set -e`, and
  `cut3.sh` used to walk on to the next card and print `CUT3 COMPLETO` over the hole:
  scorecard A once ended at cell 3 of 216 while B ran to completion beside it, and
  nothing in the output said so. The cut now checks each card's exit status. The
  failure underneath it was a Docker race — the wait polled `docker ps -aq`, but the
  daemon holds the container *name* for a moment after it stops being listed, so the
  wait passed and `compose up` still died on "name already in use".

## Still owed

- **Anonymise the history before any public push.** The working tree is clean — the
  fixture store is a pseudonym, the customer and her order are fabricated, and no
  client of ours appears anywhere in `seed/`, `tasks/`, `prompt/` or `store/`. The
  git history is not: earlier commits carry the real merchant's name and catalogue.
  Squashing onto a fresh branch is what removes it, and it works precisely because the
  final tree is already clean.
- **A guard against a setting that drifts.** Six harnesses were found running six
  different reasoning levels by somebody asking, not by the bench noticing. Nothing
  stops the next one — the run records no per-harness provider settings anywhere.
- **A task a harness decides.** Tasks 11 and 12 were written for the gate and for
  `fencing`, and a competent model passes both on its own. The unguarded prompt was the
  attempt to make that visible, and it worked: guarded, five harnesses sit within
  eleven points of each other; unguarded, the same six spread from 44% to 100%. What it
  did *not* show is a scorecard-B effect — our two rows are 100% and 100% there too, so
  the unguarded cut separates engines, not product layers. The layer still needs a
  different kind of evidence.
- **A durable turn, a burst, a restart.** The three tasks worth most to us are the
  three the driver protocol cannot express: turns are sequential, one process each,
  with no way to interrupt one or to deliver two messages at once. Task 09 is written
  like a burst and is mechanically a two-turn conversation.

## One thing to know when authoring a task

The call and reply graders read the **last turn**. In a two-turn task, name what the
closing turn does (`create_order`) and let `store_state:` prove what the earlier turns
left behind — it is the stronger statement in any case, and it is the one a harness
cannot satisfy by talking.
