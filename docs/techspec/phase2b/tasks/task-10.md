# Task 10 (P2B): Executor — partição eager/deferred + Tool Search de sistema

> **Techspec:** [P2B-02-tool-search.md](../P2B-02-tool-search.md) (§Integração, L1/L2/L5/L6) · [00-overview.md](../00-overview.md) (D5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Fechar o Tool Search no ponto onde ele de fato entra em produção: o
`configure_chat` do Executor (estágio 5). É aqui — e só aqui — que o Executor
tem, ao mesmo tempo, a `Resolution` da Policy (`state.allowed_tools`, estágio
3) e a allowlist declarada no perfil (`profile.tools_deferred`, task 7). Sem
esta task, `ToolCatalog` (task 6), `AgentProfile.tools_deferred` (task 7) e o
builtin `Tools::ToolSearch` (task 9) existem isolados, testados, mas **nunca
são cabeados num turno real** — o Executor continua cabeando 100% das
`allowed_tools` eager, exatamente como a Fase 1.

Esta task faz **duas** coisas no `configure_chat` — e nunca uma terceira que
injete texto de prompt:

1. Particiona `state.allowed_tools` em **eager** (cabeadas de cara,
   `chat.with_tools`) e **deferred** (fora do chat inicial), usando
   `allowed_tools_names ∩ profile.tools_deferred`.
2. Adiciona `Tools::ToolSearch` como tool de **sistema** (fora da allowlist,
   ao lado do `LoadSkill` — L6) quando há deferred permitido, para que o
   modelo possa promover uma tool deferred a `chat.tools` sob demanda.

O catálogo compacto (`<available_tools>`, name+description) que o modelo lê
**antes** de chamar `tool_search` **não é montado aqui**: é emitido pelo
`Context::Providers::ToolSearch` (task 8), um Context Provider de estágio 2
que lê `profile.tools_deferred` diretamente — mesmo padrão do Skill provider
(RFC-0005 §5, decisão D5 do `00-overview`). `configure_chat` só **cabeia** a
tool; nunca monta prompt (RFC-0005 §1, "o Runtime nunca monta prompt" — é
essa regra constitucional que motivou a reescrita deste doc em relação à
versão anterior, que fazia `configure_chat` concatenar o catálogo ao
`system`).

## Dependências

| Task | Componente | Necessário para |
|---|---|---|
| [Task 06](./task-06.md) | `ToolCatalog` | a instância injetada no construtor do Executor — usada aqui só como **sinalizador de presença** (`if @tool_catalog`); `.subset`/`.format_for_prompt` são chamados por `Tools::ToolSearch` (task 9) e por `Context::Providers::ToolSearch` (task 8), nunca por `configure_chat` |
| [Task 07](./task-07.md) | `AgentProfile.tools_deferred` | a allowlist do perfil que entra na interseção com `allowed_tools` |
| [Task 08](./task-08.md) | `Context::Providers::ToolSearch` | quem emite o fragmento `<available_tools>` no `state.context.system` — esta task pressupõe que ele já chegou pronto (estágio 2 roda antes do 5); não é chamado a partir daqui |
| [Task 09](./task-09.md) | `Tools::ToolSearch` (builtin) | a tool de sistema que promove deferred → `chat.tools` mid-loop |

## Contexto

### Onde isso mora no estágio 5

`run_pipeline` já resolve a Policy no **estágio 3**, antes do estágio 5:

```ruby
state.allowed_tools = wrap_tools(instantiate_tools(resolution.allowed_tools), state, skip)
```

Ou seja, quando `configure_chat(chat, state)` roda, `state.allowed_tools` já é
um array de `ToolEnvelope` (cada um um `SimpleDelegator` sobre a tool real —
`ToolEnvelope#approval_required?`/`#side_effect?` já dependem de
`__getobj__.name`, então a tool por trás de cada envelope **já responde a
`.name`** por contrato existente; não é uma exigência nova desta task). Essa é
a coleção que precisa ser particionada — a partição acontece **depois** da
Policy, nunca antes: `tools_deferred` decide **quando** cabear, nunca **se**
(P2B-02 L1). Uma tool listada em `tools_deferred` que a Policy já negou nunca
chega a `state.allowed_tools` — a interseção `allowed_tools_names ∩
tools_deferred` já a exclui automaticamente, sem lógica extra.

### Paridade Fase 1 quando `@tool_catalog`/`tools_deferred` é `nil`

Dois interruptores independentes, ambos "desligado por padrão":

- **`@tool_catalog` (novo campo do Executor, default `nil`):** se o
  composition root não passou um catálogo (wiring da task 11 ainda não
  existe, ou um agente/ambiente decide não usar Tool Search), a partição
  **nem roda** — todas as `allowed_tools` são cabeadas eager, ponto. Isso
  cobre o caso "Tool Search não está wireado neste processo" sem depender de
  cada `AgentProfile` individual não declarar `tools_deferred`.
- **`profile.tools_deferred` (task 7, default `nil`):** mesmo com
  `@tool_catalog` presente, um perfil que não declara `tools_deferred` (ou
  declara `[]`) produz interseção vazia — tudo eager, sem `ToolSearch`.

Só quando **ambos** estão presentes — `@tool_catalog` setado E
`profile.tools_deferred` com nomes que de fato sobrevivem à Policy — a
partição tem efeito observável em `chat.tools`. Isso é o que a Fase 1/2-A já
garante (nenhum agente existente passa `tools_deferred`, nenhum wiring
existente passa `tool_catalog`) e o que os testes desta task travam.

### O catálogo `<available_tools>` vem do Context Provider (task 8), nunca do `configure_chat`

A versão anterior deste doc tinha `configure_chat` concatenando
`@tool_catalog.format_for_prompt(...)` ao `system` — essa rota foi
abandonada. A reescrita do `P2B-02` (§Integração) e do `00-overview` (D5)
resolveu a "nuance L4" de outro jeito: o recorte exposto no catálogo não
precisa esperar a Resolution (estágio 3) porque **não é**
`allowed_tools ∩ tools_deferred` — é `profile.tools_deferred` puro (∩ tools
registradas), exatamente como o Skill provider usa `profile.skills` (não
`allowed_skills` pós-Policy). Isso deixa o `Context::Providers::ToolSearch`
rodar inteiramente no estágio 2, sem depender de nada que só exista no
estágio 3 e sem o seam `request.vars` que a task 8 usava provisoriamente.

Consequência direta para esta task: `configure_chat` **nunca** toca `system`
para injetar catálogo. Quando `configure_chat` roda (estágio 5),
`state.context.system` já chegou do estágio 2 com o fragmento
`<available_tools>` concatenado — do mesmo jeito que já chega com o fragmento
de skills. `configure_chat` só cabeia a tool `tool_search` (mesmo tratamento
do `load_skill`); montar texto de prompt é problema exclusivo do Context
Provider (RFC-0005 §1).

O catálogo do provider pode ser levemente sobre-inclusivo (mostra um
`tools_deferred` que a Policy depois nega) — aceitável, mesma regra do Skill
provider. O corte real de **autoridade** continua acontecendo aqui, no
`configure_chat`: `deferred_allowed = allowed_tools_names ∩
profile.tools_deferred` é o que decide (a) quais tools saem do `with_tools`
eager e (b) qual allowlist a instância de `Tools::ToolSearch` recebe para a
promoção (P2B-02 L5) — só essa interseção pode ser efetivamente promovida,
mesmo que o catálogo no prompt liste mais.

### Capability é ortogonal (nota, não escopo)

A task 5 (Etapa A, P2B-01) resolve capabilities e as funde em
`resolution.allowed_tools` **antes** do estágio 3 terminar — pelo tempo em
que `configure_chat` roda, uma tool resolvida por capability é indistinguível
de uma tool direta (mesmo `ToolEnvelope`, mesmo `.name`). Esta task não trata
capability como caso especial: se o nome resolvido de uma capability
aparecesse em `profile.tools_deferred`, ela seria deferida como qualquer
outra tool — o techspec (P2B-02 §Integração, último parágrafo) já observa
isso como comportamento esperado nesta fatia ("capability é eager" é a
expectativa de uso, não uma trava de código): nenhum agente desta fatia
declara o nome de uma capability resolvida dentro de `tools_deferred`, então
o caso não surge na prática, mas o código não impede.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/executor.rb` | MODIFY | construtor ganha `tool_catalog: nil`; `configure_chat` particiona eager/deferred e adiciona `Tools::ToolSearch` de sistema (sem tocar `system`); `create_chat` ganha o `require_relative` lazy |
| `spec/harness/executor_chat_spec.rb` | MODIFY | cobertura da partição, paridade Fase 1, `ToolSearch` nunca envelopada, `deferred_allowed` correto passado ao `ToolSearch` |

## Passo a passo

### Passo 1 — construtor: novo `tool_catalog: nil`

**Padrão de referência (codebase) — construtor atual (`lib/harness/executor.rb:16-38`):**

```ruby
def initialize(context_builder:, policy_engine:, middleware:, hooks:,
               tool_registry:, skill_catalog:, profiles:,
               session_store:, task_store:, checkpoint_store:,
               event_stream:, workflow_registry: nil, pending_action_store: nil)
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
  @workflow_registry = workflow_registry
  @pending_action_store = pending_action_store
  @running = {}
  @seqs = Hash.new(0)
  @supervised = false
  @supervisor = nil
  @session_actors = {}
end
```

**Depois** — mesmo padrão de `workflow_registry`/`pending_action_store`
(campo opcional, default `nil`, comentário inline de paridade):

```ruby
def initialize(context_builder:, policy_engine:, middleware:, hooks:,
               tool_registry:, skill_catalog:, profiles:,
               session_store:, task_store:, checkpoint_store:,
               event_stream:, workflow_registry: nil, pending_action_store: nil,
               tool_catalog: nil)
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
  @workflow_registry = workflow_registry
  @pending_action_store = pending_action_store
  # Tool Search (P2B-02): ToolCatalog opcional. nil = nenhuma tool deferred é
  # particionada, mesmo que um profile declare `tools_deferred` — paridade
  # Fase 1/2-A (todo wiring existente continua cabeando 100% eager, L2).
  @tool_catalog = tool_catalog
  @running = {}
  @seqs = Hash.new(0)
  @supervised = false
  @supervisor = nil
  @session_actors = {}
end
```

Não adicionar `attr_reader :tool_catalog` — mesma disciplina dos outros
colaboradores injetados (`@tool_registry`, `@skill_catalog` etc. também não
têm reader público); é estado interno, só usado dentro do próprio Executor.

### Passo 2 — `create_chat`: require lazy do builtin

**Padrão de referência (codebase) — `create_chat` atual:**

```ruby
def create_chat(profile)
  require "ruby_llm"
  require_relative "tools/load_skill"
  RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )
