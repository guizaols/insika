# Task 07 (P2C): Wiring (`MEMORY_STORE` + provider) + catálogo de eventos D5

> **Techspec:** [P2C-02-remember-tool-and-wiring.md](../P2C-02-remember-tool-and-wiring.md) (§Wiring/§Catálogo, D8) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Low · **Etapa:** B

## Objetivo

Ligar a fatia C inteira ao único composition root da aplicação
(`config/wiring.rb`, doc 07 §8/RFC-0001 §4): construir `MEMORY_STORE` sobre o
`BACKEND` durável (mesmo padrão de `SESSION_STORE`/`TASK_STORE`/
`CHECKPOINT_STORE`), registrar `Context::Providers::Memory` em
`CONTEXT_PROVIDERS` e injetar `memory_store:` no `EXECUTOR.new` — e fechar o
catálogo canônico de eventos (D5, Fase 1, já estendido pela fatia B com
`:capability_resolved`/`:tool_search`) com o tipo novo da fatia C
(`:memory_written`), que a task 5 (`Tools::Remember`) já emite no código mas
que ainda não consta na tabela-contrato nem no doc-comment do `Event`. Task
100% de fiação — nenhuma lógica nova, nenhum estágio novo (a memória é
sub-passo de Context/tool de sistema, não pipeline paralela).

## Dependências

| Task | O que fornece |
|------|----------------|
| Task 04 | `Context::Providers::Memory` pronto (`lib/harness/context/providers/memory.rb`), com `enabled_for?(profile) = !!profile.memory` — inerte p/ agentes sem `memory` |
| Task 06 | `Executor` já aceita `memory_store:` (default `nil`, paridade) e cabeia `Tools::Remember` de sistema quando `@memory_store` presente + `profile.memory` |

## Contexto

O composition root é único (`config/wiring.rb`) — doc 07 §8 e o comentário de
topo do próprio arquivo: é o único lugar onde dependências são construídas e
injetadas; constantes globais (`MEMORY_STORE`, `CAPABILITY_REGISTRY`,
`TOOL_CATALOG`, ...) são atalho de leitura, não fonte de verdade para teste
(as classes aceitam injeção direta). Esta task não inventa wiring novo: segue
exatamente o padrão que a fatia B (task 11 do phase2b) já estabeleceu para
`CAPABILITY_REGISTRY`/`TOOL_CATALOG` — construção eager ao lado dos demais
stores de domínio, provider acrescentado a `CONTEXT_PROVIDERS`, kwarg novo no
`EXECUTOR.new`.

`MEMORY_STORE` é construído sobre `BACKEND` (a mesma variável que já
determina `Stores::SQLite` durável quando `HARNESS_DB` está setado, ou
`Stores::Memory` efêmero em dev) — não um backend próprio. Isso é consistente
com `SESSION_STORE`/`TASK_STORE`/`CHECKPOINT_STORE`/`PENDING_ACTION_STORE`,
todos construídos `Harness::XStore.new(store: BACKEND)` sobre o mesmo backend
único, e é a garantia de que memória cross-session sobrevive a restart quando
`HARNESS_DB` está definido (mesmo critério de durabilidade do doc 00 §6).

O provider `Context::Providers::Memory` é registrado globalmente em
`CONTEXT_PROVIDERS` (não condicionalmente por agente) — o próprio provider é
inerte para agentes sem `memory` via `enabled_for?` (task 4), então
habilitá-lo globalmente não muda nenhum agente pré-existente (paridade Fase
1/2-A/2-B por omissão do flag).

O catálogo canônico de eventos (00-overview.md D5, Fase 1) foi fechado
deliberadamente e já foi estendido uma vez pela fatia B (D7 do
`phase2b/00-overview.md`, com `:capability_resolved`/`:tool_search`). Esta
fatia **estende de novo**, não reabre: `:memory_written` entra como mais uma
linha da MESMA tabela, com a MESMA disciplina (`data` explícito, origem
nomeada). A task 5 (`Tools::Remember#execute`) já é responsável por emitir
esse evento no código — esta task só o REGISTRA no contrato canônico (doc +
doc-comment do `Event`), não emite nada.

