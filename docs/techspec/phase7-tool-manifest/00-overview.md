# Techspec Fase 7 — Tool host genérico (JSON Schema + binding declarativo + ingestão dinâmica)

> **Autor:** Claude (AI-generated, pendente de revisão humana)
> **Criado:** 2026-07-16
> **Status:** Proposto. Base: main pós-Fase-6 (data-tools da Fase 5 + provisionamento por
> pack + contexto de turno `{{ctx.*}}` + SSE streaming + egress opt-in).
> **Fonte da verdade descoberta (OpenClaw, só-leitura):** `openclaw/openclaw.json`
> (`agents.list[].tools.{allow,deny}`); plugin `openclaw/extensions/acheib2b-tools-dev`
> (`index.ts`, `tools/*.ts`, `lib/api-client.ts`); resolução em `node_modules/openclaw/dist/
> tool-resolution-*.js` + `tool-policy-*.js`. Gating dinâmico no Rails achei-b2b
> (`config/routes.rb` `agent_tools`, `b2b_enabled?`/`groceries_v2_enabled?`/`require_natura!`).

---

> **Decisão de escopo:** transformar as **data-tools (Fase 5)** num **tool HOST genérico**
> dirigido por **dados em formato PADRÃO de mercado** (JSON Schema — a interlíngua de
> OpenAI/Anthropic/MCP/LangChain/TypeBox/ruby_llm-schema), **ingerível dinamicamente** (hot,
> sem rebuild/deploy), com **enablement por agente** (allowlist por tool e por grupo). O motor
> **não conhece** achei/openclaw (NF1): o **manifesto** é o contrato. O conversor
> `plugin OpenClaw → manifesto` é **utilitário de migração one-off**, fora do produto.

## 1. Contexto & Objetivo

**Como o OpenClaw faz hoje (descoberto):** as tools são **código TypeScript** — 1 `.ts` por tool,
**44 `api.registerTool(...)` imperativos** no `index.ts` (sem manifest declarativo, sem
auto-discovery). Os **grupos** (Globais/Default/Groceries/B2B/Natura/Cacau/Core) **não são
persistidos** — são derivados por convenção de nome/sufixo em runtime. O **enablement por agente**
vive no `openclaw.json` (`agents.list[].tools.{allow,deny}`: deny vence, allow vazio = herda tudo,
allow não-vazio = whitelist). O **gating por vertical/loja** (feature flags) vive **no Rails**
(o gateway expõe tudo; o controller responde "disabled"/403 quando a tool é chamada).
Consequências ruins: (a) **adicionar/editar tool = rebuild + deploy do plugin**; (b) os
`agent-store-*` **não têm `tools.allow`** → **sem isolamento real por loja** no gateway (depende do
prompt — risco documentado por eles); (c) o modelo **gasta uma tool-call** pra descobrir que uma
feature está off (a flag só existe no Rails).

**O harness já tem a peça certa** — as **data-tools da Fase 5**: tool como **DADO** (descritor HTTP
declarativo no `ToolStore`, hot-reload via overlay, egress-guard, `secret_headers`, allowlist por
agente). O que falta: (a) os **parâmetros são um array PLANO bespoke** (`{name,type,required}`) — não
expressa aninhamento (o `search_products`/`save_shopping_list`/`recommend_products` do achei têm
params aninhados) **nem é formato padrão**; (b) não há **ingestão em lote/manifesto**; (c) não há
**grupos/tags** nem allowlist por grupo.

**Objetivo:** o harness vira um **tool host agnóstico** que **ingere** definições de tool em
**formato padrão** (JSON Schema) + um **binding declarativo** (como chamar), **dinamicamente**, com
**enablement por agente/grupo** — mais genérico, mais dinâmico e mais seguro que o plugin TS do
OpenClaw.

## 2. Requisitos

### Funcionais
- **F1 — Params em JSON Schema:** `ToolDefinition.parameters` aceita/armazena **JSON Schema**
  (objeto), com aninhamento (`object`/`array`/`enum`/`required`/…). O array plano legado é **açúcar**
  que "sobe" para JSON Schema (compat).
- **F2 — Ingestão por manifesto (dinâmica):** um Command/endpoint recebe um **manifesto** (`defaults`
  + lista de tools) e faz **upsert em lote** das data-tools (hot-reload, sem restart). Aceita os
  **envelopes padrão** (OpenAI *function tool*, MCP *tool*, ou cru) normalizando para a forma interna.
- **F3 — Binding declarativo:** cada tool = **interface** (`name`/`description`/JSON-Schema) +
  **binding** (`method`/`url`/`headers`/`body` templates, `secret_headers`, `side_effect`,
  `response`), com **defaults herdados** do manifesto (`base_url`/`path_template`/headers comuns).
