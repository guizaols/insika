# Task 06 (P2C): Executor — cabeia `remember` de sistema (gate memory)

> **Techspec:** [P2C-02-remember-tool-and-wiring.md](../P2C-02-remember-tool-and-wiring.md) (§Integração no Executor, L2) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Med · **Etapa:** B

## Objetivo

Fechar, no `Executor`, o ponto onde `Tools::Remember` (task 5) de fato entra
em produção: o `configure_chat` (estágio 5) — o mesmo lugar onde `load_skill`
(Fase 0) e `tool_search` (P2B-02) já são cabeados como tools de SISTEMA, fora
da allowlist da Resolution. Sem esta task, `Tools::Remember` existe testada
isoladamente mas nunca chega a `chat.tools` num turno real — o agente nunca
consegue chamar `remember`, mesmo com `MemoryStore` (task 1) e
`AgentProfile.memory` (task 2) já mesclados.

Três mudanças, todas em `lib/harness/executor.rb`:

1. Construtor ganha `memory_store: nil` → `@memory_store` (mesmo padrão de
   `tool_catalog: nil`/`capability_registry: nil`: campo opcional, default
   `nil` = sem memória, paridade Fase 1).
2. `create_chat` ganha `require_relative "tools/remember"` lazy, ao lado do
   `load_skill`/`tool_search` já existentes.
3. `configure_chat` cabeia `Tools::Remember` como tool de SISTEMA — nunca
   envelopada — quando **ambos** `@memory_store` (presente) E
   `state.profile.memory` (truthy) valem. Gate duplo, não um único
   interruptor: cada metade cobre um jeito diferente de "memória desligada"
   (processo sem `MEMORY_STORE` wireado vs. agente que não optou por
   `memory: true`).

Esta task **não** cria `Tools::Remember` (task 5), não popula `state.tenant`
(task 3) e não toca `config/wiring.rb` (task 7) — só liga os três pontos já
existentes no estágio 5.

## Dependências

| Task | Componente | Necessário para |
|---|---|---|
| [Task 03](./task-03.md) | `state.tenant` (`Executor::ContextRequest`/`run_pipeline`) | o tenant que esta task passa ao construtor de `Tools::Remember`; task 6 só LÊ `state.tenant`, não o calcula |
| [Task 05](./task-05.md) | `Tools::Remember` (builtin) | a tool de sistema que esta task instancia dentro de `configure_chat` |

## Contexto

### Onde isso mora no estágio 5

`configure_chat(chat, state)` já é, desde a Fase 0 e reforçado pelo P2B
(Tool Search), o único lugar do Executor que decide o que entra em
`chat.tools` — e já segue uma disciplina clara para tools de sistema: elas
NÃO passam pela `Resolution` da Policy (estágio 3), NÃO são envelopadas
(`ToolEnvelope`, side-effect/timeout/skip), e são instanciadas direto dentro
do próprio `configure_chat`, empurradas no array `tools` antes do
`chat.with_tools(*tools)` final. `load_skill` faz isso desde a Fase 0;
`tool_search` (P2B-02, task 10 da fatia B) fez o mesmo, ao lado do
`load_skill`, condicionado a `@tool_catalog` presente. `remember` é o
terceiro membro dessa família — mesma disciplina, gate próprio.

O gate duplo desta task (`@memory_store && state.profile.memory`) espelha
**estruturalmente** o gate do Tool Search (`@tool_catalog` + interseção com
`profile.tools_deferred`): dois interruptores independentes, ambos
"desligado por padrão", e só quando AMBOS estão ligados é que a tool de
sistema aparece em `chat.tools`. A diferença é que aqui não há partição
eager/deferred nem interseção com `allowed_tools` — é um flag booleano
simples (`profile.memory`, task 2) cruzado com a presença do colaborador
injetado (`@memory_store`, este passo). Nenhuma lógica de particionamento é
necessária porque `remember` nunca esteve em `allowed_tools`: como
`load_skill`/`tool_search`, ela nasce fora da Resolution.

