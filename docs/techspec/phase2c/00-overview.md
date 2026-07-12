# Techspec Fase 2 (fatia C) — Memória cross-session (camadas profile + notes)

> Segue o mesmo processo das fatias anteriores (HANDOFF-TECHSPEC.md): RFC = "o quê
> e porquê"; este doc + os componentes `P2C-01`–`P2C-02` = "como, exatamente".
> A RFC-0001 é a constituição. Evolui o código das Fases 1/2-A/2-B
> (`lib/harness/`, `config/wiring.rb`), não recomeça.
>
> **Fonte da verdade:** RFC-0005 §6 (Memory Integration), RFC-0006 (Stores),
> RFC-0002 §4 (Context Builder = estágio 2), BACKLOG "Fase 2 — Avançado".

## Escopo desta fatia

A Fase 2-B entregou a camada de **resolução/exposição de ferramentas**
(capabilities + tool search). Esta fatia entrega **memória cross-session** — o
agente lembra fatos entre sessões — pelo próximo bloco coeso do BACKLOG que
assenta nas 3 costuras que a fatia B acabou de exercitar (Context Provider, Store
de domínio, builtin-tool).

**Faz (entrada, RFC-0005 §6):**
1. **`MemoryStore`** — store de domínio sobre `Harness::Store` (RFC-0006), duas
   camadas escopadas por **tenant**: `profile` (fatos chave-valor estáveis) e
   `notes` (anotações livres append-only). Mesmo padrão do `PendingActionStore`
   (Fase 2-A).
2. **Read path** — `Context::Providers::Memory`: no turno, recupera os fatos +
   as notes recentes do tenant e injeta um fragmento `<memory>` no contexto
   (estágio 2), respeitando o orçamento de tokens do Builder.
3. **Write path** — builtin `Tools::Remember`: o agente grava fatos/notes sob
   demanda (determinístico, como `load_skill`/`tool_search`), emitindo
   `:memory_written`. **Sem extractor por LLM** nesta fatia.
4. **Threading de tenant** — o `ContextRequest` do Executor passa a carregar o
   `tenant` (do Command), reconciliando uma fatia do débito da Fase 1
   (task-14/15). Opt-in por agente via `AgentProfile.memory`.

**Não faz (fatia D / evolução):** camada **semantic** (embeddings + índice
vetorial, RFC-0005 §6.1); **extractor pós-turno por LLM** (auto-remember,
§6.3 — a entrada usa a tool explícita); **Skill Workshop** (§7);
Workspace/Artifact/Plugin providers; backend pgvector. Sem modelo real, sem
vetor — 100% determinístico e testável mockado.

## Como esta fatia evolui as Fases 1/2-A/2-B (costuras já prontas)

| Costura existente | Onde | O que a fatia C faz |
|---|---|---|
| `Harness::Store` (KV escopado por namespace, contrato RFC-0006) | `lib/harness/store.rb` | `MemoryStore` grava `profile`/`notes` no scope `memory:<tenant>` |
| `PendingActionStore` (store de domínio: normaliza symbol→string, scan O(n)) | `lib/harness/pending_action_store.rb` | `MemoryStore` espelha esse padrão exato |
| Context Provider seam (estágio 2, fan-out + orçamento) | `lib/harness/context/builder.rb`, `context/provider.rb` | `Context::Providers::Memory` produz um fragmento `:system` (como Skill/ToolSearch) |
| `enabled_for?(profile)` + allowlist `context_providers` | `context/builder.rb#select_providers` | provider de memória é gated por `profile.memory` (opt-in) |
| builtin-tool de sistema (require lazy, `def name`, wired no `configure_chat`) | `tools/load_skill.rb`, `tools/tool_search.rb` | `Tools::Remember` segue o mesmo padrão |
| `Executor::ContextRequest` Struct (SEM `tenant`; débito Fase 1) | `lib/harness/executor.rb:326` | ganha `:tenant`, populado do Command (reconcilia parte do débito) |
| `AgentProfile` com allowlists opt-in (`capabilities`, `tools_deferred`) | `lib/harness/agent_profile.rb` | + `memory` (opt-in por agente) |
| Catálogo de eventos D5 | `lib/harness/event.rb`, `00-overview` D5 | + `:memory_written` |
| Composition root único | `config/wiring.rb` | constrói `MEMORY_STORE`, injeta no Executor + `CONTEXT_PROVIDERS` |

## Decisões globais desta fatia

### D1 — Duas camadas determinísticas nesta fatia; semantic é evolução
`profile` (chave-valor, ex.: `{ "nome" => "Ana", "plano" => "premium" }`) e
`notes` (texto livre append-only) são puras — sem embeddings, sem ranking por
similaridade. A recuperação é: **todos** os fatos (conjunto pequeno) + as **N
notes mais recentes** (sub-orçamento por contagem). A camada `semantic`
(RFC-0005 §6.1, top-k por similaridade) fica para a fatia D — é o único pedaço
que exige modelo/vetor e não é "testável logo". Split entrada/evolução, no
espírito da RFC-0004 §8.

