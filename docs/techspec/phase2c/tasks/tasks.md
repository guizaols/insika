# Task Plan: Harness Fase 2 (fatia C) — Memória cross-session (profile + notes)

> **Tech Spec:** [00-overview.md](../00-overview.md) + [P2C-01](../P2C-01-memory-store-and-read.md) · [P2C-02](../P2C-02-remember-tool-and-wiring.md)
> **Gerado:** 2026-07-12
> **Progress:** 4/8 tasks complete (PR 1 / Etapa A ✅)
> **Base:** Fase 2-B completa (main @ merge PR #16)

---

## Tasks

| # | Task | File | Componente | Status | Complexity | Spec |
|---|------|------|-----------|--------|------------|------|
| 1 | `MemoryStore` (facts + notes, scope por tenant, records + normalização) + suíte de contrato | [task-01.md](./task-01.md) | P2C-01 | ✅ DONE | Med | 0005 §6, 0006 |
| 2 | `AgentProfile.memory` (opt-in; nil = OFF, paridade) | [task-02.md](./task-02.md) | P2C-01 | ✅ DONE | Low | 0005 §6, D5 |
| 3 | Threading de tenant: `Executor::ContextRequest` + `:tenant`, `command_tenant` helper, `TurnState#tenant` no `run_pipeline` | [task-03.md](./task-03.md) | P2C-01 | ✅ DONE | Med | D6 |
| 4 | `Context::Providers::Memory` (read: facts + N notes recentes → fragmento `:system` p75; `enabled_for?` por `profile.memory`) | [task-04.md](./task-04.md) | P2C-01 | ✅ DONE | Med | 0005 §6, L5-L8 |
| 5 | `Tools::Remember` builtin (fato/note via `MemoryStore` + `:memory_written` + `def name`) | [task-05.md](./task-05.md) | P2C-02 | ⬜ TODO | Med | 0005 §6, D3/D4 |
| 6 | Executor `configure_chat`: cabeia `remember` de sistema (gate `@memory_store` + `profile.memory`) + `create_chat` lazy require | [task-06.md](./task-06.md) | P2C-02 | ⬜ TODO | Med | 0002 §6, L2 |
| 7 | Wiring: `MEMORY_STORE` + provider em `CONTEXT_PROVIDERS` + inject no Executor + catálogo D5 (`:memory_written`) + wiring-load spec | [task-07.md](./task-07.md) | P2C-02 | ⬜ TODO | Low | D8 |
| 8 | Smoke E2E fatia C: grava fato/note na sessão 1 → sessão 2 (mesmo tenant) lembra; paridade `memory:nil` | [task-08.md](./task-08.md) | P2C-01/02 | ⬜ TODO | Med | 00 §"Critério" |

### Status Legend
- ⬜ TODO — Not started
- 🟡 IN PROGRESS — Being worked on
- ✅ DONE — Completed and tested
- ⛔ BLOCKED — Waiting on dependency

> **Nota:** `task-NN.md` gerados sob demanda por `/create-task {NN}` — este plano é o índice.

---

## Dependency Graph

```
Etapa A — Store + Read (P2C-01)
Task 1  → —                         (MemoryStore, puro/store)
Task 2  → —                         (AgentProfile.memory)
Task 3  → —                         (tenant threading no Executor)
Task 4  → 1, 2, 3                   (provider usa store + memory flag + request.tenant)

Etapa B — Write + wiring + E2E (P2C-02)
Task 5  → 1                         (Tools::Remember usa o MemoryStore)
Task 6  → 3, 5                      (configure_chat: state.tenant + a tool)
Task 7  → 4, 6                      (wiring de provider + store + eventos)
Task 8  → 4, 6, 7                   (smoke E2E)
```

Etapa A é independente e fecha a leitura; Etapa B fecha a escrita + wiring + E2E.

⚠️ **Coordenação de arquivo compartilhado** (`executor.rb`): task **3** edita
`build_context_request`/`run_pipeline` (tenant) e o Struct `ContextRequest`; task
**6** edita `configure_chat`/`create_chat`. Áreas distintas — sequenciar 3 antes
de 6 (a task 6 lê `state.tenant` que a task 3 seta).

## Summary

- **Total tasks:** 8
- **Estimated total complexity:** Med (0 High — fatia deliberadamente enxuta e determinística; 5 Med, 3 Low)
- **Suggested PR grouping** (1 PR por etapa):
  - **PR 1 — Etapa A** (tasks 1–4): `MemoryStore` + `AgentProfile.memory` + tenant threading + read provider.
  - **PR 2 — Etapa B** (tasks 5–8): `Tools::Remember` + executor/wiring + smoke E2E.

### Cobertura da tech spec
- **P2C-01** (store + read): store (1), profile (2), tenant (3), provider (4). Decisões D1/D2/D5/D6/D7 + L1–L8.
- **P2C-02** (write + wiring): tool (5), executor (6), wiring+eventos (7). Decisões D3/D4/D8 + L1–L5.
- **Transversal:** smoke dos 4 critérios (8).

### Decisões baked-in (ver overview D1–D8)
1. **Entrada determinística:** só camadas `profile`+`notes` (k/v + append), sem embeddings/extractor por LLM — testável sem chave de API. Semantic/auto-extract = fatia D.
2. **Escopo por tenant** (`memory:<tenant>`, fallback `_default`) — NÃO por session (seria session-scoped) nem agent.
3. **Write = tool explícita `remember`** (determinística); read = provider (sem evento); write emite `:memory_written` — simetria da fatia B.
4. **Opt-in por agente** (`AgentProfile.memory`); paridade Fase 1 por omissão do flag OU do `memory_store` no wiring.
5. **Reconcilia parte do débito da Fase 1:** `tenant` finalmente entra no `Executor::ContextRequest` (o `Request` provider já o chamava).

### Concerns registrados (não bloqueiam)
- **Resume-safety de notes** (P2C-02 L5): `remember` não é envelopada; uma note pode duplicar num resume pós-crash (fato é idempotente-por-key). Aceitável (memória ≠ transação); envelopar é evolução.
- **Nomenclatura** `MemoryStore` (domínio) vs `Stores::Memory` (backend) — namespaces distintos + comentário (D7).
