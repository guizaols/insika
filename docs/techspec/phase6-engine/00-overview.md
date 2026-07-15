# Techspec Fase 6 — Harness como motor de agentes (drop-in do gateway OpenClaw)

> **Autor:** Claude (AI-generated, pendente de revisão humana)
> **Criado:** 2026-07-15
> **Status:** Proposto. Base: main pós-Fase-5 (tools por dados completas).
> **Fonte da verdade do padrão de agente:** `achei-b2b/docs/prompt-base/` (00-OVERVIEW,
> 01-PROMPT-ANATOMY, **02-MARKERS-AND-INJECTIONS**, 03/04-ARCHETYPES,
> 05-GENERATION-CHECKLIST-AND-INVARIANTS, **06-PACK-FILES-AND-STRUCTURE**).
> **Contrato de ingresso (o que o consumidor já fala):**
> `achei-b2b/app/services/core_services/openclaw_dispatcher.rb`.

---

> **Decisão de escopo:** a Fase 6 transforma o harness de "runtime + Studio" num
> **motor genérico plugável**, cujo primeiro consumidor é o **achei-b2b** (no lugar
> do gateway OpenClaw). O motor **não conhece** achei-b2b: é dirigido por (a) um
> **pack padronizado** no provisionamento (`docs/prompt-base`) e (b) **input/markers
> padronizados por turno**. Alvo concreto e mensurável: **piloto "shadow de 1 loja"**
> — rodar tráfego real de uma loja pelo harness em paralelo ao gateway e comparar
> latência, custo/tokens e qualidade. Multi-tenant de larga escala, N-procs/Postgres
> e observabilidade completa ficam para depois do piloto.

## 1. Contexto & Objetivo

O harness hoje é uma biblioteca de runtime de agentes (Fases 0–3) + o **Studio** de
autoria (Fase 4) + **tools por dados** (Fase 5). O ecossistema-alvo:

```
WhatsApp (Meta) ─▶ achei-b2b (Rails, :3000) ── OpenclawDispatcher ─▶  MOTOR  ─┐
                    (system of record:                POST /v1/responses SSE   │
                     merchants/lojas/produtos,         model: openclaw:<agent> │
                     prompts/skills por loja,          user: <chat.id>         │
                     webhook WhatsApp, e os            input: <string c/ blocos>│
                     endpoints /api/internal/*)                                 │
                        ▲                                                       │
                        └──────── tools chamam de volta ◀──────────────────────┘
                          POST /api/internal/agent_tools/* (Bearer + X-Agent/Store/Chat-Id)
```

Hoje o **MOTOR** é o **gateway OpenClaw** (`:18790`, Railway). **A Fase 6 põe o harness
nesse lugar.** O harness NÃO substitui o Rails (sistema de registro), nem o ingresso
WhatsApp (que entra no Rails), nem o front — só o motor de turno.

**Achado que molda tudo (do `openclaw_dispatcher.rb`):** o consumidor manda o turno
como **uma string** (`input`) com os blocos (`<memoria>`, `<dados_conhecidos>`,
diretivas de comportamento) **já concatenados**, e correlaciona a conversa por
`user`=chat.id. As tools de volta são **HTTP autenticadas** que recebem o contexto
por **headers** `X-Agent-Id`/`X-Store-Id`/`X-Chat-Id` (validados server-side).

**Objetivo:** o harness expõe `/v1/responses` (SSE, shape OpenAI Responses),
resolve turno por agente/chat, injeta o contexto de turno nas **data-tools** (Fase 5)
para elas chamarem `/api/internal/agent_tools/*` corretamente, e é **provisionável a
partir de um pack padronizado** — genérico para qualquer projeto, achei-b2b sendo o
primeiro.

## 2. Requisitos

### Funcionais

- **F1 — Ingresso `/v1/responses`:** `POST` Bearer, body `{model:"openclaw:<agent>",
  user, stream:true, input:<string>}`; responde **SSE** com os eventos que o
  `OpenclawDispatcher` parseia: `response.output_text.delta`,
  `response.output_item.added/.done` (function_call), `response.completed` (usage +
  output), `response.failed`, `[DONE]`.
