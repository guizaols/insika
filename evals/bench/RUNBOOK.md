# Cut 3 runbook

Cut 3 ran on 2026-09-09 and is published in `cuts/2026-09-09/`; the results are in
`README.md`. This file stays as the recipe for the next cut — it is what a fresh
session needs to run one and not repeat the false starts it took to get here.

## The one command

```bash
cd ~/projetos/tedi/insika/evals/bench
cp .env.example .env && $EDITOR .env     # OPENROUTER_API_KEY, BENCH_MODEL=deepseek/deepseek-v4-flash
docker compose build                     # six images, every version pinned
bash cut3.sh                             # ~4-5h, ~$6, resumable
```

`cut3.sh` is idempotent: `run.sh` skips any cell whose report JSON is already on disk.
If the machine OOMs (it has, twice), relaunch the same command and only the in-flight
cell is lost.

## What it runs

| Cut | Prompt | Tasks | Cells |
| --- | --- | --- | --- |
| guarded A + B | `prompt/AGENTS.md` | all 12 | 432 |
| unguarded A + B | `prompt/AGENTS-unguarded.md` | 08, 11, 12 | 108 |

12 tasks x 3 rounds x 6 harnesses x 2 scorecards, then the three tasks the unguarded
prompt stops pre-solving. 540 cells, 648 LLM turns.

## Reasoning — the setting the whole table hangs on

**Every entrant runs reasoning at `medium`**, because that is what production runs:
the store agents in the OpenClaw panel show *"Nível de raciocínio deste agente: Padrão
do sistema (Médio)"* on `deepseek/deepseek-v4-flash`.

| Harness | How it is set |
| --- | --- |
| openclaw | `reasoningDefault: "medium"` on the bench agent; `"reasoning": true` on the model (capability, not usage — production separates the two and the bench used to conflate them) |
| pi | `--thinking medium` |
| opencode | `--variant medium` |
| insika | `param :thinking, "medium"` |
| hermes | already medium — its OpenRouter plugin hardcodes `{"enabled": true, "effort": "medium"}` when nothing is configured |
| claude-code | `MAX_THINKING_TOKENS=4096` — see below |

`BENCH_REASONING` overrides the level for pi, opencode and insika. OpenClaw and Hermes
are config-side and would need editing.

Do not cross this with the scorecards. Reasoning is a deployment variable, not a bench
axis; crossing it is 8 combinations and ~1500 cells. Publish one setting, name it in
the table, and let anyone who wants the other one re-run — the bench is reproducible.

## claude-code — resolved 2026-09-09

The probe below ran 5/5 with `MAX_THINKING_TOKENS=4096` and answered normally every
time, so `harnesses/claude-code/Dockerfile` now ships that budget instead of `0` and
the row is at parity with the other five. The earlier empty-answer failure (26 of 30
cells returning nothing, a 10% score that measured the shim and not the harness) did
not reproduce.

If the real cut brings the empty answers back, fall back to `MAX_THINKING_TOKENS=0`
and dagger the row the way Pi's bridge is daggered: *"runs with thinking off because
this model, through the Anthropic-shaped endpoint, returns no visible text with
thinking on."* Recorded, not hidden.

The probe, for re-running it:

```bash
docker compose up -d store claude-code
docker compose exec -T store wait-ready
for i in 1 2 3 4 5; do
  docker compose exec -T -e MAX_THINKING_TOKENS=4096 claude-code sh -lc \
    "claude -p 'responda apenas: ok' --model \$BENCH_MODEL --output-format stream-json --verbose 2>/dev/null" \
    | node -e "let t=[];require('readline').createInterface({input:process.stdin}).on('line',l=>{if(!l.startsWith('{'))return;let e;try{e=JSON.parse(l)}catch{return};if(e.type==='assistant')for(const b of (e.message.content||[]))if(b.type==='text'&&b.text.trim())t.push(b.text.trim())}).on('close',()=>console.log(t.length?t.at(-1):'VAZIO'))"
done
```

## claude-code — 2026-09-11: empty again, and it is not the thinking budget

The first full run after cut 3 brought the empty answers back: 27 of the first 34
scorecard-A cells reported `claude exited 0 with no answer`, with the log line
`[claude-code:unrecognized_model] {"model":"deepseek/deepseek-v4-flash"}` — which is
only Claude Code failing to price a model it does not know, not the failure itself.
Reproduced outside the bench with the same pinned image (`docker run --rm
insika-bench-claude-code:2.1.266 … claude -p 'responda apenas: ok'`): the API call
happens (34,700 input tokens, ~4s), `output_tokens: 2`, and Claude Code shows no
text. `MAX_THINKING_TOKENS=0` does NOT fix it this time (3/3 empty), so the fallback
above does not apply.

