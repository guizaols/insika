# Task 11 (P2B): Wiring (CapabilityRegistry + ToolCatalog) + catálogo de eventos D5

> **Techspec:** [00-overview.md](../00-overview.md) (D7) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** C

## Objetivo
Ligar as duas peças que as Etapas A e B construíram de forma isolada
(`CapabilityRegistry` na task 5, `ToolCatalog` na task 10 — ambas já injetadas
no `Executor` com default `nil`, paridade preservada) ao único composition
root da aplicação (`config/wiring.rb`, doc 07 §8/RFC-0001 §4): construir as
constantes, injetá-las no `EXECUTOR.new` real e fechar o catálogo canônico de
eventos (D5, Fase 1) com os dois tipos novos da fatia B
(`:capability_resolved`, `:tool_search`), que as tasks 1 e 9 já emitem mas que
ainda não constam na tabela-contrato nem no doc-comment do `Event`. Task
100% de fiação — nenhuma lógica nova, nenhum estágio novo (D3 do overview
desta fatia: capability assembly é sub-passo, não pipeline paralela).

## Dependências

| Task | O que fornece |
|------|----------------|
| Task 05 | `Executor` já aceita `capability_registry:` (default `nil`) e faz a capability assembly entre Context e Policy |
| Task 10 | `Executor` já aceita `tool_catalog:` (default `nil`) e particiona `allowed_tools` em eager/deferred no `configure_chat` |

## Contexto
O composition root é único (`config/wiring.rb`) — doc 07 §8 e o comentário de
topo do próprio arquivo: é o único lugar onde dependências são construídas e
injetadas; constantes globais (`REGISTRY`, `CATALOG`, ...) são atalho de
leitura, não fonte de verdade para teste (as classes aceitam injeção direta).
Esta task não inventa wiring novo: segue o padrão já estabelecido para
`REGISTRY`/`WORKFLOW_REGISTRY`/`POLICY_REGISTRY` (construção eager na linha
~44-46) e para os argumentos nomeados do `EXECUTOR.new` (~84-91).

O catálogo canônico de eventos (00-overview.md D5, Fase 1) foi fechado
deliberadamente: "novos tipos exigem atualizar esta tabela — é o contrato do
wire". Esta fatia **estende**, não reabre (D7 do overview desta fatia): os
dois tipos novos entram como linhas adicionais da MESMA tabela, com a MESMA
disciplina (`data` explícito, origem nomeada). As tasks 1 (`CapabilityRegistry
#resolve`) e 9 (`Tools::ToolSearch#execute`) já são responsáveis por emitir
esses eventos no código — esta task só os REGISTRA no contrato canônico
(doc + doc-comment do `Event`), não emite nada.

**Achado de investigação (documentar, não bloqueia a task):** hoje
`config/wiring.rb` **não constrói** um `Harness::Plugin::Loader` em nenhum
call site de produção — `load_plugins` é um no-op explícito (linha ~151), com
o próprio comentário de topo do arquivo (linhas 9-15) dizendo que este arquivo
"será REFATORADO pela task 26" (débito herdado da Fase 1/2-A, ainda não
pago) para plugar descoberta de plugins de verdade. `Harness::Plugin::Loader`
só é construído em `spec/harness/plugin/loader_spec.rb` (helper `registries`,
linha 21-24) e no `docs/harness_handoff/reference-implementation/` (projeto de
referência externo, não este). Portanto **não há hoje um call site real em
`config/wiring.rb` ou em `server/boot.rb`** para injetar `capabilities:
CAPABILITY_REGISTRY` no registries hash do loader — a instrução original da
task ("passe CAPABILITY_REGISTRY para o registries hash do PluginLoader")
pressupõe um call site que só existirá quando a task 26 (débito da Fase 1)
for paga. Esta task resolve isso deixando `CAPABILITY_REGISTRY` **pronta e
documentada** no composition root (Passo 3) para esse dia, em vez de inventar
uma construção de `Loader` fora de escopo. Sinalizar no code review.

## Arquivos

| Arquivo | Ação |
|---------|------|
| `config/wiring.rb` | MODIFY — constrói `CAPABILITY_REGISTRY`/`TOOL_CATALOG`; injeta no `EXECUTOR.new`; adiciona `Context::Providers::ToolSearch` a `CONTEXT_PROVIDERS`; comentário-ponte para o registries hash do (futuro) `PluginLoader` |
| `docs/techspec/00-overview.md` | MODIFY — tabela D5: + linhas `:capability_resolved`, `:tool_search` |
| `lib/harness/event.rb` | MODIFY — doc-comment: catálogo estendido pela fatia 2-B |