### `require_relative` lazy em `create_chat`, não em `lib/harness.rb`

`create_chat` é o único método do Executor que hoje já requer a gem
`ruby_llm` (D9 — "este arquivo NÃO requer ruby_llm em load-time", comentário
de topo do arquivo). `Tools::Remember < RubyLLM::Tool` (task 5) exige a gem
carregada para a classe existir — por isso o `require_relative` entra aqui,
lazy, na mesma linha de raciocínio que já vale para `tools/load_skill` e
`tools/tool_search`. Carregar o arquivo não cabeia nada por si — só a
instanciação condicional dentro de `configure_chat` decide se `Remember`
entra no chat de um turno específico.

### `state.tenant` é lido, não calculado, aqui

A task 3 já resolve `state.tenant = command_tenant(task)` dentro de
`run_pipeline`, antes do estágio 5 rodar — pelo tempo em que `configure_chat`
executa, `state.tenant` já existe (string, possivelmente `"_default"` pelo
fallback da task 3). Esta task só repassa esse valor ao construtor de
`Tools::Remember.new(@memory_store, state.tenant, event_stream:, state:)` —
não recalcula tenant, não conhece `command_tenant`, não lê `task` para tirar
tenant por conta própria.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/executor.rb` | MODIFY | construtor ganha `memory_store: nil`; `create_chat` ganha o `require_relative` lazy de `tools/remember`; `configure_chat` cabeia `Tools::Remember` de sistema sob o gate duplo |
| `spec/harness/executor_chat_spec.rb` | MODIFY | cobertura do gate duplo, paridade Fase 1 (qualquer metade ausente = sem `remember`), `Remember` nunca envelopada, tenant repassado corretamente |

## Passo a passo

### Passo 1 — construtor: novo `memory_store: nil`

**Padrão de referência (codebase) — construtor atual
(`lib/harness/executor.rb:16-44`, já com `capability_registry`/`tool_catalog`
mesclados pelas fatias P2B):**

```ruby
def initialize(context_builder:, policy_engine:, middleware:, hooks:,
               tool_registry:, skill_catalog:, profiles:,
               session_store:, task_store:, checkpoint_store:,
               event_stream:, workflow_registry: nil, pending_action_store: nil,
               capability_registry: nil, tool_catalog: nil)
  @context_builder = context_builder
  @policy_engine = policy_engine
  @middleware = middleware
  @hooks = hooks
  @tool_registry = tool_registry
  @skill_catalog = skill_catalog
  @profiles = profiles
  @session_store = session_store
  @task_store = task_store
  @checkpoint_store = checkpoint_store
  @event_stream = event_stream
  @workflow_registry = workflow_registry # estágio 6 do trigger_workflow (task 23)
  @pending_action_store = pending_action_store # gate de aprovação (P2-02)
  @capability_registry = capability_registry # resolução de capability (P2B, nil = desligado)
  # Tool Search (P2B-02): ToolCatalog opcional. nil = nenhuma tool deferred é
  # particionada, mesmo que um profile declare `tools_deferred` — paridade
  # Fase 1/2-A (todo wiring existente cabeia 100% eager, L2).
  @tool_catalog = tool_catalog
  @running = {}            # task_id => TaskActor (fibers vivos neste processo)
  @seqs = Hash.new(0)      # contador monotônico por task (D5)
  @supervised = false      # modo serving? (L4) — ver #turn_parent
  @supervisor = nil        # supervisor lazy de vida-longa (criado no serving)
  @session_actors = {}     # session_id => SessionActor (fila FIFO, P2-03)