- **F4 — Templates de contexto:** `url`/`headers`/`body`/`query` resolvem `{{param}}` (args do
  modelo) e `{{ctx.*}}` (contexto de turno — Etapa B) + `{{secret.*}}` (injetado na ingestão, fora do
  manifesto) e `{{env.*}}` (config do deployment).
- **F5 — Grupos/tags:** tool pode declarar `group`/`tags`; o profile ganha **allowlist por grupo**
  (`tools_allow_groups`) que expande para as tools do grupo (união com `tools_allow`; `tools_deny`
  vence).
- **F6 — Provider-agnóstico:** o JSON Schema vai para o `params_schema` do RubyLLM (nativo no 1.16) →
  funciona em qualquer provider (OpenAI/Anthropic/Gemini/DeepSeek/Bedrock).
- **F7 — Autoria in-code opcional:** além da ingestão por dados, autoria via `ruby_llm-schema`
  (DSL Ruby que **emite JSON Schema**).

### Não-Funcionais
- **NF1 — Genérico:** nada no core (`lib/harness`) cita achei/openclaw. O manifesto é o contrato.
- **NF2 — Padrão de mercado:** JSON Schema como interlíngua; interoperável com MCP/OpenAI/Anthropic.
- **NF3 — Dinâmico:** ingestão **hot** (sem restart/rebuild/deploy); manifesto **versionável**
  (arquivo → PR/diff/rollback).
- **NF4 — Segurança:** egress guard + `secret_headers` por tool + allowlist por Policy; **secret nunca
  no manifesto** (`{{secret.*}}` injetado). Isolamento por agente **real** no motor (≠ gateway, que
  herda tudo).
- **NF5 — Sem regressão:** as data-tools atuais (array plano) seguem valendo por lift automático.

## 3. Estado atual — o que reusa vs. o que falta

### Já existe e é reusável
| Peça | Onde | Uso |
|------|------|-----|
| `ToolDefinition` + `DataDefinedTool` (tool por dados) | Fase 5 | Base do descritor + execução HTTP |
| `OverlayToolRegistry` (hot-reload) + `ToolStore` | Fase 5 | Ingestão hot, sem restart |
| `write_data_tool` Command (upsert + reload) | Fase 5 | Alvo do importador em lote |
| `tools_allow`/`tools_deny` (allowlist por agente) | AgentProfile | Enablement por tool |
| `{{ctx.*}}` (chat/store/agent/tenant) | Etapa B (Fase 6) | Headers `X-*-Id` por turno |
| Egress guard + `secret_headers` + egress opt-in | Fase 5 + Fase 6 | Fronteira de saída |
| `params_schema` do RubyLLM = **JSON Schema** nativo | ruby_llm 1.16 (`tool.rb:91`) | Schema → provider |
| `ruby_llm-schema` 0.4.0 (DSL → JSON Schema) | gem instalada | Autoria in-code |

### GAPS
- **G1 — Params planos, não JSON Schema:** `ToolDefinition.parameters` é `[{name,type,required}]`;
  não expressa aninhamento nem é padrão.
- **G2 — Sem ingestão de manifesto/lote:** só `write_data_tool` uma-a-uma.
- **G3 — Sem envelopes padrão:** não aceita OpenAI *function tool* nem MCP *tool*.
- **G4 — Sem grupos/tags nem allowlist por grupo.**
- **G5 — Templates sem `{{secret.*}}`/`{{env.*}}`:** hoje o segredo é um `secret_header` estático
  (valor literal reconciliado pelo `ToolStore`), não uma referência resolvida na ingestão.
- **G6 — Conversor de migração** (`plugin OpenClaw → manifesto`) inexistente (one-off, fora do core).

## 4. Decisões de arquitetura

### D1 — JSON Schema é o formato dos parâmetros (a interlíngua)
`ToolDefinition.parameters` passa a ser/aceitar **JSON Schema** (objeto). O **array plano** legado é
convertido automaticamente para JSON Schema (`{type:object, properties:{…}, required:[…]}`) — zero
regressão. TypeBox (plugin), `ruby_llm-schema`, OpenAI `parameters`, Anthropic `input_schema` e MCP
`inputSchema` **todos são/emitem** JSON Schema → adotá-lo dá interoperabilidade de graça.

### D2 — Tool = interface (padrão) + binding (declarativo)
Duas camadas separadas:
- **Interface** (o que o modelo vê): `{ name, description, parameters:<JSON Schema> }`.
- **Binding** (como o motor chama): descritor HTTP declarativo (`method`/`url`/`headers`/`body`/
  `response`/`secret_headers`/`side_effect`). **Não** faz parte do schema-padrão (igual ao MCP: o
  schema descreve a interface, o servidor implementa) — é a camada agnóstica do harness.