## Passo a passo

### Passo 1 — Construir `CAPABILITY_REGISTRY` e `TOOL_CATALOG` no composition root

Ao lado de `REGISTRY`/`WORKFLOW_REGISTRY`/`POLICY_REGISTRY` (mesma seção
"Event Stream + registries/catalogs", doc 03/06), adicionar as duas
constantes novas da fatia B. `TOOL_CATALOG` depende de `REGISTRY` (o
`ToolCatalog` lê metadados das entries já registradas — mesma indireção do
`SkillCatalog` sobre os `skills/` do workspace), então entra DEPOIS dele:

**Padrão de referência (codebase) — bloco atual em `config/wiring.rb`:**
```ruby
REGISTRY          = Harness::ToolRegistry.new
WORKFLOW_REGISTRY = Harness::WorkflowRegistry.new
POLICY_REGISTRY   = Harness::PolicyRegistry.new

# Builtins do estágio 3 (doc 05 §2): registrados NO BOOT pelo composition
# root, não pelo registry (doc 05/06). Consumidos via `fetch(name)`.
POLICY_REGISTRY.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist)
POLICY_REGISTRY.register(:skill_allowlist, Harness::Policy::Builtin::SkillAllowlist)
POLICY_REGISTRY.register(:workflow_allowlist, Harness::Policy::Builtin::WorkflowAllowlist)
POLICY_REGISTRY.register(:approval_required, Harness::Policy::Builtin::ApprovalRequired)
```

**Depois (adicionar logo após o bloco acima):**
```ruby
# --- Capability Registry + Tool Catalog (P2B-01/02, doc D7) --------------
# CapabilityRegistry é INDIREÇÃO (D1 do overview da fatia): guarda Providers,
# resolve para o impl_name que o REGISTRY/WORKFLOW_REGISTRY instancia. Zero
# execução aqui. ToolCatalog lê metadados do REGISTRY já construído acima
# (mesmo padrão do SkillCatalog sobre os skills/ do workspace).
CAPABILITY_REGISTRY = Harness::CapabilityRegistry.new
TOOL_CATALOG        = Harness::ToolCatalog.new(tool_registry: REGISTRY)
```

### Passo 1b — Registrar `Context::Providers::ToolSearch` em `CONTEXT_PROVIDERS`

O catálogo `<available_tools>` é emitido por um Context Provider (task 8, decisão
D5/D4 — o Runtime não monta prompt), então o provider entra no array
`CONTEXT_PROVIDERS`, ao lado do `Skill` provider.

**Padrão de referência (codebase) — `CONTEXT_PROVIDERS` atual:**
```ruby
CONTEXT_PROVIDERS = [
  Harness::Context::Providers::Request.new,
  Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
  Harness::Context::Providers::Skill.new(catalog: CATALOG),
  Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
].freeze
```
**Depois (acrescentar o provider de Tool Search — usa `TOOL_CATALOG`):**
```ruby
CONTEXT_PROVIDERS = [
  Harness::Context::Providers::Request.new,
  Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
  Harness::Context::Providers::Skill.new(catalog: CATALOG),
  Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
  Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
].freeze
```
> `ToolSearch` provider é inerte p/ agentes sem `tools_deferred` (retorna `[]`),
> então habilitá-lo globalmente não muda nenhum agente da Fase 1 (paridade).

### Passo 2 — Injetar as duas constantes no `EXECUTOR.new`

**Padrão de referência (codebase) — `EXECUTOR.new` atual:**
```ruby
EXECUTOR = Harness::Executor.new(
  context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
  middleware: MIDDLEWARE, hooks: HOOKS,
  tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
  workflow_registry: WORKFLOW_REGISTRY, pending_action_store: PENDING_ACTION_STORE
)
```

Adicionar `capability_registry:` e `tool_catalog:` à lista de argumentos
nomeados (o `Executor` da task 5/10 já os aceita com default `nil` — esta
task só passa os valores reais):
```ruby
EXECUTOR = Harness::Executor.new(
  context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
  middleware: MIDDLEWARE, hooks: HOOKS,
  tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
  workflow_registry: WORKFLOW_REGISTRY, pending_action_store: PENDING_ACTION_STORE,
  capability_registry: CAPABILITY_REGISTRY, tool_catalog: TOOL_CATALOG
)
```