end
```

**Depois** — mesma disciplina de `load_skill` (require sempre, incondicional;
carregar o arquivo não cabeia nada — só a instanciação em `configure_chat`
decide se `ToolSearch` entra no chat):

```ruby
def create_chat(profile)
  require "ruby_llm"
  require_relative "tools/load_skill"
  require_relative "tools/tool_search"
  RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )
end
```

`Tools::ToolSearch < RubyLLM::Tool` (task 9) exige a gem carregada — por isso
o require lazy aqui, nunca em `lib/harness.rb` (D9, mesma razão do
`load_skill`).

### Passo 3 — `configure_chat`: partição + tool de sistema (sem tocar `system`)

**Padrão de referência (codebase) — `configure_chat` atual:**

```ruby
def configure_chat(chat, state)
  system = state.context.system.to_s
  chat.with_instructions(system) unless system.empty?

  # load_skill é default de SISTEMA (fora da allowlist), senão o progressive
  # disclosure quebra — comportamento preservado da Fase 0. allowed_skills
  # vem da RESOLUTION (policy), não do provider de contexto.
  tools = Array(state.allowed_tools).dup
  skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
  tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?
  chat.with_tools(*tools) unless tools.empty?

  chat
end
```

**Depois:**

```ruby
def configure_chat(chat, state)
  system = state.context.system.to_s
  chat.with_instructions(system) unless system.empty?

  tools = Array(state.allowed_tools).dup

  # Tool Search (P2B-02, L1/L2/L6): a partição SÓ roda com @tool_catalog
  # presente (paridade Fase 1 quando nil — o `&&` curto-circuita ANTES de
  # chamar `.name` em qualquer tool, então specs que passam Object.new como
  # tool [sem @tool_catalog no Executor] continuam passando intocadas).
  # `deferred_allowed` é SEMPRE allowed_tools ∩ tools_deferred — nunca o
  # tools_deferred isolado (L1: decide QUANDO cabear, nunca SE). O catálogo
  # <available_tools> que o modelo já leu no `system` (acima) vem do
  # Context::Providers::ToolSearch (estágio 2, task 8) — configure_chat NÃO
  # monta prompt (RFC-0005 §1); só decide o que entra em chat.tools.
  deferred_allowed = if @tool_catalog
                       Array(state.profile.tools_deferred).map(&:to_s) &
                         tools.map { |t| t.name.to_s }
                     else
                       []
                     end

  unless deferred_allowed.empty?
    tools.reject! { |t| deferred_allowed.include?(t.name.to_s) }

    # tool_search é tool de SISTEMA (fora da allowlist), como load_skill —
    # nunca envelopada (sem side-effect, latência trivial, mesma regra do
    # load_skill — ver comentário de wrap_tools). Promove via chat.with_tools
    # dentro do próprio #execute (task 9); aqui só a instanciamos.
    # checkpoint_store: é necessário porque a tool embrulha cada match
    # promovido em ToolEnvelope (mesma wrap dos eager, P2B-02 L5) antes de
    # chat.with_tools — sem ele a promoção mid-loop não teria timeout/registro
    # de side-effect.
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