### D3 — Ingestão por manifesto com adapters de entrada
Um manifesto (`defaults` + `tools[]`) é ingerido por um Command `:import_tools` (ou endpoint), fazendo
**upsert em lote** com **reload hot**. A interface de cada tool pode chegar em qualquer envelope
padrão — adapters normalizam para a forma interna:
- `parameters` (JSON Schema cru), OU
- `{ "type":"function", "function":{ name, description, parameters } }` (OpenAI/Anthropic), OU
- `{ name, description, inputSchema }` (MCP).

### D4 — Enablement por allowlist (tool + grupo), grupos como DADO
`tools_allow` (nomes) ∪ `tools_allow_groups` (grupos) no profile; `tools_deny` vence; allowlist vazia
= todas (paridade). **Grupos são declarados no manifesto** (`group`/`tags`) — **dado**, não
convenção-de-nome derivada em runtime (melhor que o OpenClaw, onde o grupo é regex de sufixo).

### D5 — Gating por flag fica FORA do motor
O que as flags de loja fazem no Rails (`groceries_v2_enabled?`, etc.) vira: (a) **allowlist derivada
no provisionamento** da loja (corta o schema **antes** de mandar pro modelo — resolve o desperdício
de tool-call do OpenClaw), ou (b) o próprio `/api/internal/*` responde erro e a data-tool propaga
`{error:}`. O motor **nunca** conhece "groceries_v2" (NF1).

### D6 — Secret fora do manifesto
Credencial nunca literal no manifesto: `{{secret.<nome>}}` é resolvido na **ingestão** (do
`SettingsStore`/env do deployment) e gravado como `secret_header` mascarado no `ToolStore` (como já
fazemos hoje com o token interno no `import_pack`). O manifesto fica **versionável sem segredo**.

### D7 — Conversor plugin→manifesto é migração one-off
Um script (`scripts/`) lê `acheib2b-tools-dev/tools/*.ts` (o TypeBox `Type.Object` **já é** JSON
Schema) + o slug do `callAgentTool` + envolve num binding → emite o manifesto das 44. **Fora do
core**, descartável (é específico do produto atual do cliente).

### D8 — MCP como evolução natural (follow-up)
Como MCP = `inputSchema` (JSON Schema) e o harness já tem scaffolding MCP (`upsert_mcp`/`McpStore`),
um **MCP server** do consumidor viraria ingestão **live** (descoberta automática, sem manifesto).
Adiado; o caminho JSON Schema deixa isso pronto.

## 5. Contratos

### Manifesto (formato genérico)
```jsonc
{
  "version": 1,
  "defaults": {
    "base_url": "{{env.ACHEI_INTERNAL_URL}}",            // ou literal https://…
    "path_template": "/api/internal/agent_tools/{endpoint}",
    "method": "POST",
    "headers": {
      "X-Chat-Id":  "{{ctx.chat_id}}",
      "X-Store-Id": "{{ctx.store_id}}",
      "X-Agent-Id": "{{ctx.agent_id}}",
      "Authorization": "Bearer {{secret.internal_token}}",
      "Content-Type": "application/json"
    },
    "secret_headers": ["Authorization"],
    "response": { "extract": "body_raw" }
  },
  "tools": [
    {
      "name": "search_products",
      "group": "default",
      "endpoint": "search_products",                     // vira {base}/…/search_products
      "description": "Busca no catálogo da loja…",
      "parameters": {                                    // JSON Schema (aninhado)
        "type": "object",
        "properties": {
          "query_filter_pairs": {
            "type": "array", "minItems": 1,
            "items": {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
                "filters": { "type": "object", "additionalProperties": true }
              },
              "required": ["query"]
            }
          }
        },
        "required": ["query_filter_pairs"]
      },
      "side_effect": false
    },
    {
      "name": "send_finalize_button", "group": "default", "endpoint": "finalize_button",
      "description": "Envia o botão Finalizar pedido…",
      "parameters": { "type":"object", "properties": { "message": { "type":"string" } }, "required":["message"] },
      "side_effect": true
    }
  ]
}
```
- **`endpoint`** resolve os remaps nome↔slug **por dado** (`send_finalize_button`→`finalize_button`,
  `search_faq`→`search_faqs`, `call_support`→`support_requests`, `search_voucher`→`search_vouchers`).
- **`url`** = `base_url` + `path_template`(`{endpoint}`) OU um `url` explícito na tool.
- Alternativa de interface: `"function": {…}` (OpenAI) ou `"inputSchema": {…}` (MCP) no lugar de
  `parameters` — o adapter normaliza.

### Enablement (AgentProfile)
- `tools_allow: [names]` — tools por nome (já existe).
- `tools_allow_groups: [groups]` — **novo**; expande para as tools daqueles grupos.
- `tools_deny: [names]` — vence (já existe). Vazio/nil em ambos allows = todas (paridade).