### Passo 3 — Ponte documentada para o registries hash do `PluginLoader`

Não existe hoje, em `config/wiring.rb` nem em `server/boot.rb`, um call site
de produção que construa `Harness::Plugin::Loader` (ver achado no
`## Contexto`) — `load_plugins` é no-op:
```ruby
def self.load_plugins = nil
```
Não inventar um `Loader.new` fora de escopo (isso é débito da task 26 da
Fase 1). Em vez disso, deixar um comentário-ponte imediatamente acima dessa
linha, para quem pagar o débito não esqueça de incluir a chave nova no
registries hash (mesma chave usada por `spec/harness/plugin/loader_spec.rb`
para as demais: `tools:`, `workflows:`, `policies:`, `hooks:`, `middleware:`,
`context_providers:`):
```ruby
# NB (débito task 26, Fase 1): quando este no-op virar um
# Harness::Plugin::Loader.new real, o registries hash PRECISA incluir
# `capabilities: CAPABILITY_REGISTRY` (contracts.capabilities, task 4 P2B) —
# a ausência da chave é segura (loader ignora capabilities, ver task 4 L-edge),
# mas sem ela nenhum plugin consegue registrar capability.
def self.load_plugins = nil
```

### Passo 4 — Estender a tabela D5 (`docs/techspec/00-overview.md`)

**Padrão de referência (codebase) — tabela D5 atual (linhas ~171-187):**
```markdown
| Tipo | data | Origem |
|------|------|--------|
| `:task_started` | `{ task_id, command }` | Executor |
| `:content` | `{ delta }` | RubyLLM streaming |
| `:skill_activated` | `{ name }` | before_tool_call (load_skill) |
| `:tool_call` | `{ name, arguments }` | before_tool_call |
| `:tool_result` | `{ name, result }` | after_tool_result |
| `:checkpoint_created` | `{ task_id, turn }` | estágio Persistence |
| `:policy_denied` | `{ policy, reason }` | Policy Engine |
| `:provider_warning` | `{ provider, message }` | Context Builder (degradação) |
| `:session_created` | `{ session_id }` | handler CreateSession |
| `:plugin_loaded` | `{ id, tools, skills }` | PluginLoader (boot) |
| `:task_completed` | `{ task_id, content }` | Executor |
| `:task_failed` | `{ task_id, error, message }` | Executor |
| `:task_cancelled` | `{ task_id }` | Executor |
| `:done` | `{ content }` | Executor (compat Fase 0) |
| `:error` | `{ message }` | qualquer estágio (compat Fase 0) |
```

Adicionar as duas linhas da fatia 2-B (referenciar a fatia de origem, como já
é feito para as demais linhas por `Origem`):
```markdown
| `:capability_resolved` | `{ capability, chosen, candidates }` | CapabilityRegistry (P2B-01) |
| `:tool_search` | `{ query, matched }` | Tools::ToolSearch (P2B-02) |
```

Logo abaixo da tabela, no parágrafo "`:done` e `:error` são mantidos...",
acrescentar uma frase curta remetendo à fatia 2-B (mesma disciplina do D7 de
`phase2b/00-overview.md`, para quem ler só o doc de Fase 1 saber que o
catálogo foi estendido e onde):
```markdown
A fatia 2-B (`phase2b/00-overview.md` D7) estendeu este catálogo com
`:capability_resolved` e `:tool_search` — falhas de resolução de capability
NÃO ganham evento próprio, propagam como `CapabilityError` pelos eventos
`:error`/`:task_failed` já existentes.
```

### Passo 5 — Doc-comment do `Event` (`lib/harness/event.rb`)

**Padrão de referência (codebase) — doc-comment atual:**
```ruby
module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
```

Trocar só a primeira linha do comentário (o `Data.define` e o resto do
comentário não mudam — `Event` continua sem validar tipo contra allowlist,
é PORO puro; o fechamento do catálogo é disciplina de doc, não código):
```ruby
module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela; estendido
  # pela fatia 2-B com :capability_resolved/:tool_search, doc D7 de
  # phase2b/00-overview.md).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
```

