# Task Plan: Harness Fase 7 — Tool host genérico (JSON Schema + binding declarativo + ingestão dinâmica)

> **Tech Spec:** [00-overview.md](../00-overview.md)
> **Gerado:** 2026-07-16
> **Progress:** 8/8 tasks — **Etapa A (JSON Schema) ✅** (tasks 1–2); **Etapa B (manifesto + ingestão dinâmica) ✅** (tasks 3–5); **Etapa C (grupos + allowlist por grupo) ✅** (task 6); **Etapa D (conversor one-off) ✅** (task 7, PR #53); **Etapa E (MCP live + corte por flag) ✅** (task 8, PR #54 — com deferrals documentados).
> **Base:** main pós-Fase-6 (data-tools da Fase 5 + provisionamento por pack + `{{ctx.*}}` + SSE + egress opt-in).
> **Meta:** o harness vira um **tool host agnóstico** que ingere tools em **JSON Schema** (formato
> padrão) + binding declarativo, **dinamicamente** (hot, sem rebuild/deploy), com enablement por
> agente/grupo. O motor **não conhece** achei/openclaw (NF1) — o **manifesto** é o contrato.

---

## Tasks

| # | Task | Etapa | Status | Complexity | Decisão |
|---|------|-------|--------|------------|---------|
| 1 | **`ToolDefinition` v2 — params em JSON Schema.** `parameters` aceita/armazena JSON Schema (objeto, com aninhamento `object`/`array`/`enum`/`required`). **Lift automático** do array plano legado (`[{name,type,required}]` → `{type:object, properties, required}`) — zero regressão. Validação de `{{placeholders}}` e `required` sobre o schema; validação de **subset seguro** por provider na ingestão (R1). | A | ✅ DONE | High | D1, F1, R1, R2 |
| 2 | **`DataDefinedTool` alimenta `params_schema` do RubyLLM.** JSON Schema → `params_schema` nativo (ruby_llm 1.16) → funciona em qualquer provider. **Prova: param aninhado (`search_products`) exposto ao modelo E interpolado no body.** Testes de paridade (tool `cep`/viacep da Fase 5 idêntica). | A | ✅ DONE | High | D1, F6, NF5, R2 |
| 3 | **Manifesto + adapters de entrada.** Schema do manifesto (`defaults` + `tools[]`); adapters normalizam qualquer envelope padrão → forma interna: `parameters` (cru), `{type:"function",function:{…}}` (OpenAI/Anthropic), `{name,description,inputSchema}` (MCP). `endpoint` resolve remaps nome↔slug **por dado** (nunca inferido do name — R6). | B | ✅ DONE | High | D2, D3, F2, F3, R6 |
| 4 | **Templates `{{secret.*}}` + `{{env.*}}`.** `url`/`headers`/`body`/`query` resolvem `{{param}}` + `{{ctx.*}}` + `{{secret.*}}` (injetado na **ingestão** do `SettingsStore`/env, gravado como `secret_header` mascarado) + `{{env.*}}` (config do deployment). **Recusar `secret_header` com valor literal que não seja `{{secret.*}}`** (R3). | B | ✅ DONE | Med | D6, F4, NF4, R3 |
| 5 | **Command `:import_tools` + endpoint.** Upsert em lote das data-tools com **reload hot** (sem restart); relatório por-tool (`{created, updated, errors}` — molde pack importer da Fase 6); upsert idempotente / falha parcial isolada (R4). Endpoint `POST /v1/tools/manifest`. Egress da `base_url` dinâmica via `host_allowlist` (R5). | B | ✅ DONE | High | D3, F2, R4, R5 |
| 6 | **Grupos/tags + allowlist por grupo.** `group`/`tags` no `ToolDefinition` (**dado**, não convenção-de-nome); `tools_allow_groups` no `AgentProfile`; expansão na montagem do toolset (union com `tools_allow`; `tools_deny` vence; allowlists vazias = todas). | C | ✅ DONE | Med | D4, F5 |
| 7 | **Conversor de migração (one-off, FORA do core).** `scripts/` lê `acheib2b-tools-dev/tools/*.ts` (TypeBox `Type.Object` já **é** JSON Schema) + slug do `callAgentTool` → envolve em binding → emite `manifesto.json` das 44 (params/endpoints corretos). Descartável, específico do cliente. | D | ✅ DONE | Med | D7, G6 |
| 8 | **(follow-up) MCP live + corte de schema por flag.** Ingestão de um MCP server do consumidor (descoberta automática, sem manifesto); corte de schema por allowlist derivada de flag no provisionamento. | E | ✅ DONE | — | D5, D8 |

### Status Legend
⬜ TODO · 🟡 IN PROGRESS · ✅ DONE · ⛔ BLOCKED · ⬜ ADIADO

---

## Dependency Graph

```
Etapa A: 1 → 2                 (JSON Schema no ToolDefinition → alimenta o provider)
Etapa B: 3 → 4 → 5             (manifesto + adapters → secrets/env → ingestão em lote; usa o schema de A)
Etapa C: 6                     (grupos/allowlist; independe de B, pode ir junto)
Etapa D: 7                     (conversor; depende de A/B — emite o formato deles)
Etapa E: 8                     (follow-up; não bloqueia nada)
```

Caminho crítico: **A → B**. C é paralelo. D depende de A+B. E é adiado.

## Summary

- **Total:** 8 tasks / 5 etapas — **TODAS concluídas** (a Etapa E, antes adiada, entrou como
  incremento bounded com deferrals documentados; ver "O que ficou DEFERIDO na Etapa E").
- **Complexidade:** o par **A (JSON Schema, mudança mais invasiva na Fase 5 — §4 D1) + B (adapters de
  envelope + ingestão hot)** é o núcleo de risco.
- **PR grouping (sugerido):** PR1=Etapa A (1–2); PR2=Etapa B (3–5); PR3=Etapa C (6); PR4=Etapa D (7).
- **Fluxo:** 1 etapa = 1 PR; commit `Co-Authored-By: Claude Opus 4.8 (1M context)`; corpo do PR com
  `🤖 Generated with [Claude Code]`.

## Riscos-chave (do §7 da spec)

- **R1** — JSON Schema ↔ provider: validar subset seguro na ingestão (task 1).
- **R2** — Compat array plano: lift automático + testes de paridade (tasks 1–2).
- **R3** — Secret vazando no manifesto: recusar literal, obrigar `{{secret.*}}` (task 4).
- **R4** — Falha parcial no lote: upsert idempotente + relatório por-tool (task 5).
- **R5** — Egress p/ base_url dinâmica: egress guard + `host_allowlist` (task 5).
- **R6** — Nome↔slug divergente: `endpoint` explícito no manifesto (task 3).

## Open questions pendentes (§8 da spec — resolver antes/durante a implementação)

1. **Ingestão:** Command novo `:import_tools` + `POST /v1/tools/manifest` **vs.** estender `import_pack`
   (pack referencia manifesto compartilhado + allowlist). Piloto: manifesto **global compartilhado**,
   packs de loja só referenciam via allowlist/grupo.
2. **`{{secret.*}}` de onde:** ✅ **RESOLVIDO (Etapa B):** resolvedor **injetável** no composition root
   (`ImportTools.new(secrets:, env:)`). Piloto usa **`ENV` do deployment** (não `SettingsStore`): mantém o
   segredo FORA de qualquer store durável — só resolvido na ingestão e gravado mascarado como `secret_header`
   no `ToolStore`. A chave do placeholder é o nome da env var (ex.: `{{secret.BIA_INTERNAL_API_TOKEN}}`).
   Trocar por um resolvedor `SettingsStore`/vault é só injetar outro objeto que responda a `[]`.
3. **Corte de schema por flag:** ✅ **RESOLVIDO (Etapa E):** piloto **estático** — `enabled_groups`/
   `flags` do pack config viram `tools_allow_groups` no `PackImporter` (corta as tools de grupos
   desabilitados antes do turno). Genérico (NF1): a chave da flag É o nome do grupo; o mapeamento é
   dado do pack. Corte **dinâmico** (hook no assembly) segue como possível evolução.

## O que ficou DEFERIDO na Etapa E (documentado no código e no PR #54)

- **Transporte MCP real (D8):** o `McpHttpClient` faz só um POST JSON-RPC stateless; sem ciclo de
  sessão MCP (initialize/negociação/session-id/notifications), sem **stdio** (instância sem `url` →
  erro claro), sem unwrap da resposta `tools/call`. O **seam injetável** (`McpToolIngestor` recebe o
  cliente) deixa a troca pronta.
- **Injeção de credencial** (`env` da instância MCP) como header de auth no binding HTTP das tools
  ingeridas.
- **Corte dinâmico** de schema por flag (hook no assembly) — piloto usa allowlist estática.

## O que NÃO entra (fora do produto)

- O **conversor (task 7 / Etapa D)** é migração one-off, **fora do produto** (`lib/harness` nunca cita
  achei/openclaw — NF1); vive em `scripts/internal/openclaw_to_manifest.rb`.