end
```

**Depois** — mesmo padrão de `tool_catalog`: campo opcional, default `nil`,
comentário inline de paridade:

```ruby
def initialize(context_builder:, policy_engine:, middleware:, hooks:,
               tool_registry:, skill_catalog:, profiles:,
               session_store:, task_store:, checkpoint_store:,
               event_stream:, workflow_registry: nil, pending_action_store: nil,
               capability_registry: nil, tool_catalog: nil, memory_store: nil)
  @context_builder = context_builder
  @policy_engine = policy_engine
  @middleware = middleware
  @hooks = hooks
  @tool_registry = tool_registry
  @skill_catalog = skill_catalog
  @profiles = profiles
  @session_store = session_store
  @task_store = task_store
  @checkpoint_store = checkpoint_store
  @event_stream = event_stream
  @workflow_registry = workflow_registry # estágio 6 do trigger_workflow (task 23)
  @pending_action_store = pending_action_store # gate de aprovação (P2-02)
  @capability_registry = capability_registry # resolução de capability (P2B, nil = desligado)
  # Tool Search (P2B-02): ToolCatalog opcional. nil = nenhuma tool deferred é
  # particionada, mesmo que um profile declare `tools_deferred` — paridade
  # Fase 1/2-A (todo wiring existente cabeia 100% eager, L2).
  @tool_catalog = tool_catalog
  # Memória cross-session (P2C): MemoryStore opcional. nil = `remember` nunca
  # é cabeada, mesmo que `profile.memory` seja true — paridade Fase 1/2-A/2-B
  # (todo wiring existente até a task 7 continua sem memória). Gate duplo com
  # `state.profile.memory` em #configure_chat.
  @memory_store = memory_store
  @running = {}            # task_id => TaskActor (fibers vivos neste processo)
  @seqs = Hash.new(0)      # contador monotônico por task (D5)
  @supervised = false      # modo serving? (L4) — ver #turn_parent
  @supervisor = nil        # supervisor lazy de vida-longa (criado no serving)
  @session_actors = {}     # session_id => SessionActor (fila FIFO, P2-03)
end
```

Não adicionar `attr_reader :memory_store` — mesma disciplina de
`@tool_catalog`/`@tool_registry`/`@skill_catalog`: estado interno, só
consultado dentro do próprio Executor.

### Passo 2 — `create_chat`: require lazy do builtin

**Padrão de referência (codebase) — `create_chat` atual
(`lib/harness/executor.rb:659-668`):**

```ruby
def create_chat(profile)
  require "ruby_llm"
  require_relative "tools/load_skill"
  require_relative "tools/tool_search" # P2B: builtin de Tool Search (lazy, como load_skill)
  RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )
end
```

**Depois:**

```ruby
def create_chat(profile)
  require "ruby_llm"
  require_relative "tools/load_skill"
  require_relative "tools/tool_search" # P2B: builtin de Tool Search (lazy, como load_skill)
  require_relative "tools/remember" # P2C: builtin de memória (lazy, como load_skill/tool_search)
  RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )
end
```

Require incondicional (sempre roda, independente do gate) — mesma disciplina
de `load_skill`/`tool_search`: carregar o arquivo não cabeia nada; só a
instanciação em `configure_chat` decide se `Remember` entra no chat.

### Passo 3 — `configure_chat`: cabeia `Remember` sob o gate duplo

**Padrão de referência (codebase) — `configure_chat` atual
(`lib/harness/executor.rb:672-710`):**

```ruby
def configure_chat(chat, state)
  system = state.context.system.to_s
  chat.with_instructions(system) unless system.empty?

  tools = Array(state.allowed_tools).dup

  # Tool Search (P2B-02, L1/L2/L6): a partição SÓ roda com @tool_catalog
  # presente (paridade Fase 1 quando nil — o `&&` curto-circuita ANTES de
  # ler `.name`, então specs que passam Object.new como tool sem tool_catalog
  # seguem intocadas). `deferred_allowed` = SEMPRE allowed_tools ∩
  # tools_deferred (L1: decide QUANDO cabear, nunca SE). O catálogo
  # <available_tools> vem do Context::Providers::ToolSearch (estágio 2, task
  # 8) — configure_chat NÃO monta prompt (RFC-0005 §1); só decide chat.tools.
  deferred_allowed = if @tool_catalog
                       Array(state.profile.tools_deferred).map(&:to_s) &
                         tools.map { |t| t.name.to_s }
                     else
                       []
                     end

  unless deferred_allowed.empty?
    tools.reject! { |t| deferred_allowed.include?(t.name.to_s) }
    # tool de SISTEMA (fora da allowlist), como load_skill — nunca envelopada
    # (promove via chat.with_tools dentro do próprio #execute, task 9).
    tools << Tools::ToolSearch.new(@tool_catalog, deferred_allowed, chat,
                                   tool_registry: @tool_registry,
                                   checkpoint_store: @checkpoint_store,
                                   event_stream: @event_stream, state: state)
  end

  # load_skill é default de SISTEMA (fora da allowlist), senão o progressive
  # disclosure quebra — comportamento preservado da Fase 0. allowed_skills
  # vem da RESOLUTION (policy), não do provider de contexto.
  skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
  tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?
  chat.with_tools(*tools) unless tools.empty?

  chat
