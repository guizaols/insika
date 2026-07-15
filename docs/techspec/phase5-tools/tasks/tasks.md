# Task Plan: Harness Fase 5 — Tools sem código + fechamento de dívidas de wiring

> **Tech Spec:** [00-overview.md](../00-overview.md)
> **Gerado:** 2026-07-12
> **Progress:** 9/9 tasks — A (core) ✅ + B (registro dinâmico) ✅ [PR #36] + C (UI Studio) ✅ [PR #37] + D (dívidas §9.5/§9.6) ✅. **FASE 5 COMPLETA.**
> **Base:** main @ `7cb5ab3` (pós-Fase-4 + pós-DHH-review).

---

## Tasks

| # | Task | Etapa | Status | Complexity | Decisão |
|---|------|-------|--------|------------|---------|
| 1 | `ToolDefinition` (Data.define) + validação (nome único/formato, tipos de param, method/url https, placeholders ⊆ params) | A | ✅ DONE | Med | D1, §5 |
| 2 | `ToolStore` — scope `"tools"` novo no `ConfigStore::SCOPES`; versionado (molde `SkillStore`); headers secretos mascarados via `SecretMasking` (get/get_raw) | A | ✅ DONE | Med | D4, F4, F7 |
| 3 | `Harness::Tools::DataDefinedTool < RubyLLM::Tool` — override `name`/`description`/`parameters`/`params_schema`/`execute`; templating `{{param}}` c/ escaping; `HttpClient` injetável; **guarda de egress (SSRF)**; extração `body_raw`/`status`/`json_path`; erros → `{error:}` | A | ✅ DONE | High | D1, D3, NF2, R1 |
| 4 | `OverlayToolRegistry` — compõe base (código) + dinâmico (store→factories de DataDefinedTool); `reload` atômico; **base vence colisão**; plugado em `ToolCatalog` + `executor` (policy stage). **Spec de paridade: store vazio ⇒ idêntico** | B | ✅ DONE | High | D2, NF1, R3, R4 |
| 5 | Commands `:write_data_tool` / `:delete_data_tool` / `:restore_data_tool` (+ `overlay.reload` + `tool_catalog.reload`) + validação + auditoria mascarada; registrar no `BUS` (só `deployment.rb` — `wiring.rb` base não tem ConfigStore) | B | ✅ DONE | Med | §6 |
| 6 | Studio: página de autoria `/tools/def/*` — builder de parâmetros + config HTTP (method/url/headers/query/body) + editor island p/ body + segredo mascarado + versões/restore; nav + configure(store) | C | ✅ DONE | High | G5, §6, NF4 |
| 7 | Studio: matriz `/tools` passa a listar data-tools junto das de código; exposição por agente via `:set_agent_tools` (inalterado); **prova ponta-a-ponta HTTP+LLM** (criar data-tool → allow p/ agente → modelo chama → responde) | C | ✅ DONE | Med | F6, NF1 |
| 8 | §9.6 — wire A2A/AgentCard via `PROFILE_SOURCE`: `config/deployment.rb` monta `A2A::App` + expõe em `Server::App` gateado por `PROFILE_SOURCE.fetch`; `config/wiring.rb` troca `PROFILES` estático | D | ✅ DONE | Med | D6, F8 |
| 9 | §9.5 — `DeleteLLMProvider` recebe `configurator:` e chama `LLMConfigurator#unapply(api)` (zera accessors no RubyLLM global); degrada p/ banner de restart se não suportado; **confirmar RubyLLM 1.16 antes** | D | ✅ DONE | Low | D7, F9, §9.5 |

### Status Legend
⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

---

## Dependency Graph

```
Etapa A (funil): 1 → 2 → 3        (definição → store → tool HTTP)
Etapa B: 4 → 5                    (overlay → commands; dependem de A)
Etapa C: 6 → 7                    (UI; dependem de B)
Etapa D: 8, 9                     (dívida; INDEPENDENTE de A/B/C)
```

Etapa A é blocker de B e C. Etapa D pode ir em paralelo (ou primeiro).

## Summary

- **Total:** 9 tasks / 4 etapas / 4 PRs.
- **Complexidade total:** Média-Alta (a parte nova de risco é SSRF na task 3 e o
  overlay no caminho quente na task 4).
- **PR grouping:**
  - **PR 1 (Etapa A):** tasks 1-3 — core: definição + store + tool HTTP (sem UI).
  - **PR 2 (Etapa B):** tasks 4-5 — registro dinâmico + commands.
  - **PR 3 (Etapa C):** tasks 6-7 — Studio UI + prova ponta-a-ponta.
  - **PR 4 (Etapa D):** tasks 8-9 — dívidas §9.6 + §9.5.
- **Fluxo:** 1 etapa = 1 PR; commit `Co-Authored-By: Claude Opus 4.8 (1M context)`;
  corpo do PR com `🤖 Generated with [Claude Code]`.
