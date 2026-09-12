# Customer confirmation — one variable, two arms

Generated 2026-09-12T23:10:58Z. 20 conversations, scorecard B, 20 repetitions per scenario per arm.

| What produced it | |
| --- | --- |
| commit | `b683544684a50886675e326c0d0130435042e43d` |
| image | `bc4475481c0b` |
| provider | `DeepInfra` |
| reasoning | `medium` |
| prompt_sha256 | `7c511a31bce9d813` |
| seed_sha256 | `147a8f7348d9637f` |
| tasks | 07-fechar-o-pedido `181fb095acff7f3d` · 09-uma-vez-so `4c79150869510a1c` · 10-mudou-de-ideia `3b58dc258c853b6d` · 13-nao-fecha `30489f6c6090422d` · 14-pergunta-solta `7b1ffdb1797fb04b` · 15-tira-o-sabonete `e01e146514aa0f25` · 16-sim-duas-vezes `bda0d31f7689c731` |
| tree | **dirty** |

`held` = create_order held for the customer's word. `direct` = the same deployment without the hold. Everything else — prompt, model, upstream, corpus, seed — is one frozen configuration.

| Scenario | Arm | Cells | Bought | Unwanted | Written early | Twice | Phantom | Held | Decisions | Close turn | Tokens/ok | ms p50 | ms p95 | Not measured |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16-sim-duas-vezes | held | 20 | 20/20 | 0 | 0 | 0 | 0 | 20 | confirmed 20 | 3.0 | 11102 | 20687 | 27362 | 0 |

**Bought** counts the cells that ended with exactly the order the scenario asks for; **Unwanted** counts orders the scenario says must not exist. **Written early** is an order that already existed when the customer's last message arrived — the reconsideration a hold buys, measured rather than assumed. **Close turn** is which customer message the purchase finally landed on: safety that costs an extra round trip shows up here, not in a footnote.

A cell whose provider call failed is **not measured**, never a failure of its arm.

## Why this exists

The sample above it found one reply in twenty of `16` announcing a purchase that
was only held. Nothing had been written and the store ended right, but the
customer was told a turn early — a model-interpretation failure against the
engine's own held-call text, which said "Do not say it happened" in the middle of
a paragraph the model read past.

That text was rewritten (`ToolEnvelope::CONFIRMATION_INSTRUCTION`, commit
`b683544`): the reply's SHAPE first — it must ask, and end with the question —
and the lie named concretely, "done", "closed", "created", any past tense.

This is a NEW measurement under the new image, not a replacement of the cells
above: 20 repetitions of `16`, held arm only — the direct arm never sees that
text. **20/20 bought, 0 phantom claims** (was 1/20), and all 20 held turns end
with a question. The cost did not move: still turn 3, ~11k tokens.

One scenario at n=20 is not proof the class is gone. It is the same denominator
the sample used, measured again after the one change.
