# Task Plan: Harness Fase 3 (fatia A) — Adapter A2A de borda (federação inbound)

> **Tech Spec:** [00-overview.md](../00-overview.md) + [P3A-01](../P3A-01-a2a-protocol-and-projection.md) · [P3A-02](../P3A-02-agent-card-and-wiring.md)
> **Gerado:** 2026-07-12
> **Progress:** 8/8 tasks complete — fatia A COMPLETA (Etapas A · B) ✅
> **Base:** Fase 2 completa (main @ merge PR #18)

---

## Tasks

| # | Task | File | Componente | Status | Complexity | Spec |
|---|------|------|-----------|--------|------------|------|
| 1 | `A2A::Protocol` (envelope JSON-RPC 2.0: parse/result/error) + `A2A::Errors` (mapa código↔exceção) | [task-01.md](./task-01.md) | P3A-01 | ✅ DONE | Med | 0002 §1, D4/L1-L2 |
| 2 | `A2A::Message` (parts ↔ texto; só TextPart; tolera type/kind) | [task-02.md](./task-02.md) | P3A-01 | ✅ DONE | Low | D4/L3 |
| 3 | `A2A::TaskProjection` (mapa de estado + Task→A2A Task, contextId=session, content→status.message) | [task-03.md](./task-03.md) | P3A-01 | ✅ DONE | Med | D2/D3, L4-L6 |
| 4 | `A2A::AgentCard` (build: name/url/capabilities streaming:false/skills/modes) | [task-04.md](./task-04.md) | P3A-02 | ✅ DONE | Low | D5, L1-L2 |
| 5 | `Server::A2A::App` (`#rpc`: message/send→send_message, tasks/get, tasks/cancel; `#agent_card`) — compõe 1-4 | [task-05.md](./task-05.md) | P3A-02 | ✅ DONE | High | D1/D2/D4, L3-L5 |
| 6 | `Server::App` rotas: `POST /a2a` + `GET /.well-known/agent-card.json` + `handle_a2a` + `@a2a` (default nil → 404) | [task-06.md](./task-06.md) | P3A-02 | ✅ DONE | Med | L6 |
| 7 | Wiring: `A2A_APP` opt-in (`HARNESS_A2A_AGENT`) + inject no `Server::App` + require dos `server/a2a/*` | [task-07.md](./task-07.md) | P3A-02 | ✅ DONE | Low | L7 |
| 8 | Smoke E2E fatia A: message/send→Task; tasks/get projeta terminal; tasks/cancel; agent-card; mapa de erros | [task-08.md](./task-08.md) | P3A-01/02 | ✅ DONE | Med | 00 §"Critério" |

### Status Legend
- ⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

> **Nota:** `task-NN.md` gerados sob demanda por `/create-task {NN}`.

---

## Dependency Graph

```
Etapa A — Camada de tradução A2A (P3A-01/02, tudo em server/a2a/*)
Task 1  → —                (Protocol + Errors, puros)
Task 2  → —                (Message, puro)
Task 3  → —                (TaskProjection, puro)
Task 4  → —                (AgentCard, puro)
Task 5  → 1, 2, 3, 4       (App#rpc/#agent_card compõe todos)

Etapa B — Integração no servidor + wiring + E2E
Task 6  → 5                (rotas no Server::App delegam ao App)
Task 7  → 6                (wiring injeta A2A_APP no Server::App)
Task 8  → 6, 7             (smoke E2E via Server::App real)
```

Etapa A é 100% pura/unitária (sem HTTP, sem RubyLLM). Etapa B integra e valida E2E.

⚠️ **Sem coordenação de arquivo compartilhado forte:** `server/a2a/*` são arquivos
novos e exclusivos; só `server/app.rb` (task 6) e `config/wiring.rb` (task 7) são
tocados, em pontos distintos.

## Summary

- **Total tasks:** 8
- **Complexity:** Med (1 High: task 5 — o handler; 4 Med; 3 Low)
- **PR grouping:**
  - **PR 1 — Etapa A** (tasks 1–5): camada de tradução A2A completa (`server/a2a/*`), 100% unitária.
  - **PR 2 — Etapa B** (tasks 6–8): rotas no `Server::App` + wiring opt-in + smoke E2E.

### Cobertura da tech spec
- **P3A-01** (protocolo/projeção): protocol+errors (1), message (2), projection (3). D2/D3/D4 + L1–L6.
- **P3A-02** (card/app/wiring): agent_card (4), App (5), rotas (6), wiring (7). D1/D5/D6 + L1–L7.
- **Transversal:** smoke dos 6 critérios (8).

### Decisões baked-in (ver overview D1–D6)
1. **A2A é transporte** (RFC-0002 §1/§8): traduz JSON-RPC↔Command, MESMO bus, zero lógica de negócio.
2. **Modelo assíncrono** (D2): `message/send` devolve a Task (`submitted`/`working`); cliente faz `tasks/get`. Sem streaming/bloqueio nesta fatia.
3. **Mapa de estado** Task→TaskState A2A; `waiting`→`input-required` (A2A já era a referência de INPUT_REQUIRED, RFC-0002 §9).
4. **Só TextPart + erros mapeados a códigos A2A**; o App nunca vaza exceção (sempre error object).
5. **Um agente por deployment** (`HARNESS_A2A_AGENT`); opt-in — sem a env, o servidor não expõe A2A (paridade).
6. **Inbound apenas** — o cliente A2A outbound (chamar outros agentes) é a fatia seguinte.

### Concerns / questão em aberto
- **Versão do wire A2A** (nomes de método, path do AgentCard, códigos): fixamos o subconjunto ~v0.2/v0.3; **confirmar contra a versão-alvo do spec** antes de anunciar compat pública (o adapter isola o resto do sistema de mudanças de wire). Ver 00-overview §"Questão em aberto".
- **Conteúdo terminal em `tasks/get`** (P3A-02 L4): o conteúdo final pode não estar num campo lido da Task — pode exigir ler o Execution/checkpoint terminal; edge a resolver na task 5.