Notas de implementação sobre este diff:

- `chat.with_instructions(system)` **permanece na mesma posição** da versão
  pré-existente (logo no topo, antes de `tools`) — diferente da versão
  anterior deste doc, que deslocava a chamada para depois do bloco de
  deferred para poder concatenar o catálogo. Não há mais concatenação
  nenhuma: `system` não é mexido em lugar algum de `configure_chat`.
- `tools.reject!` só executa dentro do `unless deferred_allowed.empty?` — se
  a partição não roda (`@tool_catalog` nil, ou interseção vazia), `tools`
  nunca invoca `.name` em nenhum elemento. Isso preserva 100% o teste
  existente `"usa as tools da Resolution (instâncias prontas)"`
  (`t1 = Object.new`, `t2 = Object.new`) porque esse teste não passa
  `tool_catalog:` ao construir o Executor.
- `ToolSearch` é adicionada ao array `tools` **depois** do `reject!` (não
  passa pelo `wrap_tools`/`ToolEnvelope` — instanciada direta, mesma forma do
  `Tools::LoadSkill.new(...)` já existente logo abaixo).
- `@tool_catalog` é passado ao construtor de `Tools::ToolSearch` só como
  referência — `configure_chat` nunca chama `.subset`/`.format_for_prompt`
  nele; quem chama esses métodos é `Tools::ToolSearch#execute` (task 9) e
  `Context::Providers::ToolSearch#call` (task 8), cada um no seu próprio
  arquivo.

