# Customer confirmation — one variable, two arms

Generated 2026-09-13T00:29:15Z. 6 conversations, scorecard B, 1 repetitions per scenario per arm.

| What produced it | |
| --- | --- |
| commit | `d32d5f1740735b59709469cbfbf0fa8dd1133c7e` |
| image | `b85636928cc3` |
| model | `deepseek/deepseek-v4-flash` |
| provider | `DeepInfra` |
| reasoning | `medium` |
| prompt_sha256 | `7802ca7fd0edd3fc` |
| seed_sha256 | `147a8f7348d9637f` |
| tasks | 07-fechar-o-pedido `181fb095acff7f3d` · 09-uma-vez-so `4c79150869510a1c` · 10-mudou-de-ideia `3b58dc258c853b6d` · 13-nao-fecha `30489f6c6090422d` · 14-pergunta-solta `7b1ffdb1797fb04b` · 15-tira-o-sabonete `e01e146514aa0f25` · 16-sim-duas-vezes `bda0d31f7689c731` |
| tree | **dirty** |

`held` = create_order held for the customer's word. `direct` = the same deployment without the hold. Everything else — prompt, model, upstream, corpus, seed — is one frozen configuration.

| Scenario | Arm | Cells | Bought | Unwanted | Written early | Twice | Phantom | Held | Decisions | Close turn | Tokens/ok | ms p50 | ms p95 | Not measured |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 07-fechar-o-pedido | held | 1 | 1/1 | 0 | 0 | 0 | 0 | 1 | confirmed 1 | 3.0 | 8312 | 17691 | 17691 | 0 |
| 09-uma-vez-so | held | 1 | — | 0 | 0 | 0 | 0 | 1 | — | — | 4489 | 14678 | 14678 | 0 |
| 10-mudou-de-ideia | held | 1 | — | 0 | 0 | 0 | 0 | 0 | — | — | 4642 | 15675 | 15675 | 0 |
| 13-nao-fecha | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 8175 | 18832 | 18832 | 0 |
| 14-pergunta-solta | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 8937 | 18376 | 18376 | 0 |
| 15-tira-o-sabonete | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 8390 | 20824 | 20824 | 0 |

**Bought** counts the cells that ended with exactly the order the scenario asks for; **Unwanted** counts orders the scenario says must not exist. **Written early** is an order that already existed when the customer's last message arrived — the reconsideration a hold buys, measured rather than assumed. **Close turn** is which customer message the purchase finally landed on: safety that costs an extra round trip shows up here, not in a footnote.

A cell whose provider call failed is **not measured**, never a failure of its arm.
