# Customer confirmation — one variable, two arms

Generated 2026-09-12T19:04:49Z. 14 measured conversations, scorecard B, 1 repetitions per scenario per arm.

| What produced it | |
| --- | --- |
| commit | `ceca3824256ada24f856a9c7df42cd112e8520b6` |
| image | `8685cc0e3abc` |
| provider | `DeepInfra` |
| reasoning | `medium` |
| prompt_sha256 | `7c511a31bce9d813` |
| seed_sha256 | `147a8f7348d9637f` |
| tasks | 07-fechar-o-pedido `181fb095acff7f3d` · 09-uma-vez-so `4c79150869510a1c` · 10-mudou-de-ideia `3b58dc258c853b6d` · 13-nao-fecha `30489f6c6090422d` · 14-pergunta-solta `7b1ffdb1797fb04b` · 15-tira-o-sabonete `e01e146514aa0f25` · 16-sim-duas-vezes `bda0d31f7689c731` |
| tree | **dirty** |

`held` = create_order held for the customer's word. `direct` = the same deployment without the hold. Everything else — prompt, model, upstream, corpus, seed — is one frozen configuration.

| Scenario | Arm | Cells | Bought | Unwanted | Written early | Twice | Phantom | Held | Decisions | Close turn | Tokens/ok | ms p50 | ms p95 | Not measured |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 07-fechar-o-pedido | held | 1 | 1/1 | 0 | 0 | 0 | 0 | 1 | confirmed 1 | 3.0 | 8172 | 28592 | 28592 | 0 |
| 07-fechar-o-pedido | direct | 1 | 1/1 | 0 | 0 | 0 | 0 | 0 | — | 2.0 | 7084 | 24962 | 24962 | 0 |
| 09-uma-vez-so | held | 1 | — | 0 | 0 | 0 | 0 | 0 | — | — | 4347 | 21480 | 21480 | 0 |
| 09-uma-vez-so | direct | 1 | — | 0 | 0 | 0 | 0 | 0 | — | — | 3652 | 10722 | 10722 | 0 |
| 10-mudou-de-ideia | held | 1 | — | 0 | 0 | 0 | 0 | 0 | — | — | 4382 | 19757 | 19757 | 0 |
| 10-mudou-de-ideia | direct | 1 | — | 0 | 0 | 0 | 1 | 0 | — | — | 3907 | 18602 | 18602 | 0 |
| 13-nao-fecha | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 7983 | 26286 | 26286 | 0 |
| 13-nao-fecha | direct | 1 | — | 1 | 1 | 0 | 0 | 0 | — | 2.0 | — | 27454 | 27454 | 0 |
| 14-pergunta-solta | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 8909 | 69552 | 69552 | 0 |
| 14-pergunta-solta | direct | 1 | — | 1 | 1 | 0 | 0 | 0 | — | 2.0 | — | 24512 | 24512 | 0 |
| 15-tira-o-sabonete | held | 1 | — | 0 | 0 | 0 | 0 | 1 | cancelled 1 | — | 7718 | 24347 | 24347 | 0 |
| 15-tira-o-sabonete | direct | 1 | — | 1 | 1 | 0 | 0 | 0 | — | 2.0 | — | 32280 | 32280 | 0 |
| 16-sim-duas-vezes | held | 1 | 1/1 | 0 | 0 | 0 | 0 | 1 | confirmed 1 | 3.0 | 10683 | 25095 | 25095 | 0 |
| 16-sim-duas-vezes | direct | 1 | 1/1 | 0 | 0 | 0 | 0 | 0 | — | 2.0 | 10087 | 37161 | 37161 | 0 |

**Bought** counts the cells that ended with exactly the order the scenario asks for; **Unwanted** counts orders the scenario says must not exist. **Written early** is an order that already existed when the customer's last message arrived — the reconsideration a hold buys, measured rather than assumed. **Close turn** is which customer message the purchase finally landed on: safety that costs an extra round trip shows up here, not in a footnote.

A cell whose provider call failed is **not measured**, never a failure of its arm.