The endpoint itself answers: the same model through the same Anthropic-shaped
`/api/v1/messages`, called with curl — short prompt, streaming with tools, and a
72,000-token system prompt alike — returns a `text` block with "ok". OpenRouter is
rotating this model across upstreams (`Mancer 2`, `Baidu`, `StreamLake` on the day),
and whatever Claude Code's exact request shape hits, it comes back with nothing
visible. The `provider` routing parameter IS honoured on `/v1/messages` (naming an
upstream the model does not have returns "No endpoints found"), so pinning an
upstream is possible in principle — but Claude Code cannot add a body field, which
means a shim in front of it, and that is a change to the entrant's wiring, not a
config fix.

What to do: a row that cannot run must never look like a row that ran badly. Stop the
cut, resume without the entrant — `HARNESSES="insika openclaw hermes pi opencode"
bash cut3.sh` keeps every measured cell — and publish the claude-code row as *not
measured this cut*, with this section as the evidence. Keep `runs/A/claude-code` in
the cut under `claude-code-did-not-run/`; do not let it into the scorecard.

## What cut 3 added to the traps

6. **A refused run is JSON too.** `reasoningDefault` is reasoning *visibility*
   (`on|off|stream`); the thinking level is `thinkingDefault`. Typed into the wrong
   key, OpenClaw rejects the whole config and runs no turn — and the adapter used to
   read `finalAssistantVisibleText` off the `{"ok":false}` error and report an empty
   answer. Seventy-two cells scored a harness that never ran. The adapter now errors;
   when adding an entrant, check that a refused run cannot look like a bad one.
7. **`docker ps -aq` is the wrong probe for "the name is free".** The daemon holds the
   container name after the container stops being listed, so the wait passes and
   `compose up` still dies on "name already in use". `run.sh` retries the `up`.
8. **A dead scorecard used to be silent.** `run.sh` runs under `set -e`; `cut3.sh` now
   checks each card's exit status instead of walking on and printing `CUT3 COMPLETO`.

## Traps already paid for — do not re-discover them

1. **`for p in $GLOB`** lets the shell expand the pattern against the CURRENT directory
   before `run.sh` prefixes it. `*.yml` became `compose.yml` and the bench ran one task
   that does not exist. Fixed with `set -f` + `read -ra`.
2. **`compose down` returns before the containers are gone**, and the next `up` dies on
   the name it is about to reuse. Fixed with a wait on the project label.
3. **Anonymisation residue breaks tasks, not just prose.** An order number from the pre-anonymisation fixture survived in task
   02 and the order-number generator, and the task failed on the store while looking
   exactly like a harness that could not read an order. There is now a spec
   (`bench_tasks_spec.rb`) asserting every order number a customer types exists in the
   fixture.
4. **Host memory, not Docker.** The containers total ~350 MB in a 7.7 GiB VM; the Mac
   itself runs out. Pruning images will not help. Close what you can and use the
   resumability.
5. **The bench store must be rebuilt** after any `store/server.rb` change
   (`docker compose build store`) — the seed is a mount, the code is not.

## After the run

```bash
mkdir -p cuts/$(date +%F)
cp -R runs runs-unguarded REPORT.md REPORT-unguarded.md cuts/$(date +%F)/
cp -R tasks cuts/$(date +%F)/tasks       # the questions this cut answered, frozen with it
# plus any arm or probe root the cut produced: runs-reasoning-off, runs-probe-*
./viewer.rb --runs cuts/$(date +%F)     # the page the team reads
ruby compare.rb cuts/<previous>/runs cuts/$(date +%F)/runs   # cell by cell against the last cut
```

`runs/`, `REPORT.md` and `bench.html` are gitignored working output; `cuts/<date>/` is
the published record and IS tracked. Then rewrite the results sections of `README.md`
against the new tables.

`compare.rb` prints, per scorecard, harness and task, the cells passed before and
after and the difference — and marks a task whose file differs between the two cuts'
`tasks/` snapshots as **not comparable**, because its two rows answer two different
questions. Cut 3's snapshot was reconstructed from its commit (`4b84450`); from cut 4
on, the `cp -R tasks` line above is what makes the mark possible. Two cuts are
comparable on a task only when the task, the store image, the model and the
reasoning setting are the same; the script checks the first, the RUNBOOK's traps
above are how you check the rest.

Before any public push, check that the history is clean. The tree is anonymised — the
fixture store is a pseudonym and its one customer is fabricated — but a branch whose
history predates that anonymisation still carries the real catalogue, and a push takes
the history with it. Squashing onto a fresh branch off `main` is what removes it, and
it works precisely because the final tree is already clean:

```bash
git log -p main..HEAD | grep -icE '<the merchant name>'   # must be 0
```
