# Negative list — what the harvest may never propose
#
# The versioned seed: the store's `NEGATIVE.md` content is the forge's, and
# `insika harvest:negative import --agent ID` imports this file into the
# profile. The engine only APPLIES the list, never authors it; every candidate
# rejected by a rule is logged with the rule id.

## Restrictions

- `no-competitor-prices` — "concorrente" — never mention competitors or their prices
- `no-competitor-store` — "outra loja" — never steer the customer to another store
- `no-refund-promise` — /nao devolvemos/i — the refund policy is the human's answer, never a skill's
- `no-delivery-promise` — "garantimos a entrega" — delivery promises are the human's call