## Edge cases

- **`@tool_catalog` nil (default do construtor):** a partição inteira é
  pulada (`deferred_allowed = []`) — nenhuma tool é lida por `.name`, nenhum
  `ToolSearch` é criado. Comportamento idêntico, byte a byte, à Fase 1/2-A no
  que toca a `configure_chat`. (O `Context::Providers::ToolSearch`, task 8,
  resolve seu próprio caso nil-safe de forma independente, no estágio 2 —
  fora do escopo desta task.) Este é o caso de todo wiring existente até a
  task 11 rodar.
- **`profile.tools_deferred` nil ou `[]` (mesmo com `@tool_catalog` setado):**
  `Array(nil) = []`, interseção com qualquer coisa é `[]` → `deferred_allowed`
  vazio → mesmo caminho do caso acima (tudo eager, sem `ToolSearch`). Cobre o
  agente que ainda não opta por Tool Search mesmo rodando num processo que já
  tem o catálogo wireado.
- **Interseção vazia por a Policy ter negado tudo que estava em
  `tools_deferred`** (ex.: `tools_deferred: ["send_email"]` mas
  `tools_allow`/`tools_deny` já removeu `send_email` de `allowed_tools`):
  `deferred_allowed` vazio pelo mesmo motivo — nenhuma tool "deferida" que a
  Policy negou aparece em lugar nenhum (nem cabeada, nem promovível).
  Autoridade permanece 100% na Policy (L1). O `Context::Providers::
  ToolSearch` pode ainda listar o nome no `<available_tools>` (ele enxerga só
  `profile.tools_deferred`, sem a Policy) — inofensivo, porque a instância de
  `Tools::ToolSearch` construída aqui recebeu `deferred_allowed` vazio e não
  promove nada fora dele (P2B-02 L5).
