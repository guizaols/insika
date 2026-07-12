# Task Plan: Harness Fase 4 — Studio (UI de gestão, substituto do agent-studio)

> **Tech Spec:** [00-overview.md](../00-overview.md)
> **Gerado:** 2026-07-12
> **Progress:** 20/20 tasks — Etapas A (fundação) + B (CRUD de agente) + C (prompts/skills por-agente) + D (memória/settings/LLM) + E (app Roda + auth + assets + primeiras páginas) + F (páginas de autoria) + G (mcp/settings/system-files/chats) + H (polish & paridade) ✅ · **FASE 4 COMPLETA**
> **Base:** main @ merge PR #31 (`449668c`) · Etapas A (#26) + B (#27) + C (#29) + D (#30) + E (#31) mergeadas · F (PR aberto)
> **Retomada:** ver [HANDOFF.md](../HANDOFF.md)

---

## Tasks

| # | Task | File | Etapa | Status | Complexity | Decisão |
|---|------|------|-------|--------|------------|---------|
| 1 | `ConfigStore` — KV durável de configuração (scopes: agents/settings/llm_providers/mcp) sobre o backend | [task-01.md](./task-01.md) | A | ✅ DONE | Med | D2 |
| 2 | `ProfileSource` — interface `fetch(id)`/`all`; `StaticProfileSource` (Hash de hoje) + `StoredProfileSource` (ConfigStore↔AgentProfile) | [task-02.md](./task-02.md) | A | ✅ DONE | Med | D2 |
| 3 | Refactor Executor + Commands de turno p/ resolver profile via `ProfileSource` no dispatch (Hash→wrap automático; zero regressão) | [task-03.md](./task-03.md) | A | ✅ DONE | High | D2 |
| 4 | `:create_agent` / `:update_agent` / `:delete_agent` — Commands CQRS + validação + auditoria | [task-04.md](./task-04.md) | B | ✅ DONE | Med | D-API |
| 5 | `:set_agent_tools` — allow/deny por agente (hot via ProfileSource) | [task-05.md](./task-05.md) | B | ✅ DONE | Low | D4 |
| 6 | Escrita + `reload` em `SkillCatalog`/`PromptCatalog` (troca atômica do índice) | [task-06.md](./task-06.md) | C | ✅ DONE | Med | D3 |
| 7 | Workspace por agente (`AgentFileStore`, store-backed) + `:write_agent_file`/`:delete_agent_file` + snapshots de histórico | [task-07.md](./task-07.md) | C | ✅ DONE | Med | D3 |
| 8 | `:restore_agent_file` + `:write_skill` + `:set_skill_agents` + Prompt provider por-agente | [task-08.md](./task-08.md) | C | ✅ DONE | Med | D3 |
| 9 | Commands de memória (`:memory_put_fact`/`:memory_forget_fact`/`:memory_add_note`) + leituras | [task-09.md](./task-09.md) | D | ✅ DONE | Low | D5 |
| 10 | ConfigStore settings/llm_providers + `:update_settings` + masking sentinel `__OCULTO__` | [task-10.md](./task-10.md) | D | ✅ DONE | Med | D6 |
| 11 | `LLMConfigurator` — reconfigure runtime por provider + `:upsert/delete_llm_provider` | [task-11.md](./task-11.md) | D | ✅ DONE | Med | D6 |
| 12 | App `studio/` (Roda) + boot/mount sob `/studio` + auth por cookie (login) + CSRF | — | E | ✅ DONE | High | D1, D7 |
| 13 | Pipeline esbuild (Tailwind+Stimulus+CodeMirror) → `dist/` versionado + CSP `'self'` | — | E | ✅ DONE | Med | D8 |
| 14 | Shell/layout + Stimulus base + páginas login + agents(list) + playground (SSE) | — | E | ✅ DONE | Med | D9 |
| 15 | Página agents(detail): config/model + island `code-editor` (prompts) | — | F | ✅ DONE | High | D3, D9 |
| 16 | Páginas skills + tools (matriz + toggles) | — | F | ✅ DONE | Med | D4, D9 |
| 17 | agents(detail): skills/memória/histórico | — | F | ✅ DONE | Med | D3, D5 |
| 18 | Páginas mcp + settings (providers/models, masked-secret) — `McpStore`+`:upsert/delete_mcp` novos | — | G | ✅ DONE | High | D6, D9 |
| 19 | Página system-files (store global + injeção no Prompt provider) + chats (índice + viewer) | — | G | ✅ DONE | Med | D3, D9 |
| 20 | Polish & paridade: dirty-guards, banner de restart, health chip, empty states, tema, criação de agente | — | H | ✅ DONE | Med | D9 |

### Status Legend
⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

---

## Dependency Graph

```
Etapa A (funil): 1 → 2 → 3            (ConfigStore → ProfileSource → refactor Executor)
Etapa B: 4, 5           → dependem de A
Etapa C: 6 → 7 → 8      → dependem de A
Etapa D: 9; 10 → 11     → dependem de A
Etapa E: 12 → 13 → 14   → dependem de A–D
Etapa F: 15, 16 → 17    → dependem de E
Etapa G: 18, 19         → dependem de E, F
Etapa H: 20             → depende de F, G
```

A Etapa A (tasks 1-3) é **blocker de tudo** — funil de fundação, sem UI.

## Summary

- **Total:** 20 tasks / 8 etapas / 8 PRs.
- **Complexidade total:** Alta (é um produto).
- **PR grouping:**
  - **PR 1 (Etapa A):** tasks 1-3 — ConfigStore + ProfileSource + refactor (sem UI).
  - **PR 2 (Etapa B):** tasks 4-5 — Commands de agente.
  - **PR 3 (Etapa C):** tasks 6-8 — catálogos graváveis + workspace.
  - **PR 4 (Etapa D):** tasks 9-11 — memória + settings + LLM.
  - **PR 5 (Etapa E):** tasks 12-14 — app Roda + auth + assets + shell.
  - **PR 6 (Etapa F):** tasks 15-17 — páginas de autoria.
  - **PR 7 (Etapa G):** tasks 18-19 — mcp/settings/system-files/chats.
  - **PR 8 (Etapa H):** task 20 — polish & paridade.
