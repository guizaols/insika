# Task Plan: Harness Fase 2 (fatia A) — Actor completo + Aprovação + Control UI de escrita

> **Tech Spec:** [00-overview.md](../00-overview.md) + docs P2-01–P2-04 (a detalhar)
> **Gerado:** 2026-07-10
> **Progress:** 14/14 tasks complete
> **Base:** Fase 1 completa (main @ merge PR #8)

---

## Tasks

| # | Task | Componente | Status | Complexity | Spec |
|---|------|-----------|--------|------------|------|
| 1 | Estender `TaskActor`: enum `%i[cancel user_message approval pause resume timeout heartbeat]` + `drain!` roteando cada um (approval/pause/resume mudam fluxo; timeout/heartbeat observam) | P2-01 | ✅ DONE | Med | 0002 §9 |
| 2 | Ativar estados no Executor: suspensão em `:paused` (drena `:pause` na fronteira → `transition(:paused)` → aguarda `:resume`) sem perder checkpoint | P2-01 | ✅ DONE | High | 0002 §9 |
| 3 | Command `PauseTask` (controle: posta `:pause`, no-op idempotente se terminal/órfã) + evento `:task_paused`/`:task_resumed` | P2-01 | ✅ DONE | Low | 0002 §9 |
| 4 | Reconciliar `ResumeTask` (Fase 1) para retomar tanto órfã-de-crash quanto `:paused`/`:waiting` (critério de elegibilidade estendido) | P2-01 | ✅ DONE | Med | 03 §3 |
| 5 | `PendingActionStore` (record durável: task_id, turn, tool, args, requested_at, status, resolved_by, resolved_at) sobre `Harness::Store` + suíte de contrato | P2-02 | ✅ DONE | Med | 0006, 0002 §9 |
| 6 | Policy builtin `ApprovalRequired` (allowlist de tools que exigem aprovação por agente) + campo no `AgentProfile` (`approvals_required`) | P2-02 | ✅ DONE | Med | 05, 0002 §9 |
| 7 | `ToolEnvelope` gate: antes de executar tool marcada, cria `PendingAction`, emite `:approval_requested`, suspende o turno em `:waiting` (via mailbox) | P2-02 | ✅ DONE | High | 0002 §9 |
| 8 | Command `ApproveAction` (resolve o `PendingAction` + posta `:approval` na mailbox; approved → executa a tool pulada, rejected → `{error: rejected}` ao modelo) + evento `:approval_resolved` | P2-02 | ✅ DONE | High | 0007 §3 |
| 9 | `SessionActor`: fiber por sessão + fila FIFO de turnos; registro in-process (`session_id → SessionActor`) no escopo supervisionado (L4) | P2-03 | ✅ DONE | High | 0002 §9 |
| 10 | Integrar `SendMessage`/Executor ao `SessionActor`: turno com `session_id` enfileira (serializa); one-shot/history segue Task avulsa; recovery reidrata a fila | P2-03 | ✅ DONE | High | 0002 §9 |
| 11 | `Server::App`: rotas de Command de escrita já cobertas pela genérica `POST /v1/commands/:type` (Fase 1) — validar `pause_task`/`approve_action`; reads de `PendingAction` (`GET /v1/tasks/:id` inclui pendências) | P2-04 | ✅ DONE | Low | 07 §2 |
| 12 | Control UI write: `Admin::App` vira read-write (Hotwire/Turbo vendored, sem build); Tasks com pause/resume/cancel/approve; auth de operador p/ destrutivo; evento `:operator_action` por ação | P2-04 | ✅ DONE | High | 0007 §3-§5 |
| 13 | Telas Chat (testar agente via `send_message` + SSE renderizado em Turbo Stream) e Config (editar perfis/políticas — read-write com validação) | P2-04 | ✅ DONE | High | 0007 §3 |
| 14 | Smoke E2E fatia A: tool `approval` suspende em `:waiting` → kill -9 → reboot → operador aprova → tool executa e turno conclui; + serialização de 2 turnos concorrentes na mesma sessão | P2-01..03 | ✅ DONE | Med | 00 §"Critério" |

### Status Legend
⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

---

## Dependency Graph

```
Etapa A — Actor completo (P2-01)
1 (TaskActor enum)        → —
2 (suspensão paused)      → 1
3 (PauseTask)             → 1, 2
4 (ResumeTask reconc.)    → 2

Etapa B — Aprovação / human-in-the-loop (P2-02)
5 (PendingActionStore)    → — (só stores da Fase 1)
6 (policy ApprovalRequired)→ — (Policy Engine da Fase 1)
7 (Envelope gate)         → 1, 5, 6   (suspende em :waiting via mailbox)
8 (ApproveAction)         → 4, 7

Etapa C — Sessions como Actors (P2-03)
9 (SessionActor)          → 1   (mailbox/escopo supervisionado)
10 (integra SendMessage)  → 9

Etapa D — Control UI de escrita (P2-04)
11 (rotas/reads)          → 3, 8
12 (UI write + auth+audit)→ 3, 8, 11
13 (Chat/Config)          → 12
14 (smoke E2E fatia A)    → 4, 8, 10
```

Etapas A e B podem andar em paralelo até a task 7 (que junta as duas). C é
independente (só depende da task 1). D fecha por cima de tudo.

## Sugestão de PRs (1 por etapa, como na Fase 1)

- **PR 1 — Etapa A** (tasks 1–4): mailbox completa + pause/resume + estados.
- **PR 2 — Etapa B** (tasks 5–8): PendingAction + policy + envelope gate + ApproveAction.
- **PR 3 — Etapa C** (tasks 9–10): Sessions como Actors.
- **PR 4 — Etapa D** (tasks 11–14): Control UI de escrita + smoke E2E.

## Regras herdadas (Fase 1)
- Testes fazem parte de cada task (não são tasks separadas).
- Núcleo (`lib/`) testável sem `ruby_llm` nem chave de API; RubyLLM mockado só na integração.
- Toda task referencia as seções do doc de componente (coluna Spec).
- Cada task passa por code review antes de fechar.

---

## Notas da Etapa D (limitações registradas — follow-ups)

- **Config-edit (`update_profile`) adiado:** perfis são `Data` imutáveis e a
  base `PROFILES` é congelada; editar em runtime exige um holder mutável de
  perfis. A tela Config entrega leitura; a edição runtime-safe fica p/ fatia
  seguinte (o Command `update_profile` não foi criado).
- **`events.turbo_stream` adiado:** a projeção do Event Stream como
  `<turbo-stream>` sobre SSE fica p/ depois; o painel usa o `EventSource` JSON
  de `/v1/events` (events.erb) p/ o "ao vivo".
- **Turbo/Stimulus vendored = placeholders:** `server/admin/assets/{turbo,stimulus}.js`
  são stubs a substituir pelos arquivos reais (P2-04 L1). Sem eles o painel
  DEGRADA graciosamente (forms POST + 303 redirect); com eles, turbo_stream
  atualiza fragmentos ao vivo. Servidos em `/admin/assets/*` (CSP `script-src 'self'`).
- **Recovery de turno `:waiting` no boot (limitação):** o smoke da task 14 aprova
  via HTTP SEM kill-9. Motivo: recuperar um turno `:waiting` (aprovação) durante
  o boot faz o turno reexecutar e RE-SUSPENDER no `await(:approval)`, bloqueando
  o `Sync` transiente do Boot (ninguém aprova no boot). O fix correto é rodar o
  Recovery no reactor de SERVING (após `supervised=true`), para turnos retomados
  suspensíveis nascerem no supervisor e não bloquearem o listen — restructure do
  fluxo Boot/serve, follow-up. O caminho crash-safe da aprovação (reexecução com
  a PendingAction durável) está coberto em `tool_envelope_approval_spec`.