- **`ToolSearch` nunca é envelopada:** ela é instanciada e empurrada direto
  no array `tools`, no mesmo ponto (e pela mesma razão) que `Tools::LoadSkill`
  — tool de sistema, sem side-effect, latência trivial. Um teste dedicado
  garante que a instância em `chat.tools` é a `Tools::ToolSearch` crua, não
  um `Harness::ToolEnvelope` (`be_a(Harness::Tools::ToolSearch)`, não
  `be_a(Harness::ToolEnvelope)`).
- **`ToolSearch` recebe a interseção correta, não o `tools_deferred` cru:** a
  autoridade de promoção (P2B-02 L1/L5) vem de `deferred_allowed` —
  `allowed_tools ∩ tools_deferred` — nunca de `profile.tools_deferred`
  isolado. Um teste dedicado verifica o argumento passado ao construtor de
  `Tools::ToolSearch` (não só o efeito em `chat.tools`).
- **Capability é eager, ortogonal a esta fatia (nota, não trava de
  código):** uma tool resolvida por capability (task 5) chega a
  `state.allowed_tools` como qualquer outra — se o nome resolvido coincidir
  com uma entrada de `profile.tools_deferred`, ela seria deferida também;
  nenhum cenário desta fatia produz essa colisão, então não há teste
  dedicado, só o registro do comportamento (P2B-02 §Integração, último
  parágrafo).

## Testes

**Arquivo:** `spec/harness/executor_chat_spec.rb`

| Cenário | Expectativa |
|---|---|
| Executor sem `tool_catalog:` (default), profile com `tools_deferred` setado | todas as `allowed_tools` aparecem em `chat.tools` (nada deferido) — paridade Fase 1; nenhum `Tools::ToolSearch` em `chat.tools` |
| Executor com `tool_catalog:` fake, profile **sem** `tools_deferred` (nil) | mesmo resultado acima — tudo eager, sem `ToolSearch` |
| Executor com `tool_catalog:` fake, `tools_deferred: ["b"]`, `allowed_tools: [tool_a, tool_b]` (stubs com `.name`) | `chat.tools` NÃO contém `tool_b`; contém `tool_a` e uma instância de `Tools::ToolSearch` |
| mesmo cenário acima | a instância de `Tools::ToolSearch` foi construída com `deferred_allowed == ["b"]` e `checkpoint_store:` igual ao `@checkpoint_store` do Executor (via spy/`expect(Tools::ToolSearch).to receive(:new).with(...)` ou inspeção dos atributos da instância) |
| `tools_deferred: ["z"]` (nome fora de `allowed_tools` — Policy já negou) | interseção vazia: `chat.tools` não tem `ToolSearch`; nenhuma tool some de `chat.tools` |
| `ToolSearch` presente | `chat.tools.grep(Harness::Tools::ToolSearch).first` não é `be_a(Harness::ToolEnvelope)` (nunca envelopada) |
| deferred + skills juntos (`tools_deferred` não vazio E `allowed_skills` não vazio) | `chat.tools` contém `Tools::ToolSearch` E `Tools::LoadSkill`, ambos de sistema, nenhum envelopado |
| teste existente "usa as tools da Resolution (instâncias prontas)" (`Object.new` como tool, Executor sem `tool_catalog:`) | continua verde sem alteração — trava a não-regressão |

Usar um dublê simples para `@tool_catalog` no `subject(:executor)` — só
precisa ser um objeto truthy: `configure_chat` nunca chama métodos nele
diretamente, só repassa a referência a `Tools::ToolSearch.new`. Um
`instance_double("Harness::ToolCatalog")` sem stubs (ou até um `Object.new`)
já serve; `.subset`/`.format_for_prompt` são exercitados nas specs das tasks
8 e 9, não aqui. Tools de teste precisam responder a `.name` quando
`tool_catalog:` está presente — usar `Struct.new(:name)` ou uma classe local
simples (o `Object.new` do teste de paridade continua válido justamente
porque, nesse cenário, `@tool_catalog` é nil e `.name` nunca é chamado).