### ToolDefinition v2 (interna)
`name`, `description`, **`parameters` (JSON Schema)**, `request{method,url,headers,query,body}`,
`response{extract,path}`, `secret_headers`, `side_effect`, **`group`/`tags`**.

## 6. Plano de implementação (etapas → PRs)

| Etapa | Entrega | Complexidade |
|-------|---------|--------------|
| **A — ToolDefinition v2 (JSON Schema)** | `parameters` aceita JSON Schema; lift automático do array plano; `DataDefinedTool` alimenta `params_schema` do RubyLLM; validação de `{{placeholders}}` e `required` sobre o schema. **Prova: param aninhado (`search_products`) exposto ao modelo e interpolado no body.** | High |
| **B — Manifesto + ingestão dinâmica** | Schema do manifesto (`defaults`+`tools`); adapters de entrada (OpenAI/MCP/cru → interno); templates `{{secret.*}}`/`{{env.*}}`; Command `:import_tools` (upsert em lote + reload hot) + endpoint. | High |
| **C — Grupos/tags + allowlist por grupo** | `group`/`tags` no `ToolDefinition`; `tools_allow_groups` no `AgentProfile`; expansão na montagem do toolset (Policy/assembly). | Med |
| **D — Conversor de migração (one-off)** | `scripts/` lê `acheib2b-tools-dev/tools/*.ts` (TypeBox=JSON Schema) → `manifesto.json` das 44 (params/endpoints corretos). **Fora do core.** | Med |
| **E — (follow-up) MCP + corte por flag** | Ingestão de um MCP server; corte de schema por allowlist derivada de flag. | Adiado |

**Dependências:** A → B (B usa o schema de A). C independe (pode ir com B). D depende de A/B (emite o
formato deles). E é follow-up.

## 7. Riscos & edge cases
- **R1 — JSON Schema ↔ provider:** nem todo JSON Schema é suportado por todo provider. Mitigar:
  validar na ingestão um **subset seguro** (object/array/string/number/boolean/enum/required/nested/
  min/max) e rejeitar o resto com erro claro.
- **R2 — Compat das data-tools atuais (array plano):** Mitigar: lift automático + testes de paridade
  (a tool `cep`/viacep da Fase 5 continua idêntica).
- **R3 — Secret vazando no manifesto:** Mitigar: recusar `secret_header` com valor literal que
  **não** seja `{{secret.*}}`; obrigar a referência.
- **R4 — Falha parcial no lote:** Mitigar: upsert idempotente + relatório por-tool (como o pack
  importer da Fase 6 devolve `{created, files, skills, tools}`).
- **R5 — Egress p/ base_url dinâmica:** Mitigar: egress guard + `host_allowlist` (Fase 6 egress
  opt-in) — o destino interno entra por allowlist.
- **R6 — Nome↔slug divergente esquecido:** Mitigar: `endpoint` explícito no manifesto (o conversor
  extrai do `callAgentTool`), nunca inferido do `name`.

## 8. Open questions
1. **Grupos:** declarar no manifesto (recomendado — dado) vs. derivar do backend/flags? (Manifesto.)
2. **Corte de schema por flag:** estático (allowlist no provisionamento) vs. dinâmico (hook no
   assembly do toolset). (Piloto: estático; dinâmico é follow-up E.)
3. **`{{secret.*}}` de onde:** `SettingsStore`, env do deployment, ou um vault? (Recomendado:
   `SettingsStore`/env; um resolvedor injetável no composition root.)
4. **Ingestão:** Command novo `:import_tools` + endpoint `POST /v1/tools/manifest`, ou estender o
   `import_pack` (o pack passa a referenciar um manifesto compartilhado + allowlist)? (Avaliar: tools
   **compartilhadas** por manifesto global; packs de loja só referenciam via allowlist/grupo.)
5. **MCP:** adotar como fonte primária no futuro (o consumidor expõe um MCP server)? (Sim, evolução.)

## 9. Dependências & blockers
- **Reusa:** Fase 5 (data-tools/overlay/egress) + Etapa B (ctx) + Fase 6 (egress opt-in, pack importer).
- **Provider:** RubyLLM 1.16 (`params_schema` = JSON Schema nativo) + `ruby_llm-schema` 0.4.0.
- **Conversor (D):** depende de leitura do plugin OpenClaw — **fora do produto**, descartável.
- **Não bloqueado por** MCP (follow-up E) nem pelo achei-b2b (o motor é agnóstico; o manifesto é o
  contrato).

---

> ⚠️ **Spec AI-generated, requer revisão humana.** Atenção especial a §4 D1 (migração do
> `parameters` plano → JSON Schema, a mudança mais invasiva na Fase 5), §4 D3 (adapters de envelope)
> e §7 R1 (subset de JSON Schema seguro por provider).