## Arquivos

| Arquivo | Ação |
|---------|------|
| `config/wiring.rb` | MODIFY — constrói `MEMORY_STORE = Harness::MemoryStore.new(store: BACKEND)`; adiciona `Context::Providers::Memory` a `CONTEXT_PROVIDERS`; adiciona `memory_store: MEMORY_STORE` ao `EXECUTOR.new` |
| `docs/techspec/00-overview.md` | MODIFY — tabela D5: + linha `:memory_written` |
| `lib/harness/event.rb` | MODIFY — doc-comment: catálogo estendido também pela fatia 2-C |
| `spec/harness/wiring_load_spec.rb` | MODIFY — estende o guard de carga do composition root: `MEMORY_STORE` construído, `Memory` provider em `CONTEXT_PROVIDERS`, `EXECUTOR` aceita `memory_store:` |

## Passo a passo

### Passo 1 — Construir `MEMORY_STORE` no composition root

Ao lado de `SESSION_STORE`/`TASK_STORE`/`CHECKPOINT_STORE`/
`PENDING_ACTION_STORE` (mesma seção "Persistência", doc 01/02) — todos
construídos sobre o `BACKEND` único —, adicionar a constante nova da fatia C.

**Padrão de referência (codebase) — bloco atual em `config/wiring.rb`:**
```ruby
SESSION_STORE    = Harness::SessionStore.new(store: BACKEND)
TASK_STORE       = Harness::TaskStore.new(store: BACKEND)
CHECKPOINT_STORE = Harness::CheckpointStore.new(store: BACKEND)
PENDING_ACTION_STORE = Harness::PendingActionStore.new(store: BACKEND)
```

**Depois (adicionar logo após o bloco acima):**
```ruby
# --- Memória cross-session (P2C, RFC-0005 §6) sobre o BACKEND durável -----
# MemoryStore é domínio (facts + notes por tenant), Stores::Memory é backend
# (namespaces distintos — doc D7 do P2C). Sobre o mesmo BACKEND que os demais
# stores: SQLite durável quando HARNESS_DB setado (memória sobrevive a
# restart), Memory efêmero em dev.
MEMORY_STORE = Harness::MemoryStore.new(store: BACKEND)
```

Este é exatamente o padrão que a fatia B já usou para `CAPABILITY_REGISTRY`/
`TOOL_CATALOG` (task 11 do phase2b) — construção eager, comentário de origem
+ decisão de indireção, na seção correspondente do arquivo.

### Passo 2 — Registrar `Context::Providers::Memory` em `CONTEXT_PROVIDERS`

O fragmento `<memory>` (facts + N notes recentes) é emitido por um Context
Provider (task 4, mesma decisão D4 da fatia B — o Runtime não monta prompt),
então o provider entra no array `CONTEXT_PROVIDERS`, ao lado do `ToolSearch`
provider que a fatia B já acrescentou.

**Padrão de referência (codebase) — `CONTEXT_PROVIDERS` atual (fatia B já
adicionou o `ToolSearch`):**
```ruby
CONTEXT_PROVIDERS = [
  Harness::Context::Providers::Request.new,
  Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
  Harness::Context::Providers::Skill.new(catalog: CATALOG),
  # Tool Search nível-1 (P2B-02, task 8): emite <available_tools> de
  # profile.tools_deferred. Inerte p/ agentes sem tools_deferred (retorna []).
  Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
  Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
].freeze
```

**Depois (acrescentar o provider de Memória — usa `MEMORY_STORE`):**
```ruby
CONTEXT_PROVIDERS = [
  Harness::Context::Providers::Request.new,
  Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
  Harness::Context::Providers::Skill.new(catalog: CATALOG),
  # Tool Search nível-1 (P2B-02, task 8): emite <available_tools> de
  # profile.tools_deferred. Inerte p/ agentes sem tools_deferred (retorna []).
  Harness::Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),
  # Memória cross-session (P2C-01, task 4): emite <memory> (facts + notes) de
  # MEMORY_STORE, escopado por tenant. Inerte p/ agentes sem profile.memory
  # (enabled_for? retorna false).
  Harness::Context::Providers::Memory.new(store: MEMORY_STORE),
  Harness::Context::Providers::Session.new(session_store: SESSION_STORE)
].freeze
```
> Ordem não é normativa entre providers inertes-por-omissão (cada um decide
> via `enabled_for?`/retorno vazio) — manter perto do `ToolSearch` só por
> proximidade temática (ambos "opt-in por profile", fatias B/C).