- **F2 — Sessão por chat:** `user` (chat.id) mapeia para uma sessão do harness —
  cria se nova, continua se existe (multi-turn). `sim-<chat_id>` (simulador) tolerado.
- **F3 — Contexto de turno nas tools:** as data-tools resolvem, no template,
  variáveis de **contexto de turno** — `{{ctx.chat_id}}`, `{{ctx.store_id}}`,
  `{{ctx.agent_id}}`, `{{ctx.tenant}}` — vindas do turno (NÃO dos args do modelo) para
  emitir `X-Chat-Id`/`X-Store-Id`/`X-Agent-Id`. Auth estática do endpoint interno via
  `secret_headers` (Fase 5 ✅).
- **F4 — Input pré-composto:** o `input` (string com blocos) entra como a mensagem do
  turno, verbatim, sem o motor precisar entender cada marker (contrato drop-in).
- **F5 — Memória com dono-por-agente:** o motor suporta as duas pontas — (a) `memoria`
  embutida no input pelo consumidor (default drop-in) OU (b) `MemoryStore` do harness
  (por `tenant`=chat) com o `remember` escrevendo. Toggle por agente
  (`profile.memory`). `<dados_conhecidos>` é sempre do consumidor.
- **F6 — Provisionamento por pack:** importar um agente a partir de um **pack**
  conforme `docs/prompt-base/06-PACK-FILES-AND-STRUCTURE` (`agent.config.json` +
  `IDENTITY/SOUL/TOOLS/SKILLS/...md` + `skills/*` + defs de tools) via os Commands já
  existentes (`create_agent`/`write_agent_file`/`write_skill`/`set_skill_agents`/
  `write_data_tool`). Genérico por projeto.
- **F7 — API de provisionamento:** endpoints que o `GatewayClient`/`ProvisionStore`
  do achei-b2b chama para criar/atualizar/deletar um agente de loja em runtime.

### Não-Funcionais

- **NF1 — Genérico, não achei-específico:** nada no core (`lib/harness`) cita
  achei-b2b. O motor é dirigido por pack + input padronizado. (O `deployment.rb`/
  composition root pode ter um consumidor concreto.)
- **NF2 — Paridade de comportamento (piloto justo):** o mesmo pack rodando no harness
  produz comportamento equivalente ao gateway — nomes de tool 1:1, formato do catálogo
  (`<available_tools>`/`<available_skills>`) e ordem dos markers conforme o padrão. A
  comparação head-to-head mede o **motor**, não drift de prompt.
- **NF3 — Fronteira de confiança:** blocos injetados por turno (input) e
  `dados_conhecidos` são **dados**, nunca autoridade — identidade + guardrails ficam
  **pinned acima** e decisões de segurança (allow/deny de tool, egress) continuam do
  lado do motor/profile. Um prompt-injection que suba por `dados_conhecidos` não
  sobrepõe o SOUL/guardrails.
- **NF4 — Segurança de saída:** o egress guard das data-tools (Fase 5) continua; o
  destino interno (`/api/internal/*`) entra via allowlist de host.
- **NF5 — Streaming fiel:** o SSE precisa emitir exatamente os eventos que o
  `OpenclawDispatcher` espera (deltas de texto contínuos; function_call em
  output_item; usage no completed). Sem isso a UI/entrega quebra.
- **NF6 — Sem regressão:** o `/v1/messages`+`/v1/events` atuais e todo o core seguem
  intactos; `/v1/responses` é um adapter novo na borda.

## 3. Estado atual — o que reusa vs. o que falta

### Já existe e é reusável

