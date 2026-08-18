# Negative list fixture — what the harvest may never propose
#
# The real list is the store's own, read from the file INSIKA_HARVEST_NEGATIVE
# points at. This fixture exists so the deployment wiring spec boots with one.

## Restrictions

- `no-competitor-prices` — "concorrente" — never mention competitors or their prices
- `no-competitor-store` — "outra loja" — never steer the customer to another store
- `no-refund-promise` — /nao devolvemos/i — the refund policy is the human's answer, never a skill's
- `no-delivery-promise` — "garantimos a entrega" — delivery promises are the human's call