end
```

**Depois** — o bloco de `remember` entra depois do `load_skill`, mesma
posição relativa (fim da lista de tools de sistema), antes do
`chat.with_tools(*tools)` final:

```ruby
def configure_chat(chat, state)
  system = state.context.system.to_s
  chat.with_instructions(system) unless system.empty?

  tools = Array(state.allowed_tools).dup

  # Tool Search (P2B-02, L1/L2/L6): a partição SÓ roda com @tool_catalog
  # presente (paridade Fase 1 quando nil — o `&&` curto-circuita ANTES de
  # ler `.name`, então specs que passam Object.new como tool sem tool_catalog
  # seguem intocadas). `deferred_allowed` = SEMPRE allowed_tools ∩
  # tools_deferred (L1: decide QUANDO cabear, nunca SE). O catálogo
  # <available_tools> vem do Context::Providers::ToolSearch (estágio 2, task
  # 8) — configure_chat NÃO monta prompt (RFC-0005 §1); só decide chat.tools.
  deferred_allowed = if @tool_catalog
                       Array(state.profile.tools_deferred).map(&:to_s) &
                         tools.map { |t| t.name.to_s }
                     else
                       []
                     end

  unless deferred_allowed.empty?
    tools.reject! { |t| deferred_allowed.include?(t.name.to_s) }
    # tool de SISTEMA (fora da allowlist), como load_skill — nunca envelopada
    # (promove via chat.with_tools dentro do próprio #execute, task 9).
    tools << Tools::ToolSearch.new(@tool_catalog, deferred_allowed, chat,
                                   tool_registry: @tool_registry,
                                   checkpoint_store: @checkpoint_store,
                                   event_stream: @event_stream, state: state)
  end

  # load_skill é default de SISTEMA (fora da allowlist), senão o progressive
  # disclosure quebra — comportamento preservado da Fase 0. allowed_skills
  # vem da RESOLUTION (policy), não do provider de contexto.
  skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
  tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?

  # Memória cross-session (P2C-02, L2): gate DUPLO — @memory_store presente
  # (colaborador wireado no processo, task 7) E state.profile.memory truthy
  # (opt-in do agente, task 2). Qualquer metade ausente = sem `remember`,
  # paridade Fase 1/2-A/2-B. Tool de SISTEMA (fora da allowlist), como
  # load_skill/tool_search — nunca envelopada (sem side-effect de negócio a
  # checkpointar; ver P2C-02 L2/L5 sobre a limitação de resume de notes).
  # `state.tenant` já foi setado no estágio 3 do run_pipeline (task 3) — esta
  # linha só o repassa, nunca o calcula.
  if @memory_store && state.profile.memory
    tools << Tools::Remember.new(@memory_store, state.tenant,
                                 event_stream: @event_stream, state: state)
  end

  chat.with_tools(*tools) unless tools.empty?

  chat