| Peça | Onde | Uso |
|------|------|-----|
| Runtime de turno, tool-loop, resume durável | Executor (Fases 0–3) | O turno em si |
| SSE + EventStream | `server/app.rb` `/v1/events` | Base do stream de `/v1/responses` |
| Sessão multi-turn | SessionStore | `user`=chat.id → sessão |
| Data-tools HTTP + `secret_headers` + egress guard | Fase 5 | As ~25 tools `/api/internal/agent_tools/*` |
| Workspace de agente (IDENTITY/SOUL/TOOLS + skills + allowlist + system-files) | Fase 4 | **Já espelha o padrão `docs/prompt-base`** |
| Commands de autoria (create_agent/write_agent_file/write_skill/set_skill_agents/write_data_tool) | Fases 4–5 | Alvos do importador de pack |
| `MemoryStore` + Memory provider + tool `remember` (por `tenant`) | Fase 4 | Memória dono-motor |
| Context = fragmentos por turno (placement/priority/pinned) | ContextBuilder/providers | Injeção por-turno + precedência |
| ProfileSource dinâmico | StoredProfileSource | Agentes de loja em runtime |

### GAPS — o que a Fase 6 precisa e não existe

- **G1 — Endpoint `/v1/responses` (SSE OpenAI Responses)** na borda — hoje só há
  `/v1/messages`+`/v1/events` (contrato próprio).
- **G2 — Bridge EventStream → eventos OpenAI Responses** (delta/output_item/completed).
- **G3 — Contexto de turno acessível pelas data-tools** — hoje o `DataDefinedTool` só
  interpola args do modelo; uma tool de registry NÃO recebe TurnState
  (`ToolEnvelope#call(args)` só passa args, ≠ tool de sistema `remember`). Precisa de
  `{{ctx.*}}` resolvido do turno.
- **G4 — Landing do contexto no turno** — `user`(chat.id)→`tenant`/sessão,
  `agent`→profile, `store_id`→config do profile; disponíveis para G3.
- **G5 — Importador de pack** (`docs/prompt-base` → Commands) + **API de
  provisionamento** (o `GatewayClient` do achei-b2b).
- **G6 — Precedência/pinning** de fragmentos (identidade/guardrails > injeções de
  turno) — o `priority` existe, falta a política + `pinned` nos fragmentos certos.
- **G7 — Deploy** (Dockerfile + Railway/volume + envs) e **observabilidade**
  (tokens/custo/latência; OTel opcional).

## 4. Decisões de arquitetura

### D1 — `/v1/responses` é um ADAPTER de borda, core intacto
Novo handler no `server/` (ou um sub-app), traduzindo o request OpenAI-Responses →
`:send_message` (mesmo bus) e o `EventStream` do turno → SSE OpenAI-Responses. O
`input` (string) entra como a mensagem do turno **verbatim** (os blocos já vêm
compostos — o motor não os interpreta; F4). `model:"openclaw:<agent>"` e/ou
`X-Openclaw-Agent` resolvem o agente; `user` resolve/cria a sessão. Zero mudança no
Executor.

### D2 — Contexto de turno → data-tools via `{{ctx.*}}` (o gap fundante)
Landing: o adapter põe no turno um **contexto** com `chat_id`(=user), `agent_id`,
`tenant`(=chat_id) e `store_id` (de `profile` config/var). O `DataDefinedTool` ganha
acesso a esse contexto e resolve `{{ctx.chat_id}}`/`{{ctx.store_id}}`/`{{ctx.agent_id}}`
em url/query/headers/body — **separado** dos `{{param}}` do modelo (namespace `ctx.`).
Como uma tool de registry não recebe TurnState hoje, a costura é: o overlay/factory ou
o envelope injeta o contexto do turno corrente na instância da data-tool (mesma ideia
da tool de sistema `remember`, que já recebe `tenant`/`state`). Assim a tool emite
`X-Chat-Id`/`X-Store-Id`/`X-Agent-Id` e o `/api/internal/agent_tools/*` valida.

> **Segredo vs contexto:** auth (`BIA_INTERNAL_API_TOKEN`) = `secret_header` estático
> (Fase 5 ✅). `X-*-Id` = contexto de turno (D2). São coisas diferentes.

### D3 — Memória: dono-por-agente; `dados_conhecidos` sempre do consumidor
Duas pontas coexistem porque contexto é soma de fragmentos:
- **Consumidor dono** (drop-in default): `memoria`/`dados_conhecidos` chegam **dentro
  do `input`** — o motor não faz nada, os blocos ridem no turno. `profile.memory=false`.