## Definition of Done

- [ ] Construtor aceita `tool_catalog: nil` (default) sem quebrar nenhum
      call site existente (todos usam kwargs)
- [ ] `configure_chat` particiona `eager`/`deferred` via
      `allowed_tools_names ∩ profile.tools_deferred`, só quando
      `@tool_catalog` presente
- [ ] `Tools::ToolSearch` adicionada como tool de sistema (fora da
      allowlist, nunca envelopada) quando há deferred permitido, recebendo
      `checkpoint_store: @checkpoint_store`
- [ ] `configure_chat` **não** chama `@tool_catalog.format_for_prompt` (nem
      `.subset`) e não concatena texto ao `system` — o catálogo
      `<available_tools>` é responsabilidade exclusiva do
      `Context::Providers::ToolSearch` (task 8, estágio 2)
- [ ] `create_chat` ganha `require_relative "tools/tool_search"` lazy
- [ ] Paridade Fase 1 comprovada em teste: `tool_catalog: nil` OU
      `tools_deferred: nil/[]` → comportamento idêntico ao pré-existente
- [ ] Teste existente `"usa as tools da Resolution (instâncias prontas)"`
      continua verde sem modificação
- [ ] Suíte verde sem chave de API (RubyLLM mockado na integração)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**COORDENAÇÃO DE ARQUIVO COMPARTILHADO:** a task 5 (Etapa A, P2B-01) também
edita `executor.rb` — ela monta a resolução de capabilities no `run_pipeline`
(resolve por `profile.capabilities`, `rescue :capability`, **join pós-Policy**
com wrap `ResolvedTool` → `ToolEnvelope`), em áreas DISTINTAS do
`configure_chat` que esta task (10) edita. Menos sobreposição do que a versão
anterior sugeria (a task 5 não injeta capability em `configure_chat`), mas
como as duas tocam o mesmo arquivo, a
`tasks.md` já registra esta colisão explicitamente ("Etapa A e B são
independentes... mas `executor.rb`/`configure_chat` — tasks 5 e 10 o
editam. Sequenciar 5 antes de 10, ou fazer o rebase/merge com atenção ao
`configure_chat`"). Recomendação: **mesclar a task 5 primeiro**; esta task
(10) parte do `configure_chat` já com capability integrada e só adiciona o
bloco de partição eager/deferred. Se a ordem inverter na prática, quem
mesclar por último resolve o conflito manualmente — os dois blocos (merge de
capability em `state.allowed_tools` antes da Policy vs. partição
eager/deferred dentro de `configure_chat`) não se sobrepõem semanticamente,
só ficam fisicamente próximos no arquivo.

**Wiring fora de escopo:** esta task não toca `config/wiring.rb` — o
`EXECUTOR = Harness::Executor.new(...)` real ganha `tool_catalog:` na task
11 (junto do `TOOL_CATALOG` novo e do catálogo de eventos D5); o
`CONTEXT_PROVIDERS` que passa a incluir `Context::Providers::ToolSearch`
também é wiring de outra task. Até lá, o `@tool_catalog` do Executor em
produção continua `nil` (paridade Fase 1 intacta) mesmo depois desta task
mesclada — só specs que instanciam o Executor diretamente com
`tool_catalog:` exercitam o caminho novo.

**`Context::Providers::ToolSearch` (task 8) é ATIVO em produção, não
preparado-mas-inerte:** a versão anterior deste doc registrava o provider
como "preparado mas nunca populado" porque dependia do seam
`request.vars[:deferred_tool_names]`, só disponível pós-Policy. A reescrita
do `P2B-02`/`00-overview` (D5) trocou esse recorte por `profile.tools_deferred`
puro (conhecido já no estágio 2, igual ao Skill provider com
`profile.skills`) — eliminando a dependência do seam. Esta task (10) não
altera o provider; só deixa de fazer o trabalho que a versão anterior deste
doc atribuía a `configure_chat` (montar e injetar o catálogo), porque essa
responsabilidade nunca foi dele — é do Context Provider, por construção
(RFC-0005 §1).
