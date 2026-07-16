# Task Plan: Harness Fase 6 — Motor de agentes (drop-in do gateway OpenClaw)

> **Tech Spec:** [00-overview.md](../00-overview.md)
> **Gerado:** 2026-07-15
> **Progress:** 8/10 tasks — Etapas A (ingresso `/v1/responses`), B (contexto de turno), C (memória + fronteira) e **D (provisionamento por pack)** ✅ (branch `feature/harness-p6-engine-etapa-d`; ver [etapa-d-provisioning.md](../etapa-d-provisioning.md)). **Task 9 (deploy Railway) DESCARTADA** por decisão de produto — este motor não vai pro Railway.
> **Base:** main pós-Fase-5. Primeiro consumidor: achei-b2b.
> **Meta do near-term:** piloto "shadow de 1 loja" (A → B → slice de D → E).

---

## Tasks

| # | Task | Etapa | Status | Complexity | Decisão |
|---|------|-------|--------|------------|---------|
| 1 | Endpoint `POST /v1/responses` (Bearer, `X-Openclaw-Agent`) — parse `{model:"openclaw:<agent>", user, stream, input}`; resolve agente (model/header) + sessão por `user`=chat.id (cria/continua); despacha `:send_message` com `input` verbatim como mensagem do turno | A | ✅ DONE | High | D1, F1, F2, F4 |
| 2 | Bridge EventStream do turno → **SSE OpenAI Responses**: `response.output_text.delta`, `output_item.added/done` (function_call), `response.completed` (usage+output), `response.failed`, `[DONE]`. Fidelidade ao parser do `OpenclawDispatcher` | A | ✅ DONE | High | D1, F1, NF5, R1 |
| 3 | Landing do contexto de turno: `chat_id`(=user)/`tenant`/`agent_id`/`store_id`(de profile) disponíveis no turno (TurnState/ContextRequest) | B | ✅ DONE | Med | D2, G4 |
| 4 | `DataDefinedTool` resolve `{{ctx.chat_id/store_id/agent_id/tenant}}` (namespace `ctx.`, separado dos `{{param}}` do modelo) em url/query/headers/body — costura p/ a tool de registry receber o contexto do turno. **Prova: tool emite `X-Chat-Id`/`X-Store-Id`/`X-Agent-Id`** | B | ✅ DONE | High | D2, F3, R2 |
| 5 | Memória dono-por-agente: default drop-in (`memoria`/`dados_conhecidos` embutidos no `input`, `profile.memory=false`) + caminho MemoryStore (`profile.memory=true`, tenant=chat, `remember` escreve). Documentar semântica; `dados_conhecidos` sempre do consumidor | C | ✅ DONE | Med | D3, F5 |
| 6 | Fronteira de confiança: identidade + skills de guardrail `pinned`/priority acima das injeções de turno; segurança (allow/deny/egress) só no motor/profile | C | ✅ DONE | Med | D5, NF3, R4 |
| 7 | Importador de pack: `docs/prompt-base/06` (`agent.config.json` + `*.md` + `skills/*` + defs de tools) → Commands (`create_agent`/`write_agent_file`/`write_skill`/`write_data_tool`; allowlists autoritativas subsumem `set_skill_agents` no caso single-agent). Genérico por projeto | D | ✅ DONE | High | D4, F6, NF1, NF2 |
| 8 | API de provisionamento (POST/DELETE `/v1/agents`) que o `GatewayClient`/`ProvisionStore` do achei-b2b chama em runtime, sob o Bearer do gateway | D | ✅ DONE | Med | D4, F7 |
| 9 | Deploy: Dockerfile + Railway/volume + envs (token, providers, DB); rodar single-proc alcançável pelo achei-b2b | E | ⛔ DESCARTADA | Med | D6, G7 |
| 10 | Observabilidade (tokens/custo/latência via EventStream; OTel opcional) + **piloto shadow de 1 loja**: tráfego real em paralelo ao gateway, comparar latência/custo/qualidade | E | ⬜ TODO | Med | D6, G7 |

### Status Legend
⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED

---

## Dependency Graph

```
Etapa A: 1 → 2                 (adapter de ingresso + SSE)
Etapa B: 3 → 4                 (contexto de turno → tools; depende de A)
Etapa C: 5, 6                  (memória + fronteira; depende de A)
Etapa D: 7 → 8                 (pack → provisionamento; depende de A)
Etapa E: 9 → 10                (deploy + piloto; depende de A,B e slice de D)
```

Caminho crítico do piloto: **A → B → (provisionar 1 loja, pode ser manual via Studio/
Commands) → E**. C entra cedo (default drop-in já funciona sem trabalho).

## Summary

- **Total:** 10 tasks / 5 etapas.
- **Complexidade:** Alta (é integração de produção). O par **A (SSE) + B (contexto de
  turno)** é o núcleo de risco e destrava o piloto.
- **PR grouping (sugerido):** PR1=Etapa A (1–2); PR2=Etapa B (3–4); PR3=Etapa C (5–6);
  PR4=Etapa D (7–8); PR5=Etapa E (9–10).
- **Fluxo:** 1 etapa = 1 PR; commit `Co-Authored-By: Claude Opus 4.8 (1M context)`;
  corpo do PR com `🤖 Generated with [Claude Code]`.

## O que NÃO entra (adiado, explícito)

- Multi-tenant de merchant em larga escala + N-procs/Caddy sticky + **Postgres** (§9.2
  das fases anteriores) — pós-piloto.
- Hooks do gateway que **não** são necessários (confirmado): render/dispatch de card
  WhatsApp (é side-effect da própria tool no achei-b2b), sentiment-routing de modelo,
  keyword skill-injection (legado morto).
- OTel→SigNoz completo (métricas próprias bastam pro piloto).
- Render "WhatsApp" no motor (§9.4 das fases anteriores — fica no achei-b2b).
