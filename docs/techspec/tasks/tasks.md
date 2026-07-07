# Task Plan: Harness Fase 1 — Pipeline & Plataforma

> **Jira:** — (sem ticket; origem: pacote de handoff)
> **Tech Spec:** [00-overview.md](../00-overview.md) + docs [01](../01-persistence-stores.md)–[07](../07-service-platform.md)
> **Generated:** 2026-07-06
> **Progress:** 2/26 tasks complete

---

## Tasks

| # | Task | File | Status | Complexity | Spec |
|---|------|------|--------|------------|------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | [task-01.md](./task-01.md) | ✅ DONE | Med | 00 D4-D6, D8 |
| 2 | Interface `Harness::Store` + suíte de contrato compartilhada (shared examples) | [task-02.md](./task-02.md) | ✅ DONE | Med | 01 §2, §7 |
| 3 | Backend `Stores::Memory` com rollback real de transação | [task-03.md](./task-03.md) | ⬜ TODO | Low | 01 §2 |
| 4 | Backend `Stores::SQLite` (WAL, tabela `kv`, semáforo de escrita) | [task-04.md](./task-04.md) | ⬜ TODO | Med | 01 §3, §5 |
| 5 | `SessionStore` (schema `session:<id>`, transcript como fonte da verdade) | [task-05.md](./task-05.md) | ⬜ TODO | Low | 02 §2-§3 |
| 6 | `TaskStore` (máquina de estados validada, Executions, campos de claim reservados) | [task-06.md](./task-06.md) | ⬜ TODO | Med | 02 §2-§3 |
| 7 | `CheckpointStore` (checkpoint por turno, chave avulsa de side-effects, `prune`) | [task-07.md](./task-07.md) | ⬜ TODO | Med | 02 §2-§3 |
| 8 | `Recovery` no boot (varredura + dispatch de resume; bus como duplo até a task 13) | [task-08.md](./task-08.md) | ⬜ TODO | Med | 02 §4, §6 |
| 9 | `Command` + `CommandBus` + handlers de controle (`CreateSession`, `CancelTask`) | [task-09.md](./task-09.md) | ⬜ TODO | Med | 03 §2-§3 |
| 10 | `Executor` esqueleto: fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream` | [task-10.md](./task-10.md) | ⬜ TODO | High | 03 §2, §5 |
| 11 | Migrar `runner.rb` → estágios 6-7 (build_chat/seed/callbacks RubyLLM intactos, `max_tool_calls` no hook) | [task-11.md](./task-11.md) | ⬜ TODO | Med | 03 §4.2, §6 |
| 12 | Handler `SendMessage` end-to-end (providers stub) + checkpoint no estágio 8 + timeouts D4 | [task-12.md](./task-12.md) | ⬜ TODO | High | 03 §3-§4 |
| 13 | Handler `ResumeTask` (critério running-órfã, skip de side-effects) + integração real do Recovery | [task-13.md](./task-13.md) | ⬜ TODO | Med | 03 §3, §4.1 |
| 14 | `ContextFragment`/`ContextProvider`/`Builder` (fan-out Async, orçamento global, pinned, evicção) | [task-14.md](./task-14.md) | ⬜ TODO | High | 04 §2-§4 |
| 15 | Providers `Request`, `Prompt` (absorve SystemPrompt/SOUL.md + prompt_refs), `Skill`, `Session` (teto 79) | [task-15.md](./task-15.md) | ⬜ TODO | Med | 04 §2, §8 |
| 16 | Classe `Hooks` (mecanismo around) + par `before/after_prompt` envolvendo o Builder | [task-16.md](./task-16.md) | ⬜ TODO | Low | 05 §2, 04 §4 |
| 17 | `Policy::Engine` + builtins `Tool/Skill/WorkflowAllowlist` (absorve `ToolRegistry#resolve`, fail-closed) | [task-17.md](./task-17.md) | ⬜ TODO | Med | 05 §2-§4 |
| 18 | `MiddlewareStack` rack-like (`TurnState` mutável, `halt_reason`) | [task-18.md](./task-18.md) | ⬜ TODO | Low | 05 §2-§3 |
| 19 | Pares de hook restantes (`before/after_task`, `_agent`, `_tool`) integrados ao Executor | [task-19.md](./task-19.md) | ⬜ TODO | Med | 05 §2, 03 §4 |
| 20 | `Registry` genérico + Workflow/Policy Registries + `PromptCatalog` (PROMPT.md) | [task-20.md](./task-20.md) | ⬜ TODO | Med | 06 §2 |
| 21 | `Plugin::Loader` estendido: manifesto `harness.plugin.yml` (compat), config_schema, rollback parcial, novos registros | [task-21.md](./task-21.md) | ⬜ TODO | Med | 06 §2-§4 |
| 22 | Autodiscovery por gem (`Plugin.announce`, precedência workspace > gem > bundled) | [task-22.md](./task-22.md) | ⬜ TODO | Low | 06 §2, §4 |
| 23 | Handler `TriggerWorkflow` (workflow = 1 turno lógico, tools filtradas pela Resolution) | [task-23.md](./task-23.md) | ⬜ TODO | Med | 03 §4.1, 06 §2 |
| 24 | Rotas formais: `POST /v1/commands/:type` + açúcar, reads GET, `/v1/events` SSE (heartbeat, cap), rota legada | [task-24.md](./task-24.md) | ⬜ TODO | Med | 07 §2-§4 |
| 25 | Esqueleto Control UI `/admin` read-only (ERB) + `AdminAuth` fail-closed | [task-25.md](./task-25.md) | ⬜ TODO | Med | 07 §2, §6 |
| 26 | `Gemfile` pinado + Gemfile.lock + `Server::Boot` (plugins→recovery→listen) + smoke E2E kill -9 | [task-26.md](./task-26.md) | ⬜ TODO | Med | 00 D9, 07 §4, §7 |