- **Motor dono** (evolução): `MemoryStore` por `tenant`=chat; Memory provider injeta
  `<memory>`; `remember` escreve. `profile.memory=true`; o consumidor para de mandar
  `memoria`.
- **Ambos:** possível (fragmentos compõem), com precedência definida (D5).

`<dados_conhecidos>` (catálogo/cliente/carrinho) é **sempre** do consumidor (sistema
de registro) — o motor nunca "possui" isso.

### D4 — Provisionamento: o motor consome o PACK padrão (genérico)
O harness já espelha o workspace do padrão (Fase 4). Um **importador** lê um pack
conforme `docs/prompt-base/06` e emite os Commands (`create_agent` +
`write_agent_file` por arquivo .md + `write_skill` + `set_skill_agents` + `write_data_tool`
por tool). Exposto como **API de provisionamento** que o `GatewayClient` do achei-b2b
chama. Nomes de tool são **declarados pelo pack** → prompts↔tools consistentes por
construção (NF2). Nada achei-específico (NF1).

### D5 — Fronteira de confiança por precedência/pinning
Identidade (IDENTITY/SOUL) e skills de guardrail entram **pinned** e com `priority`
acima das injeções de turno (input/markers/dados_conhecidos). Sob orçamento de token,
injeções de turno são sacrificadas antes da identidade. Decisões de segurança
(allow/deny de tool, egress, approvals) são do motor/profile — nunca do bloco
injetado (NF3).

### D6 — Piloto antes de escala
V1 = 1 loja, single-proc, SQLite-em-volume (serve). N-procs/Postgres/multi-tenant de
merchant (§9.2 da Fase 4/5) e OTel completo ficam **pós-piloto**. O objetivo do piloto
é validar motor (latência/custo/qualidade), não operar a frota.

## 5. Contratos

### `/v1/responses` (ingresso) — request
```
POST /v1/responses
Authorization: Bearer <GATEWAY_TOKEN>
X-Openclaw-Agent: <agent_id>
Content-Type: application/json          Accept: text/event-stream
{ "model": "openclaw:<agent_id>", "user": "<chat.id>", "stream": true,
  "input": "<string com blocos já compostos + user text + linhas de mídia>" }
```

### `/v1/responses` — response (SSE, eventos consumidos pelo dispatcher)
- `response.output_text.delta`  → `{ "delta": "<token>" }`
- `response.output_item.added` / `response.output_item.done` → `{ "item": { "type":"function_call", "name":"<tool>" } }`
- `response.completed` → `{ "response": { "usage": {...}, "output": [...] } }`
- `response.failed` → `{ "response": { "error": { "message": ... } } }`
- terminador `data: [DONE]`

### Contexto de turno disponível às data-tools (`{{ctx.*}}`)
`ctx.chat_id` (=user), `ctx.agent_id`, `ctx.tenant` (=chat_id), `ctx.store_id`
(de `profile`). Ex.: header `X-Chat-Id: {{ctx.chat_id}}`, `X-Store-Id: {{ctx.store_id}}`,
`X-Agent-Id: {{ctx.agent_id}}`; `Authorization` = secret header estático.

### Pack (provisionamento) — `docs/prompt-base/06-PACK-FILES-AND-STRUCTURE`
`agent.config.json` (model/limits/skills allowlist) + `IDENTITY.md`/`SOUL.md`/`TOOLS.md`/
`SKILLS.md`/… + `skills/<nome>/SKILL.md` + defs de data-tools → Commands do harness.

## 6. Plano de implementação (etapas → PRs)