## Edge cases
- `Executor.new` sem `capability_registry:`/`tool_catalog:` (specs antigas,
  smoke antigo em `spec/support/smoke/boot_app.rb`) continua funcionando —
  ambos têm default `nil` na assinatura da task 5/10 (paridade Fase 1: sem
  capabilities/tool search, comportamento idêntico ao pré-fatia-B). Esta task
  NÃO precisa tocar `spec/support/smoke/boot_app.rb` — ele fica sem as duas
  chaves de propósito, provando a paridade por omissão.
- `PluginLoader` que não recebe `capabilities:` no registries hash (hoje, o
  único caso real: `spec/harness/plugin/loader_spec.rb`) apenas ignora
  `contracts.capabilities` no manifesto — mesma degradação graciosa que
  `hooks:`/`middleware:`/`context_providers:` ausentes teriam; não é erro
  fatal (comportamento a cargo da task 4, não desta).
- `TOOL_CATALOG` construído sobre um `REGISTRY` vazio (base do wiring, antes
  de qualquer plugin/tool registrada) é um catálogo vazio válido — `search`
  não erra, só não acha nada (mesmo padrão do `SkillCatalog` vazio hoje).
- Reordenar a extração das constantes (`TOOL_CATALOG` antes de `REGISTRY`
  existir) quebraria por `NameError` — manter a ordem do Passo 1
  (`REGISTRY` → `TOOL_CATALOG`), já é a ordem natural de leitura do arquivo.

## Testes
**Arquivo:** `spec/harness/event_spec.rb` + smoke de carga do wiring (boot)

| Cenário | Verificação |
|---|---|
| `spec/harness/event_spec.rb` | inalterado — `Event` não valida tipo contra allowlist; nenhum caso novo exigido pelo Passo 5 (é doc-comment). Rodar a suíte existente só para confirmar que nada quebrou. |
| Carga de `config/wiring.rb` (`require_relative "config/wiring"` num spec/smoke, ou reaproveitar o boot existente) | não explode: `CAPABILITY_REGISTRY`/`TOOL_CATALOG` resolvem sem erro; `EXECUTOR` responde a `capability_registry`/`tool_catalog` (se a task 5/10 expuser leitor) ou ao menos constrói sem `ArgumentError` de keyword ausente/desconhecida |
| `docs/techspec/00-overview.md` | revisão manual: tabela D5 tem as 2 linhas novas; nenhuma linha antiga removida/alterada |
| `lib/harness/event.rb` | revisão manual: doc-comment menciona a extensão; `Event = Data.define(...)` byte-a-byte inalterado (só comentário muda) |

## Definition of Done
- [ ] `CAPABILITY_REGISTRY` e `TOOL_CATALOG` construídos em `config/wiring.rb`, na ordem correta (depois de `REGISTRY`)
- [ ] `EXECUTOR.new` recebe `capability_registry: CAPABILITY_REGISTRY, tool_catalog: TOOL_CATALOG`
- [ ] Comentário-ponte para o registries hash do (futuro) `PluginLoader` adicionado acima de `load_plugins`
- [ ] Tabela D5 de `docs/techspec/00-overview.md` com as 2 linhas novas (`:capability_resolved`, `:tool_search`) + frase de remissão à fatia 2-B
- [ ] Doc-comment de `lib/harness/event.rb` atualizado
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review (sinalizar explicitamente o achado do `## Contexto` sobre o `PluginLoader` não construído em produção — decidir se vira ticket de débito junto da task 26 ou fica só como comentário)

## Notas
- Esta task é 100% wiring + documentação — nenhuma classe nova, nenhum
  método novo. Toda a lógica (`CapabilityRegistry#resolve`,
  `Tools::ToolSearch#execute`, emissão dos dois eventos) já foi entregue
  pelas tasks 1 e 9; aqui só se registra o contrato e se liga o fio.
  Complexity Low é fiel a isso — se esta task crescer código de negócio,
  algo foi mal decomposto nas tasks 1/9.
- Inconsistência a validar com quem revisar: a task original pede para
  "achar onde o `PluginLoader` é construído" em `config/wiring.rb` ou num
  boot step — nenhum dos dois constrói o `Loader` hoje (a Fase 1 deixou isso
  como débito explícito da "task 26", ainda não pago). O Passo 3 resolve
  isso com um comentário-ponte em vez de inventar um call site; se o time
  preferir, dá para em vez disso já criar esse call site aqui (adiantando
  parte da task 26) — decisão de escopo para o review, não bloqueia a task.
