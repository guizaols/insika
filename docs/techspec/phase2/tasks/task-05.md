# Task 05 (P2): `PendingActionStore` (record durável de aprovação)

> **Techspec:** [P2-02-approval.md](../P2-02-approval.md) (D2, L3). **Status:** 🟡 IN PROGRESS
> **Complexity:** Med · **Etapa:** B · **Depende:** — (só stores da Fase 1)

## Objetivo
Store de domínio para o record de aprovação (D2: "estado como record, não flag").
Sobrevive a `kill -9` — o operador aprova depois do reboot.

## Interface (`lib/harness/pending_action_store.rb`)
```ruby
PendingAction = Data.define(:id, :task_id, :turn, :tool, :args,
                            :status, :requested_at, :resolved_by, :resolved_at)
STATUSES = %i[pending approved rejected]
create(task_id:, turn:, tool:, args:) -> PendingAction   # :pending
find(id) -> PendingAction | nil
open_for(task_id) -> [PendingAction]                     # só :pending (recovery/UI)
resolve(id, decision:, operator:) -> PendingAction       # :pending -> :approved|:rejected
```
- Backend `Harness::Store` injetado; scope `"pending_actions"`, chave
  `pending:<uuid>`. `open_for` faz scan O(n) filtrando por task_id + :pending
  (aceitável Fase 1/2, single-node — igual `TaskStore#running_or_interrupted`).
- `resolve`: `NotFoundError` se ausente; `ValidationError` se já resolvida
  (só `:pending` resolve — edge 1) ou decision inválida. Normaliza symbol→string
  na escrita (padrão dos stores da Fase 1).

## Testes (`spec/harness/pending_action_store_spec.rb`)
- create → :pending com campos; find; open_for filtra por task/status; resolve
  approved/rejected grava operador+timestamp; resolve de ausente → NotFound;
  resolve dupla → ValidationError; decision inválida → ValidationError;
  round-trip de tipos (args aninhado) via Memory backend.

## DoD
- [ ] store + spec verdes; suíte inteira verde