| Etapa | Tasks | Entrega | 
|-------|-------|---------|
| **A — Ingresso `/v1/responses`** | 1–2 | Endpoint + parse do request (model/user/input) → `:send_message`; bridge EventStream → SSE OpenAI-Responses; sessão por chat.id. **Sem tocar o core.** |
| **B — Contexto de turno nas tools (fundante)** | 3–4 | Landing do contexto (chat/agent/store/tenant) no turno; `{{ctx.*}}` nas data-tools → `X-*-Id`. Prova: tool emite os 3 headers. |
| **C — Memória dono-por-agente + fronteira** | 5–6 | Toggle de dono (input-embedded vs MemoryStore); precedência/pinning (identidade/guardrails > injeções). |
| **D — Provisionamento por pack** | 7–8 | Importador `docs/prompt-base` → Commands; API de provisionamento (GatewayClient). |
| **E — Deploy + observabilidade + piloto** | 9–10 | Dockerfile+Railway/volume; métricas tokens/custo/latência; piloto shadow de 1 loja + comparação. |

**Dependências:** A → B (B usa a costura de contexto de A). C e D dependem de A.
E fecha. Ordem crítica p/ o piloto: **A → B → (slice de D: provisionar 1 loja, pode ser
manual) → E**. C pode ir junto de A (memória default = input-embedded já funciona).

## 7. Riscos & edge cases

- **R1 — Fidelidade do SSE.** Se os eventos/deltas não casarem com o parser do
  `OpenclawDispatcher` (que faz heurística de gap/boundary), a entrega em balões
  quebra. Mitigação: espelhar exatamente os tipos de evento; testar com o parser real.
- **R2 — Contexto ausente → 403 em cascata.** Sem `X-*-Id` corretos toda tool falha.
  Mitigação: B é blocker; teste que valida os 3 headers na chamada.
- **R3 — Drift de prompt (comparação injusta).** Nomes de tool/formato divergentes do
  padrão. Mitigação: NF2 — nomes 1:1 e formato de catálogo conforme `docs/prompt-base`.
- **R4 — Prompt injection via `dados_conhecidos`.** Mitigação: D5 (pinning/precedência
  + segurança no motor).
- **R5 — Bloqueio do reactor.** Data-tools HTTP síncronas (Net::HTTP) sob carga. Já
  mitigado por timeouts (Fase 5); avaliar async-http no piloto se latência exigir.
- **R6 — SQLite single-proc.** Não escala p/ N procs. Aceito no piloto (1 proc);
  Postgres é pós-piloto.

## 8. Open questions

1. **Dono da memória no piloto:** começar drop-in (input-embedded) e migrar `memoria`
   pro MemoryStore depois? (Recomendado: drop-in primeiro, medir, depois avaliar.)
2. **`store_id` no profile:** vem do `agent.config.json` do pack (metadata do agente)
   ou de um var por-turno? (Recomendado: metadata do agente — é estável por loja.)
3. **Provisionamento:** o achei-b2b adapta o `GatewayClient` p/ os Commands do harness,
   ou o harness expõe uma fachada compatível com o GatewayClient atual? (Menor esforço:
   fachada fina no harness.)
4. **Sessão nativa vs Rails:** o gateway guarda session JSONL; o dispatcher removeu
   `<historico>` confiando nisso. Confirmar que a sessão do harness (SessionStore)
   preserva o transcript equivalentemente por `user`=chat.id.
5. **Observabilidade:** OTel→SigNoz (paridade) ou métricas próprias no EventStream por
   ora? (Piloto: métricas próprias bastam p/ comparar; OTel depois.)
6. **Modelo por turno:** sentiment-routing (claude em sentimento negativo) fica de fora
   do piloto (deepseek default). Reavaliar se a qualidade exigir.

## 9. Dependências & blockers

- **Consumidor:** achei-b2b (`OpenclawDispatcher`, `GatewayClient`, endpoints
  `/api/internal/*`) — já existem e são estáveis; a Fase 6 se pluga neles.
- **Reusa:** todo o core + Fase 4 (workspace/Studio) + Fase 5 (data-tools).
- **Blocker interno:** A é blocker de B; B é blocker do piloto (sem contexto, tools
  dão 403).
- **Não bloqueado por** multi-tenant de merchant nem N-procs (pós-piloto).

---

> ⚠️ **Spec AI-generated, requer revisão humana.** Atenção especial a §4 D2 (contexto
> de turno nas data-tools — a costura mais invasiva), §5 (fidelidade do SSE, R1) e §4
> D5 (fronteira de confiança das injeções por-turno).