end
```

Notas de implementação sobre este diff:

- O `if @memory_store && state.profile.memory` entra **depois** do bloco de
  `load_skill`, não antes — ordem sem significado funcional (todas são tools
  de sistema empurradas no mesmo array `tools`, cabeadas juntas no
  `chat.with_tools(*tools)` final), mas manter a ordem de introdução
  histórica (`tool_search` → `load_skill` → `remember`) facilita revisar o
  diff linha a linha sem reordenar contexto não relacionado.
- `@memory_store && state.profile.memory` curto-circuita: se
  `@memory_store` é `nil` (default do construtor), `state.profile.memory`
  **nunca é lido** — logo specs/stubs de `profile` que não respondem a
  `.memory` (ex.: `ProfileStub = Struct.new(:model, :provider, :limits)`, já
  existente no spec file) continuam passando intocados nos testes que não
  passam `memory_store:` ao construir o Executor.
- `Tools::Remember` é instanciada direto e empurrada no array `tools` — não
  passa por `wrap_tools`/`ToolEnvelope`, mesma forma de
  `Tools::LoadSkill.new(...)`/`Tools::ToolSearch.new(...)` já existentes.
- `state.tenant` (task 3) e `state.profile.memory` (task 2) são os dois
  campos externos que esta task só LÊ — nenhum dos dois é calculado ou
  setado por `configure_chat`.

## Edge cases

- **`@memory_store` nil (default do construtor):** `remember` nunca é
  cabeada, mesmo que `state.profile.memory` seja `true` — o `&&`
  curto-circuita antes de ler `.memory`. Paridade Fase 1/2-A/2-B: todo
  wiring existente até a task 7 rodar continua sem memória, byte a byte.
- **`state.profile.memory` nil/false (mesmo com `@memory_store` presente):**
  `remember` não é cabeada — agente que não optou por `memory: true`
  continua sem a tool, mesmo rodando num processo que já tem
  `MEMORY_STORE` wireado (mesma lógica do `tools_deferred` vazio no Tool
  Search: presença do colaborador no processo não implica uso por todo
  agente).
- **Ambos presentes (`@memory_store` truthy E `profile.memory` truthy):**
  `Tools::Remember` entra em `chat.tools`, instância crua (não
  `ToolEnvelope`), recebendo `state.tenant` tal como veio da task 3 (sem
  normalização adicional aqui).
- **`remember` nunca é envelopada:** mesma disciplina de `load_skill`/
  `tool_search` — tool de sistema, sem side-effect de negócio a
  checkpointar (P2C-02 L2). Um teste dedicado garante
  `be_a(Harness::Tools::Remember)` sem `be_a(Harness::ToolEnvelope)`.
- **`state.tenant` vem da task 3, não desta task:** `configure_chat` não
  tem — e não precisa ter — nenhuma lógica de fallback de tenant; se a task
  3 não estiver mesclada, `state.tenant` simplesmente não existe no
  `TurnState`/stub e qualquer teste que exercite o gate ligado precisa do
  stub já atualizado (ver Notas de coordenação).

## Testes

**Arquivo:** `spec/harness/executor_chat_spec.rb`

| Cenário | Expectativa |
|---|---|
| Executor sem `memory_store:` (default), `profile.memory: true` | `chat.tools` não contém `Tools::Remember` — paridade Fase 1 |
| Executor com `memory_store:` fake, `profile.memory` nil/ausente | mesmo resultado acima — sem `Tools::Remember` |
| Executor com `memory_store:` fake, `profile.memory: false` | mesmo resultado acima — sem `Tools::Remember` |
| Executor com `memory_store:` fake, `profile.memory: true`, `state.tenant: "acme"` | `chat.tools` contém uma instância de `Tools::Remember` |
| mesmo cenário acima | a instância de `Tools::Remember` foi construída com `store == @memory_store` do Executor e `tenant == "acme"` (via spy/`expect(Tools::Remember).to receive(:new).with(...)` ou inspeção dos ivars da instância) |
| `Tools::Remember` presente | `chat.tools.grep(Harness::Tools::Remember).first` não é `be_a(Harness::ToolEnvelope)` (nunca envelopada) |
| memory + skills + tool_search juntos (todos os gates ligados) | `chat.tools` contém as três tools de sistema (`Tools::Remember`, `Tools::LoadSkill`, `Tools::ToolSearch`), nenhuma envelopada |
| testes existentes de `#configure_chat` (sem `memory_store:` no Executor) | continuam verdes sem alteração — trava a não-regressão |