### D2 — Escopo por tenant; fallback `_default` documentado
Memória cross-session é **escopada por tenant** (RFC-0005 §6). O `MemoryStore`
usa o `scope` do `Harness::Store`: `memory:<tenant>`. Sem tenant no Command →
scope `memory:_default` (deployments single-tenant funcionam; multi-tenant DEVEM
passar `tenant` no Command). **NÃO** escopar por `session_id` (seria
session-scoped, anulando o "cross-session") nem por `agent_id` por default.

### D3 — Write path é uma TOOL explícita (determinística), não um extractor por LLM
Fiel ao "human/agent no loop" e à testabilidade: o agente decide o que lembrar
chamando `remember` (como este harness usa um memory tool). Zero chamada de
modelo no write path → determinístico, testável sem chave de API. O extractor
automático por LLM (RFC-0005 §6.3) é evolução (fatia D). `remember` grava fato
(`key`+`value`) ou note (`value` sem `key`), emite `:memory_written`.

### D4 — Read é PROVIDER (sem evento); write é TOOL (com evento) — simetria da fatia B
O read path é um Context Provider (estágio 2) que **não emite evento** — igual ao
Skill/ToolSearch provider (falha → `:provider_warning`, degradação graciosa, o
provider é `required? == false`). O write path é uma tool que **emite
`:memory_written`** — igual ao `tool_search`/`:tool_search`. Mesma disciplina que
a fatia B já fixou.

### D5 — Opt-in por agente via `AgentProfile.memory`
`memory: nil`/ausente = desligado (o provider retorna `[]` via `enabled_for?`, a
tool não é cabeada) → **paridade total** com agentes existentes. `memory: true` =
ligado. Explícito, como `capabilities`/`tools_deferred`. Habilitar o provider
globalmente no `CONTEXT_PROVIDERS` é seguro porque `enabled_for?` corta por
perfil (e store vazio produz `[]` de qualquer forma).

### D6 — `tenant` no `ContextRequest` do Executor (reconcilia débito da Fase 1)
O `Executor::ContextRequest` (Struct, `executor.rb:326`) — o objeto que os
providers REALMENTE recebem — não tem `tenant` hoje (o `Request` provider já
chama `request.tenant`, um seam pendente da Fase 1). Esta fatia adiciona `:tenant`
ao Struct, populado de `rebuild_command(task).meta[:tenant]` (o Command carrega
`tenant`, `command.rb:21`). O `remember` tool recebe o mesmo scope resolvido. Não
reabrimos o `vars` (outro seam) — só o `tenant`, que é o necessário aqui.

### D7 — Nomenclatura: `MemoryStore` (domínio) ≠ `Stores::Memory` (backend)
`Harness::Stores::Memory` (Fase 1) é o BACKEND KV em memória. `Harness::MemoryStore`
(esta fatia) é o STORE DE DOMÍNIO de memória-do-agente, sobre um `Harness::Store`
QUALQUER (Memory ou SQLite). Namespaces distintos (`Stores::` vs top-level) +
comentário no topo de cada um para não confundir.

### D8 — Catálogo de eventos estendido, não reaberto
Novo tipo: `:memory_written { kind, key }` (kind: `fact` | `note`). Registrado no
catálogo canônico (Fase 1 D5). Read não ganha evento (D4).

## Componentes (docs a detalhar)

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `P2C-01-memory-store-and-read.md` | `MemoryStore` (profile+notes, scope por tenant) + `Context::Providers::Memory` (read) + `AgentProfile.memory` + threading de tenant | 0005 §6, 0006 |
| `P2C-02-remember-tool-and-wiring.md` | `Tools::Remember` (write) + integração no Executor/`configure_chat` + wiring do composition root + `:memory_written` | 0005 §6, 0002 §6 |

## Plano de tarefas (resumo — detalhe em `tasks/tasks.md`)

Ordem por dependência: store → profile/tenant → read provider (Etapa A); write
tool → executor/wiring → smoke E2E (Etapa B). Ver `tasks/tasks.md`.

## Critério de conclusão da fatia

1. Um agente com `memory: true` chama `remember(key: "plano", value: "premium")`
   na **sessão 1**; `:memory_written` é emitido; o fato persiste no `MemoryStore`
   escopado pelo tenant.
2. Numa **sessão 2 nova** (mesmo tenant, mesmo agente), o
   `Context::Providers::Memory` recupera o fato e injeta `<memory>` no `system` do
   turno — o agente "lembra" sem ter sido dito de novo.
3. `remember(value: "cliente prefere email")` (sem `key`) grava uma **note**;
   notes recentes aparecem no contexto da sessão seguinte.
4. Um agente com `memory: nil` (default) não recebe o fragmento de memória nem a
   tool `remember` — **paridade Fase 1** (nenhum agente existente muda).
5. Suíte inteira verde sem chave de API (store/provider/tool determinísticos;
   RubyLLM mockado só na integração) — herda o critério de testabilidade.