### Passo 3 — Injetar `memory_store:` no `EXECUTOR.new`

**Padrão de referência (codebase) — `EXECUTOR.new` atual (fatia B já injeta
`capability_registry:`/`tool_catalog:`):**
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

Adicionar `memory_store:` à lista de argumentos nomeados (o `Executor` da
task 6 já o aceita com default `nil` — esta task só passa o valor real):
```ruby
EXECUTOR = Harness::Executor.new(
  context_builder: CONTEXT_BUILDER, policy_engine: POLICY_ENGINE,
  middleware: MIDDLEWARE, hooks: HOOKS,
  tool_registry: REGISTRY, skill_catalog: CATALOG, profiles: PROFILES,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  checkpoint_store: CHECKPOINT_STORE, event_stream: EVENT_STREAM,
  workflow_registry: WORKFLOW_REGISTRY, pending_action_store: PENDING_ACTION_STORE,
  capability_registry: CAPABILITY_REGISTRY, tool_catalog: TOOL_CATALOG,
  memory_store: MEMORY_STORE
)
```

### Passo 4 — Estender a tabela D5 (`docs/techspec/00-overview.md`)

**Padrão de referência (codebase) — tabela D5 atual (linhas ~171-189, já com
as 2 linhas da fatia B):**
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
| `:capability_resolved` | `{ capability, chosen, candidates }` | CapabilityRegistry (P2B-01) |
| `:tool_search` | `{ query, matched }` | Tools::ToolSearch (P2B-02) |
| `:done` | `{ content }` | Executor (compat Fase 0) |
| `:error` | `{ message }` | qualquer estágio (compat Fase 0) |
```

Adicionar a linha da fatia 2-C, na mesma posição relativa (antes de
`:done`/`:error`, junto das demais linhas de correlação — referenciando a
fatia de origem, como já é feito para `:capability_resolved`/`:tool_search`):
```markdown
| `:memory_written` | `{ kind, key }` | Tools::Remember (P2C) |
```

Logo abaixo da tabela, no parágrafo que já remete à fatia 2-B, acrescentar
uma frase curta remetendo também à fatia 2-C (mesma disciplina — para quem
ler só o doc de Fase 1 saber que o catálogo foi estendido de novo e onde):
```markdown
A fatia 2-C (`phase2c/P2C-02-remember-tool-and-wiring.md`) estendeu este
catálogo com `:memory_written` — `kind` é `"fact"` ou `"note"`, `key` é a
chave do fato ou o id da note.
```

### Passo 5 — Doc-comment do `Event` (`lib/harness/event.rb`)

**Padrão de referência (codebase) — doc-comment atual (já menciona a
extensão da fatia B):**
```ruby
module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela; estendido pela
  # fatia 2-B com :capability_resolved/:tool_search, doc D7 de
  # phase2b/00-overview.md).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
```

Trocar só a primeira linha do comentário (o `Data.define` e o resto não
mudam — `Event` continua sem validar tipo contra allowlist, é PORO puro; o
fechamento do catálogo é disciplina de doc, não código):
```ruby
module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela; estendido
  # pela fatia 2-B com :capability_resolved/:tool_search (doc D7 de
  # phase2b/00-overview.md) e pela fatia 2-C com :memory_written (doc
  # P2C-02-remember-tool-and-wiring.md).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
