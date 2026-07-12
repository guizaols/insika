# Task Plan: Harness Fase 3 (fatia B) — A2A outbound (federação de saída)

> **Tech Spec:** [00-overview.md](../00-overview.md) + [P3B-01](../P3B-01-a2a-client.md) · [P3B-02](../P3B-02-remote-tool-and-wiring.md)
> **Gerado:** 2026-07-12
> **Progress:** 7/7 tasks complete — fatia B COMPLETA (Etapas A · B) ✅
> **Base:** Fase 3 fatia A completa (main @ merge PR #20)

---

## Tasks

| # | Task | File | Componente | Status | Complexity | Spec |
|---|------|------|-----------|--------|------------|------|
| 1 | `A2A::Client` — `send_message`/`get_task` (monta JSON-RPC via Protocol/Message; parseia envelope; lê Task remota) + `RemoteError` | [task-01.md](./task-01.md) | P3B-01 | ✅ DONE | Med | 0002 §1, L1-L3 |
| 2 | `A2A::Client#call` — send + poll `tasks/get` até terminal + encapsula erro | [task-02.md](./task-02.md) | P3B-01 | ✅ DONE | Med | D3, L4-L5 |
| 3 | `A2A::Http` — adapter `post_json` sobre async-http (boundary; require lazy) | [task-03.md](./task-03.md) | P3B-01 | ✅ DONE | Low | D2, L6 |
| 4 | `Tools::A2ARemote` — RubyLLM::Tool por remoto (execute→client.call; `:a2a_call`; name/desc por instância) | [task-04.md](./task-04.md) | P3B-02 | ✅ DONE | Med | D1/D4, L1-L3 |
| 5 | `A2A::Remotes.parse` — config `id=url,..` → [Remote] | [task-05.md](./task-05.md) | P3B-02 | ✅ DONE | Low | D6 |
| 6 | Wiring: `A2A_CLIENT` + `Http` + registro lazy dos tools remotos + catálogo D5 (`:a2a_call`) + wiring-load spec | [task-06.md](./task-06.md) | P3B-02 | ✅ DONE | Med | D5/D6/D7, L4-L5 |
| 7 | Smoke E2E loopback: orchestrator chama remote_worker → inbound A2A::App roda o worker → resposta volta; erro remoto; paridade | [task-07.md](./task-07.md) | P3B-01/02 | ✅ DONE | Med | 00 §"Critério" |

### Status Legend
- ⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

> **Nota:** `task-NN.md` gerados sob demanda por `/create-task {NN}`.

---

## Dependency Graph

```
Etapa A — Cliente + tool (unit)
Task 1  → —              (Client send/get; reusa Protocol/Message da fatia A)
Task 2  → 1              (Client#call: poll)
Task 3  → —              (Http adapter, boundary)
Task 4  → 2              (A2ARemote usa client.call)

Etapa B — Config + wiring + smoke
Task 5  → —              (Remotes.parse)
Task 6  → 3, 4, 5        (wiring registra tools com client+http)
Task 7  → 6              (smoke loopback)
```

Etapa A é unitária (http fake). Etapa B integra e valida o loopback outbound→inbound.

⚠️ **Sem coordenação de arquivo forte:** `server/a2a/{client,http,remotes}.rb` e
`lib/harness/tools/a2a_remote.rb` são novos; só `config/wiring.rb` (task 6) e o
catálogo D5 são tocados.

## Summary

- **Total tasks:** 7
- **Complexity:** Med (0 High — reusa a camada de tradução da fatia A; 4 Med, 3 Low)
- **PR grouping:**
  - **PR 1 — Etapa A** (tasks 1–4): `A2A::Client` + `Http` + `Tools::A2ARemote` (unitário).
  - **PR 2 — Etapa B** (tasks 5–7): config/registro + wiring + smoke loopback.

### Cobertura da tech spec
- **P3B-01** (client): send/get (1), call/poll (2), http (3). D2/D3/D4 + L1–L6.
- **P3B-02** (tool/wiring): tool (4), config (5), wiring+eventos (6). D1/D5/D6/D7 + L1–L5.
- **Transversal:** smoke loopback (7).

### Decisões baked-in (ver overview D1–D7)
1. **Remoto = TOOL** (D1) governada pela allowlist; nome `remote_<id>`.
2. **HTTP injetado** (D2): Client puro; smoke usa **loopback** (outbound→inbound in-process).
3. **`call` faz poll até terminal** (D3), envelopado (timeout do turno protege).
4. **Erro remoto → `{ error: }` ao modelo** (D4); turno segue.
5. **Require lazy no bloco de registro** (D5): wiring-load gem-free (D9).
6. **Opt-in** por `HARNESS_A2A_REMOTES`; sem env → nada registrado (paridade).

### Concerns
- **`:a2a_call` sem correlação de task** (P3B-02 L3): tools de registry não recebem TurnState; o event sai com `meta: {}` (o `:tool_call` do wire_callbacks já correlaciona a chamada).
- **`Http` toca a rede** (boundary, L6): o Client é testado com fake; o smoke usa loopback; `Http` real fica com teste leve — a validação contra um A2A remoto REAL é o de-risk de "rodar de verdade".