Usar um dublê simples para `@memory_store` no Executor construído nestes
testes — só precisa ser um objeto truthy (`configure_chat` nunca chama
método nenhum nele; só repassa a referência a `Tools::Remember.new`), como já
é feito para `@tool_catalog` nos testes de Tool Search
(`instance_double("Harness::ToolCatalog")` sem stubs, ou `Object.new`). O
`State` Struct do spec file (`State = Struct.new(:context, :allowed_tools,
:allowed_skills, :profile, :task, :current_tool_call, keyword_init: true)`)
precisa já ter ganhado `:tenant` pela task 3 — esta task não adiciona esse
campo ao stub, só o consome nos novos testes.

## Definition of Done

- [ ] Construtor aceita `memory_store: nil` (default) sem quebrar nenhum
      call site existente (todos usam kwargs)
- [ ] `create_chat` ganha `require_relative "tools/remember"` lazy
- [ ] `configure_chat` cabeia `Tools::Remember` como tool de sistema (fora
      da allowlist, nunca envelopada) só quando `@memory_store` presente E
      `state.profile.memory` truthy
- [ ] `Tools::Remember` recebe `@memory_store`, `state.tenant`,
      `event_stream: @event_stream` e `state: state` — mesma assinatura da
      task 5
- [ ] Paridade Fase 1 comprovada em teste: `memory_store: nil` OU
      `profile.memory` nil/false → comportamento idêntico ao pré-existente
- [ ] Testes existentes de `#configure_chat` (Tool Search, LoadSkill,
      Resolution) continuam verdes sem modificação
- [ ] Suíte verde sem chave de API (RubyLLM mockado na integração)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**COORDENAÇÃO DE ARQUIVO COMPARTILHADO:** a task 3 também edita
`executor.rb` — ela mexe em `build_context_request`/`run_pipeline` e no
`Struct ContextRequest` (threading de `tenant`, estágios 1-3), em áreas
DISTINTAS do `create_chat`/`configure_chat` que esta task (6) edita. A
`tasks.md` já registra esta colisão explicitamente: "task 3 edita
`build_context_request`/`run_pipeline` (tenant) e o Struct `ContextRequest`;
task 6 edita `configure_chat`/`create_chat`. Áreas distintas — sequenciar 3
antes de 6 (a task 6 lê `state.tenant` que a task 3 seta)." Sem a task 3
mesclada primeiro, `state.tenant` simplesmente não existe — esta task não
tem como ser testada de ponta a ponta (gate ligado) sem essa dependência já
resolvida, embora o diff em si (constructor/create_chat/configure_chat) não
toque nenhuma linha que a task 3 também toca.

**`Tools::Remember` (task 5) é pré-requisito de código, não só de spec:**
diferente da task 3 (colisão de arquivo, sem dependência de símbolo), a task
5 precisa estar mesclada porque `configure_chat` referencia a constante
`Tools::Remember` diretamente — sem o arquivo `lib/harness/tools/remember.rb`
existir, o `require_relative` do Passo 2 falha e a classe não existe para o
Passo 3 instanciar.

**Wiring fora de escopo:** esta task não toca `config/wiring.rb` — o
`EXECUTOR = Harness::Executor.new(...)` real ganha `memory_store:
MEMORY_STORE` na task 7 (junto do `Context::Providers::Memory` em
`CONTEXT_PROVIDERS` e do catálogo de eventos D8 para `:memory_written`). Até
lá, o `@memory_store` do Executor em produção continua `nil` (paridade Fase
1 intacta) mesmo depois desta task mesclada — só specs que instanciam o
Executor diretamente com `memory_store:` exercitam o caminho novo.