```

## Edge cases

- `MEMORY_STORE` construído sobre `BACKEND` (não backend próprio): se
  `HARNESS_DB` não estiver setado, memória é efêmera (`Stores::Memory`) —
  mesma degradação de dev que os demais stores de domínio já têm; produção
  DEVE setar `HARNESS_DB` para memória sobreviver a restart (mesmo critério
  de durabilidade do doc 00 §6, nada novo desta task).
- `Context::Providers::Memory` registrado globalmente, mas gated por
  `enabled_for?(profile) = !!profile.memory` (task 4) — agentes sem `memory`
  no profile (`nil`, default) não recebem `<memory>` no contexto, paridade
  Fase 1/2-A/2-B por omissão do flag.
- `Executor.new` sem `memory_store:` (specs antigas, smoke antigo em
  `spec/support/smoke/boot_app.rb`) continua funcionando — o kwarg tem
  default `nil` na assinatura da task 6 (paridade: sem memory_store, sem tool
  `remember`, comportamento idêntico ao pré-fatia-C). Esta task NÃO precisa
  tocar `spec/support/smoke/boot_app.rb` — ele fica sem a chave nova de
  propósito, provando a paridade por omissão.
- `MEMORY_STORE` construído depois de `BACKEND` mas independente de
  `REGISTRY`/`CAPABILITY_REGISTRY`/`TOOL_CATALOG` — pode entrar em qualquer
  ordem relativa a esses (não há dependência cruzada), mas entra na seção de
  "Persistência" junto dos demais `*_STORE`, pela mesma lógica de leitura do
  arquivo que a fatia B seguiu para `CAPABILITY_REGISTRY`/`TOOL_CATALOG`.

## Testes

**Arquivo:** `spec/harness/wiring_load_spec.rb` (estende) + revisão manual da
tabela D5

| Cenário | Verificação |
|---|---|
| `MEMORY_STORE` construído | `described_class::MEMORY_STORE` é um `Harness::MemoryStore` |
| `CONTEXT_PROVIDERS` inclui `Memory` | `described_class::CONTEXT_PROVIDERS` inclui `a_kind_of(Harness::Context::Providers::Memory)` |
| `EXECUTOR` aceita `memory_store:` | `described_class::EXECUTOR` é um `Harness::Executor` (constrói sem `ArgumentError` de keyword ausente/desconhecida) |
| `docs/techspec/00-overview.md` | revisão manual: tabela D5 tem a linha nova (`:memory_written`); nenhuma linha antiga removida/alterada |
| `lib/harness/event.rb` | revisão manual: doc-comment menciona a extensão da fatia 2-C; `Event = Data.define(...)` byte-a-byte inalterado (só comentário muda) |

## Definition of Done

- [ ] `MEMORY_STORE` construído em `config/wiring.rb` sobre `BACKEND`, ao lado
      dos demais stores de domínio
- [ ] `Context::Providers::Memory.new(store: MEMORY_STORE)` acrescentado a
      `CONTEXT_PROVIDERS`
- [ ] `EXECUTOR.new` recebe `memory_store: MEMORY_STORE`
- [ ] Tabela D5 de `docs/techspec/00-overview.md` com a linha nova
      (`:memory_written`) + frase de remissão à fatia 2-C
- [ ] Doc-comment de `lib/harness/event.rb` atualizado (fatia 2-B e 2-C)
- [ ] `spec/harness/wiring_load_spec.rb` estendido com os 3 cenários novos
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task é 100% wiring + documentação — nenhuma classe nova, nenhum
  método novo. Toda a lógica (`MemoryStore#get_fact`/`#add_note`,
  `Context::Providers::Memory#call`, `Tools::Remember#execute` + emissão de
  `:memory_written`) já foi entregue pelas tasks 1, 4 e 5; aqui só se
  registra o contrato e se liga o fio. Complexity Low é fiel a isso — se esta
  task crescer código de negócio, algo foi mal decomposto nas tasks
  anteriores.
- Fecha a fatia C junto da task 8 (smoke E2E) — depois desta task, os quatro
  critérios do §Smoke E2E do P2C-02 (fato na sessão 1, lembrar na sessão 2,
  note, paridade `memory:nil`) já têm todo o fio ligado ponta a ponta no
  composition root real.
</content>
</invoke>