### Status Legend
- ⬜ TODO — Not started
- 🟡 IN PROGRESS — Being worked on
- ✅ DONE — Completed and tested
- ⛔ BLOCKED — Waiting on dependency

---

## Dependency Graph

```
1 (tipos base)          → —
2 (Store + suíte)       → 1
3 (Memory)              → 2
4 (SQLite)              → 2
5 (SessionStore)        → 3
6 (TaskStore)           → 3
7 (CheckpointStore)     → 3
8 (Recovery c/ duplo)   → 6, 7
9 (Command/Bus/controle)→ 1, 5, 6
10 (Executor esqueleto) → 6, 9
11 (migração runner)    → 10
12 (SendMessage e2e)    → 7, 10, 11
13 (ResumeTask+Recovery)→ 8, 12
14 (Builder)            → 1
15 (Providers)          → 5, 14, 20*   (*Prompt c/ catalog: só o parâmetro; 20 pode chegar depois com nil)
16 (Hooks + par prompt) → 14
17 (Policy Engine)      → 1, 14
18 (Middleware)         → 10
19 (pares restantes)    → 10, 16
20 (Registries/Catalog) → 1
21 (Plugin Loader)      → 17, 20
22 (Autodiscovery)      → 21
23 (TriggerWorkflow)    → 12, 17, 20
24 (Rotas formais)      → 9, 12
25 (Control UI)         → 24
26 (Boot + smoke E2E)   → 13, 22, 24
```

Sem dependência de task posterior; 14/17/20 podem andar em paralelo à Etapa C
(times/worktrees separados).

## Summary

- **Total tasks:** 26
- **Estimated total complexity:** High (3 tasks High: 10, 12, 14 — o Executor e o Builder são o núcleo da fase)
- **Suggested PR grouping** (1 PR por etapa do plano, doc 00 §6):
  - PR 1: Tasks 1–4 — Etapa A: fundação (tipos + Store + backends)
  - PR 2: Tasks 5–8 — Etapa B: domínio persistente + recovery
  - PR 3: Tasks 9–13 — Etapa C: Command Bus + Executor + resume (o coração; se ficar grande, dividir em 9-11 e 12-13)
  - PR 4: Tasks 14–16 — Etapa D: Context Builder + providers
  - PR 5: Tasks 17–19 — Etapa E: Policy + Middleware + Hooks
  - PR 6: Tasks 20–23 — Etapa F: Registries + plugins + TriggerWorkflow
  - PR 7: Tasks 24–26 — Etapa G: Service Platform + boot + smoke E2E

**Critério de conclusão da fase** (doc 00 §6): fluxo `SendMessage` com
`session_id` sobrevive a `kill -9` + reboot retomando do checkpoint; suíte
inteira verde sem chave de API (RubyLLM mockado só na integração do Executor).

**Regras herdadas do techspec:** testes fazem parte de cada task (não são
tasks separadas); núcleo testável sem RubyLLM instalado; toda task referencia
as seções do doc de componente correspondente (coluna Spec).
