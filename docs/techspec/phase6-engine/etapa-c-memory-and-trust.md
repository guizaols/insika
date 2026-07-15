# Fase 6 · Etapa C — Memória dono-por-agente + fronteira de confiança

> Fecha as tasks **5** (memória dono-por-agente) e **6** (fronteira de confiança).
> Decisões: §4 D3 e D5; requisitos F5, NF3; risco R4. Base: Etapa B (contexto de
> turno) já mergeada.

## 1. Memória: dono-por-agente (task 5, D3/F5)

O motor suporta **duas pontas**, escolhidas por `profile.memory`. Contexto é soma
de fragmentos, então as pontas coexistem; a precedência é a da §2.

### Ponta A — consumidor dono (drop-in default, `profile.memory = false`)
O bloco `<memoria>` (e sempre o `<dados_conhecidos>`) chega **dentro do `input`**
já composto pelo consumidor. O motor **não faz nada**: o `input` entra verbatim
como a mensagem do turno (Etapa A, F4). `Memory` provider desligado
(`enabled_for?` = false), tool `remember` **não** cabeada. É o modo do **piloto**
(Open Question #1: começar drop-in, medir, depois avaliar).

### Ponta B — motor dono (evolução, `profile.memory = true`)
- **Read:** o `Memory` provider injeta `<memory>` (fatos + notes) — fragmento
  `:system`, priority `MEMORY` (75), **não-pinned** (cortável sob orçamento).
- **Write:** a tool de sistema `remember` grava fato/nota no `MemoryStore`.
- **Escopo = chat (D3):** tenant da memória = **tenant explícito do Command**
  (override multi-merchant) **ou** a **sessão** (`user`=chat.id). Simétrico entre
  read (`Memory#memory_tenant`) e write (`Executor#memory_tenant` → `state.tenant`).
  One-shot sem tenant → `_default` do `MemoryStore`.

> **Sutileza de paridade (NF2):** o `tenant` do `<request_context>` **não** mudou
> — segue vindo do `command_tenant` (explícito). O fallback-para-chat vale só para
> o **escopo de leitura/escrita da memória**, não para o texto do prompt. Assim o
> prompt do harness não ganha uma linha `tenant: <chat_id>` que o gateway não tem.

### `<dados_conhecidos>` é SEMPRE do consumidor
Catálogo/cliente/carrinho são do **sistema de registro** (achei-b2b). O motor
nunca "possui" isso — chega no `input` a cada turno, verbatim.

## 2. Fronteira de confiança (task 6, D5/NF3/R4)

**Escada de precedência** — fonte única em `Harness::Context::Priority`
(`lib/harness/context/priority.rb`); os providers referenciam as constantes:

| Fragmento | priority | pinned | Origem |
|-----------|---------:|:------:|--------|
| IDENTITY/SOUL | 100 | ✅ | `Prompt` (IDENTITY.md/SOUL.md — guardrails) |
| prompt_refs (guardrails do catálogo) | 90 | ✅ | `Prompt` |
| `<available_skills>` | 80 | — | `Skill` |
| `<memory>` | 75 | — | `Memory` |
| `<available_tools>` | 70 | — | `ToolSearch` |
| histórico (por recência) | 60–79 | — | `Session` |
| **`<request_context>` (injeção de turno)** | **40** | — | `Request` |

**Invariantes (travadas por `spec/harness/context/trust_boundary_spec.rb`):**
1. Identidade/guardrails entram **pinned** no topo e **precedem** as injeções de
   turno no system prompt.
2. Sob orçamento, os fragmentos de **injeção de turno** (`<request_context>`) são
   **sacrificados primeiro** (menor priority); a identidade (pinned) **nunca** é
   truncada — se só a identidade já excede o cap, é `ContextError` (não corte).
3. Os blocos que o consumidor injeta (`<memoria>`/`<dados_conhecidos>`) viajam na
   **mensagem do turno** (papel *user*), inerentemente **abaixo** do system — são
   **dado, não autoridade**. Um prompt-injection ali não sobrepõe SOUL/guardrails.

**Segurança é do motor/profile, nunca do bloco injetado (NF3):** allow/deny de
tool (Policy Engine + allowlist do `AgentProfile`), egress (`EgressGuard`) e
approvals (`approvals_required`) são decididos server-side. Nenhum texto que suba
por `dados_conhecidos`/`input` expande a allowlist, libera egress ou dispensa
aprovação — essas decisões não leem o conteúdo injetado.

## 3. O que NÃO entrou (escopo, D6)
- Migrar o `memoria` do piloto para o `MemoryStore` — só quando medirmos (Open Q #1).
- "Guardrail skills" como categoria pinível própria: no padrão `docs/prompt-base`
  os guardrails vivem em **SOUL** (identidade, pinned 100) ou em **prompt_refs**
  (pinned 90) — ambos já acima das injeções de turno. Um flag por-skill fica para
  quando um projeto real precisar, evitando mecanismo sem uso no piloto.
