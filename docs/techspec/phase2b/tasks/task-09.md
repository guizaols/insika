# Task 09 (P2B): `Tools::ToolSearch` — busca + promoção mid-loop

> **Techspec:** [P2B-02-tool-search.md](../P2B-02-tool-search.md) (D6, L5, L6, §Riscos) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** B

## Objetivo

Criar a builtin `Tools::ToolSearch`: o nível 2 do progressive disclosure de
tools (RFC-0005 §5), espelhando `Tools::LoadSkill`. Um agente com
`tools_deferred` vê só um catálogo compacto (name+description) no system
prompt (task 8); quando o modelo precisa de uma dessas tools, chama
`tool_search(query: "...")`, que:

1. busca no `ToolCatalog` (matcher puro, task 6) restrito ao que este agente
   pode ver (`deferred_allowed`);
2. instancia os matches via `tool_registry`, embrulha cada um no MESMO
   `ToolEnvelope` que as tools eager recebem, e chama `chat.with_tools(*wrapped)`
   — a **promoção mid-loop** (D6): sem isso, `chat.tools` nunca ganha as
   deferred e o progressive disclosure de tools não passa do catálogo;
3. emite `:tool_search { query, matched }` (auditoria — análogo a
   `:skill_activated`);
4. devolve ao modelo name+description+parâmetros dos matches, para que ele
   monte a chamada real na rodada seguinte.

Esta é a task mais arriscada da fatia (tasks.md, "Concerns a sinalizar" #1):
a promoção só funciona se `chat.with_tools`, chamado DENTRO de um `execute` de
tool, afetar a rodada **seguinte do MESMO** `chat.ask` — não um `ask` futuro.
Ver §Riscos do P2B-02 e a `## Notas` abaixo, onde esse comportamento é
**verificado contra o `ruby_llm` 1.16.0 realmente instalado neste projeto**
(não é só uma leitura do código-fonte — foi executado).

## Dependências

| Task | Componente | Motivo |
|---|---|---|
| Task 06 | `ToolCatalog` | fornece `search(query, within:)` — o matcher puro que esta tool consulta. Sem catálogo não há o que buscar nem o que instanciar via nome. |

Não depende das tasks 7/8/10: `tools_deferred` no `AgentProfile` (7) e a
injeção do catálogo no system (8) são consumidores desta classe, não
pré-requisitos para escrevê-la e testá-la isoladamente (os specs desta task
usam um `deferred_allowed` literal, sem precisar do profile real). A
integração de verdade (instanciar `Tools::ToolSearch` dentro de
`configure_chat`) é a task 10.

## Contexto

### Nível 2 do progressive disclosure, mesmo padrão de `LoadSkill`

`Tools::LoadSkill` (Fase 0, migrada intacta) já resolveu esse problema para
skills: nível 1 = name+description no system; nível 2 = uma tool de sistema
que carrega o corpo sob demanda, respeitando uma allowlist recebida no
construtor. `Tools::ToolSearch` é o mesmo padrão, mas em vez de "carregar
texto" ela "habilita uma tool" — e por isso precisa mexer no `chat` vivo
(`LoadSkill` só lê o `catalog`; nunca toca o `chat`).

### D6 — por que `chat.with_tools` dentro de `execute` funciona (verificado)

O ciclo de tool-use do `ruby_llm` (não reimplementado aqui — "RubyLLM First")
está em `RubyLLM::Chat` (gem 1.16.0, instalada em
`ruby_llm-1.16.0/lib/ruby_llm/chat.rb`):

```ruby
# lib/ruby_llm/chat.rb (gem 1.16.0) — trecho relevante, NÃO editar/copiar p/ o
# projeto; só para embasar por que D6 é seguro.
def handle_tool_calls(response, &)
  halt_result = if concurrency
                  handle_concurrent_tool_calls(response.tool_calls)
                else
                  handle_sequential_tool_calls(response.tool_calls)
                end

  reset_tool_choice if forced_tool_choice?
  halt_result || complete(&)   # <-- relê @tools DEPOIS de todo tool_call já executado
end

def with_tool(tool, choice: nil, calls: nil, concurrency: @concurrency)
  # ...
  @tools[tool_instance.name.to_sym] = tool_instance   # <-- Hash MUTADO in-place
  # ...
end
```

`@tools` é um `Hash` de instância mutado diretamente por `with_tool`
(chamado por `with_tools`). `handle_tool_calls` executa TODOS os tool_calls da
resposta corrente (`execute_tool_with_callbacks` → `tool.call(args)` — é aqui
que `ToolSearch#execute` roda) e só DEPOIS chama `complete(&)` de novo, que lê
`@tools` no estado ATUAL (mutado). Ou seja: a promoção acontece ANTES da
releitura, na mesma pilha de chamadas do mesmo `ask` — não existe uma janela
onde o `ruby_llm` "trava" a lista de tools da rodada.

Isto foi **confirmado executando o código real** (script ad-hoc, gem 1.16.0
instalada via Bundler neste projeto, sem rede — `@provider.complete` foi
stubado para devolver duas respostas roteirizadas dentro do MESMO `chat.ask`):
uma tool `tool_search` que promove `send_email` via `chat.with_tools` durante
seu `execute`; a resposta seguinte (ainda dentro do mesmo `ask`) chama
`send_email` com sucesso — sem lançar "unavailable tool". `chat.tools.keys`
ao final: `[:tool_search, :send_email]`. **D6 se confirma para 1.16.0**: não é
preciso desenhar em cima do fallback "chamável só no próximo turno" — mas a
task ainda precisa PROVAR isso com o double da suíte (abaixo), porque é esse
teste, não o script ad-hoc, que corre no CI e pega uma regressão futura da gem.

### Achado colateral — `RubyLLM::Tool#name` não resolve para nomes limpos em classes aninhadas

`RubyLLM::Tool#name` (a que o `ruby_llm` usa como CHAVE em `@tools` — e,
portanto, o nome que o modelo precisa chamar) deriva do `self.class.name`
quando não overridden:

```ruby
# comportamento real, verificado com a classe deste projeto:
Harness::Tools::LoadSkill.new(catalog, []).name
# => "harness--tools--load_skill"   (NÃO "load_skill")
```

Isso significa que, **sem um override explícito de `#name`**, tanto
`Tools::ToolSearch` quanto (pré-existente, fora do escopo desta task)
`Tools::LoadSkill` exporiam ao `ruby_llm` real um nome tipo
`harness--tools--tool_search`/`harness--tools--load_skill` — divergente de
tudo que o resto do código assume (`wire_callbacks` checa
`tool_call.name.to_s == "load_skill"` literal; o `SkillCatalog#format_for_prompt`
instrui o modelo a chamar `load_skill`). Os testes existentes não pegam isso
porque usam `FakeChat#fire_tool_call(name: "load_skill", ...)` com o nome
literal, nunca derivado da classe real — o `FakeChat`/stub de smoke não
reproduz o algoritmo de `RubyLLM::Tool#name`.

**Esta task PRECISA** definir `def name = "tool_search"` explicitamente em
`Tools::ToolSearch` (não depender do default da gem) — ver Passo 1. **Decisão da
fatia (P2B-02 L7): corrigir o mesmo defeito em `LoadSkill` NESTE PR** com um
one-liner `def name = "load_skill"` em `lib/harness/tools/load_skill.rb` — é
pré-existente da Fase 0, mas barato, adjacente e remove um bug real (o
`:skill_activated`/`wire_callbacks` nunca casa em produção sob o nome derivado da
classe). Adicionar `lib/harness/tools/load_skill.rb` aos Arquivos desta task.

### Desvios de interface em relação ao P2B-02 (documentados, não silenciosos)

O construtor pedido (P2B-02 §Interfaces e o brief desta task) é:

```ruby
def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:, state:)
```

Ao tentar implementar o Passo 3 do L5 ("embrulha no `ToolEnvelope`, mesmo wrap
das eager"), aparecem duas lacunas reais contra `ToolEnvelope#initialize`
(`tool_envelope.rb:22`, todos obrigatórios, sem default):

```ruby
def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:, skip_side_effects: [])
```

- **`checkpoint_store:` não está no construtor pedido** — sem ele é
  impossível montar um `ToolEnvelope` idêntico ao eager (`record_side_effect!`
  precisa dele). **Decisão desta task:** adicionar `checkpoint_store:` como
  kwarg obrigatório do construtor de `ToolSearch`, além dos pedidos. É um
  desvio do brief/da P2B-02, mas o L5 ("mesmo wrap das eager") não é
  satisfazível sem ele — a alternativa seria embrulhar sem checkpoint (e
  perder o registro de side-effect das tools promovidas), o que é pior.
- **`timeout:` não precisa ser um parâmetro à parte** — deriva de
  `state.profile.limits[:tool_timeout] || 60`, exatamente como
  `Executor#wrap_tools` (`executor.rb:509`) já faz. `state:` já chega no
  construtor pedido; basta ler de lá.
- **`skip_side_effects` (resume-safety) não aparece em lugar nenhum do fluxo
  hoje** — nem no `TurnState`, nem no construtor pedido. Ele existe hoje só
  como variável LOCAL `skip` dentro de `Executor#run_pipeline`
  (`executor.rb:363`), passada direto para `wrap_tools` das tools EAGER. Se
  uma tool deferred, side-effect, for promovida por `tool_search`, executada,
  e o turno crashar DEPOIS — no replay o `tool_search` roda de novo (idempotente,
  sem problema), promove a MESMA tool de novo, mas **sem `skip_side_effects`
  ela reexecutaria o side-effect já concluído** (cobrar duas vezes, por
  exemplo). **Decisão desta task:** adicionar `attr_accessor :skip_side_effects`
  ao `TurnState` (`lib/harness/turn_state.rb`, uma linha) e ler
  `Array(state.skip_side_effects)` ao montar o `ToolEnvelope` das promovidas.
  Quem de fato ATRIBUI `state.skip_side_effects = skip` no `run_pipeline` é a
  **task 10** (ela já mexe em `configure_chat`/no entorno do estágio 3-5) —
  esta task só consome o accessor e trata `nil` como `[]` (turno novo, sem
  nada a pular), então os specs desta task não dependem da task 10 para
  passar.

Isso é reportado explicitamente como inconsistência a resolver, não corrigido
silenciosamente — ver o fechamento desta task.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/tools/tool_search.rb` | CREATE | `Harness::Tools::ToolSearch < RubyLLM::Tool` — matcher + promoção mid-loop (D6) |
| `spec/harness/tools/tool_search_spec.rb` | CREATE | specs puros (matcher/allowlist/idempotência) + o teste crítico de propagação mid-loop |
| `lib/harness/turn_state.rb` | MODIFY | `attr_accessor :skip_side_effects` (ver "Desvios de interface" acima; task 10 atribui o valor real) |

## Passo a passo

### Passo 1 — esqueleto da classe, DSL da gem, override de `#name`

`require "ruby_llm"` fica NESTE arquivo (herda de `RubyLLM::Tool`), por isso
`Tools::ToolSearch` **não** entra em `lib/harness.rb` — o Executor a carrega
lazy dentro de `configure_chat` (mesma disciplina D9 do `LoadSkill`, ver
`create_chat`/`configure_chat` em `executor.rb:590-615`, que a task 10 edita
para fazer `require_relative "tools/tool_search"` ao lado do de `load_skill`).

**Padrão de referência (codebase) — `Tools::LoadSkill` inteiro** (o espelho
direto desta tool; a MESMA disciplina de `require` lazy, allowlist recebida
no construtor, e retorno como Hash em caso de erro):

```ruby
# lib/harness/tools/load_skill.rb (arquivo completo, referência)
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Nível 2 do progressive disclosure: carrega o corpo completo do SKILL.md
    # sob demanda. Respeita a allowlist do agente (o modelo não carrega uma
    # skill que a política não expôs).
    #
    # Migrado da Fase 0 sem mudança de lógica — só o módulo AgentRuntime ->
    # Harness (doc 00 §4). `require "ruby_llm"` fica NESTE arquivo (herda de
    # RubyLLM::Tool), por isso ele NÃO entra em lib/harness.rb: o Executor o
    # carrega lazy dentro de create_chat (D9).
    class LoadSkill < RubyLLM::Tool
      description "Carrega as instruções completas (SKILL.md) de uma skill pelo nome"
      param :name, desc: "Nome exato da skill, conforme listado em <available_skills>"

      def initialize(catalog, allowed_names)
        @catalog = catalog
        @allowed = Array(allowed_names).map(&:to_s)
        super()
      end

      def execute(name:)
        return { error: "skill '#{name}' não disponível para este agente" } unless @allowed.include?(name.to_s)

        skill = @catalog.find(name)
        return { error: "skill '#{name}' não encontrada" } unless skill

        skill.body
      end
    end
  end
end
```

`ToolSearch` diverge de `LoadSkill` em três pontos, todos motivados acima:
recebe `chat` (para promover), `tool_registry`/`event_stream`/`checkpoint_store`
(para instanciar+embrulhar+auditar) e `state` (perfil/limits/skip). E,
diferente de `LoadSkill`, **precisa** de `def name` explícito — ver
"Achado colateral" no Contexto:

```ruby
# lib/harness/tools/tool_search.rb — esqueleto (Passo 1)
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    class ToolSearch < RubyLLM::Tool
      description "Busca e habilita ferramentas adicionais por descrição da necessidade"
      param :query, desc: "O que você precisa fazer (ex.: 'enviar email', 'gerar fatura')"

      # RubyLLM::Tool#name deriva de self.class.name (self.class.name.gsub(...)),
      # e para uma classe aninhada (Harness::Tools::ToolSearch) isso NÃO produz
      # "tool_search" — produz "harness--tools--tool_search" (verificado; ver
      # Contexto). Override explícito: o nome que o modelo chama tem que casar
      # com o que o resto do sistema (catálogo, docs, testes) assume.
      def name = "tool_search"

      def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:,
                     checkpoint_store:, state:)
        @catalog = catalog
        @deferred_allowed = Array(deferred_allowed).map(&:to_s)
        @chat = chat
        @tool_registry = tool_registry
        @event_stream = event_stream
        @checkpoint_store = checkpoint_store
        @state = state
        @promoted = [] # nomes já promovidos NESTE chat — idempotência (Passo 5)
        super()
      end
    end
  end
end
```

### Passo 2 — matcher restrito à allowlist + instanciação via `tool_registry`

`catalog.search` já aceita `within:` (task 6, P2B-02 §Interfaces) — usar isso
em vez de fazer a interseção manualmente é o que garante L1 (Tool Search
NUNCA promove o que a Policy não liberou; se o nome não está em
`deferred_allowed`, `search` já não o devolve):

```ruby
def execute(query:)
  matches = @catalog.search(query, within: @deferred_allowed)
  return { matched: [], message: "nenhuma ferramenta encontrada para '#{query}'" } if matches.empty?

  new_matches = matches.reject { |m| @promoted.include?(m.name) }
  promote(new_matches) unless new_matches.empty?
  emit_tool_search(query, matches.map(&:name))

  { matched: matches.map { |m| describe(m) } }
end
```

`describe(entry)` resolve a tool via `tool_registry` só para ler
name/description/parameters (não precisa embrulhar de novo se já promovida —
mas instanciar de novo é barato e sem efeito colateral, então simplificar
instanciando sempre para a descrição é aceitável; a PROMOÇÃO é que precisa
checar `@promoted`, não a descrição).

### Passo 3 — instancia, embrulha em `ToolEnvelope`, promove via `chat.with_tools` (D6)

**Padrão de referência (codebase) — como o Executor embrulha as tools eager**
(`wrap_tools`, `executor.rb:508-515` — o MESMO wrap que as promovidas
precisam receber, L5 "mesmo wrap das eager"):

```ruby
# lib/harness/executor.rb (trecho existente, referência)
def wrap_tools(tools, state, skip_side_effects = [])
  timeout = state.profile.limits[:tool_timeout] || 60 # D4/D6
  tools.map do |tool|
    ToolEnvelope.new(tool, state: state, checkpoint_store: @checkpoint_store,
                           tool_registry: @tool_registry, timeout: timeout,
                           skip_side_effects: skip_side_effects)
  end
end
```

`ToolSearch#promote` replica exatamente essa forma (mesmos kwargs, mesma
fonte de timeout), só que as instâncias vêm do `tool_registry.resolve(name)`
em vez de já chegarem prontas do Executor:

```ruby
def promote(entries)
  timeout = @state.profile.limits[:tool_timeout] || 60
  wrapped = entries.filter_map do |entry|
    tool = @tool_registry.resolve(entry.name)
    @promoted << entry.name
    ToolEnvelope.new(tool, state: @state, checkpoint_store: @checkpoint_store,
                           tool_registry: @tool_registry, timeout: timeout,
                           skip_side_effects: Array(@state.skip_side_effects))
  rescue Harness::NotFoundError
    nil # catálogo desalinhado do registry — defensivo, não deveria acontecer (edge case)
  end
  @chat.with_tools(*wrapped) unless wrapped.empty?
end
```

`tool_registry.resolve(name)` (`Registry#resolve`, `registry.rb:37`) devolve
a INSTÂNCIA pronta (`entry.factory.call`) ou levanta `NotFoundError` — o
`rescue` cobre o catálogo apontar para um nome que o registry não tem mais
(cenário de plugin removido a quente; fora do escopo normal, mas não deve
derrubar a busca inteira por causa de UM match ruim).

### Passo 4 — evento `:tool_search`

Espelha `:skill_activated`, mas emitido pela PRÓPRIA tool (não por
`wire_callbacks`, diferente de `load_skill` — decisão da P2B-02 de dar
`event_stream:`/`state:` no construtor). `meta` usa `task.id`/`session_id`
disponíveis em `state.task`; **não** carrega `seq` monotônico por task (isso
vem do contador `@seqs`, privado ao `Executor` — ver `## Notas`, gap
documentado, não bloqueia):

```ruby
def emit_tool_search(query, matched_names)
  @event_stream.emit(Harness::Event.new(
                       type: :tool_search,
                       data: { query: query, matched: matched_names },
                       meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                     ))
end
```

### Passo 5 — idempotência

`@promoted` (Array de nomes já promovidos NESTE chat/turno) evita
reinstanciar+reembrulhar+chamar `chat.with_tools` de novo para uma tool já
promovida — importante porque o double da suíte (`FakeChat#with_tools`)
**concatena** (`@tools.concat(tools)`, sem dedupe por chave, ao contrário do
`Hash` do `ruby_llm` real que sobrescreve pela chave). Sem esse controle
próprio, uma re-busca que reencontra a mesma tool duplicaria entradas em
`chat.tools` no double (mesmo sendo inofensivo no `ruby_llm` real) — a
idempotência fica correta nos DOIS ambientes, não só no real.

### Passo 6 — retorno ao modelo

```ruby
def describe(entry)
  tool = @tool_registry.resolve(entry.name)
  {
    name: entry.name,
    description: entry.description,
    parameters: tool.parameters.transform_values do |p|
      { type: p.type, description: p.description, required: p.required }
    end
  }
rescue Harness::NotFoundError
  { name: entry.name, description: entry.description, parameters: {} }
end
```

## Edge cases

- **Query sem match:** `catalog.search` devolve `[]`; nada é promovido, nada
  chama `chat.with_tools`; retorna `{ matched: [], message: "..." }` ao
  modelo. `:tool_search` ainda é emitido com `matched: []` (auditoria: "o
  modelo buscou e não achou" é um fato relevante, análogo a manter o registro
  mesmo em busca vazia).
- **Tool fora de `deferred_allowed`:** nunca aparece nos resultados — o
  filtro é a fonte (`within:` do `search`), não um segundo passo. Uma tool de
  OUTRO agente (fora da allowlist deste), ou uma tool que a Policy negou,
  simplesmente não existe para esta busca (L1).
- **Re-promoção da mesma tool (idempotência):** segunda chamada com query que
  recasa a mesma entry NÃO chama `chat.with_tools` de novo para ela (Passo 5);
  ainda assim aparece no `matched` retornado ao modelo (ela continua
  "encontrada", só não precisa ser promovida de novo).
- **Entry no catálogo, ausente no `tool_registry`:** `resolve` levanta
  `NotFoundError`; `promote` a descarta (`rescue` no `filter_map`) e
  `describe` devolve `parameters: {}` — a busca não quebra por causa de UM
  match dessincronizado.
- **`state.skip_side_effects` não setado (nil):** `Array(nil)` → `[]` —
  comportamento idêntico a "nenhum side-effect para pular" (turno novo, não é
  um resume). Task 10 é quem popula isso de verdade a partir do `skip` local
  do `run_pipeline` — os specs desta task cobrem só o `Array(nil) => []`.
- **`chat` não é o `ruby_llm` real (double da suíte):** `promote` só chama
  `#with_tools` — qualquer objeto que responda a isso (real ou `FakeChat`)
  funciona; nenhuma outra API do `chat` é usada.

## Testes

**Arquivo:** `spec/harness/tools/tool_search_spec.rb`

| Cenário | Expectativa |
|---|---|
| `execute(query:)` com match dentro de `deferred_allowed` | `tool_registry.resolve` chamado para o nome; `chat.with_tools` chamado com um `ToolEnvelope` cuja tool delegada tem aquele `name`; retorno inclui `name`/`description`/`parameters` |
| match que NÃO está em `deferred_allowed` (mas está no catálogo geral) | nunca aparece no resultado; `chat.with_tools` não é chamado para ele |
| query sem nenhum match | `chat.with_tools` NÃO chamado; retorno `{ matched: [], message: ... }`; `:tool_search` ainda emitido com `matched: []` |
| segunda chamada, mesmo match já promovido | `tool_registry.resolve`/`chat.with_tools` NÃO chamados de novo para aquele nome (idempotência); resultado ainda lista a tool como encontrada |
| `entry` no catálogo cujo nome o `tool_registry` não resolve (`NotFoundError`) | descartada de `promote` sem levantar; `describe` devolve `parameters: {}` |
| evento emitido | `event_stream` recebe um `Harness::Event` `:tool_search` com `data: { query:, matched: [names] }` e `meta[:task_id]`/`meta[:session_id]` corretos |
| `state.skip_side_effects` ausente | `ToolEnvelope` das promovidas recebe `skip_side_effects: []` sem levantar |
| **CRÍTICO — propagação mid-loop (D6), com `FakeChat`** (`spec/support/fake_chat.rb`) | ver cenário detalhado abaixo |

**Cenário crítico, passo a passo** (usa o `script`/`fire_tool_call`/
`fire_tool_result` do `FakeChat`, exatamente como o padrão de
`executor_chat_spec.rb`):

```ruby
it "tool promovida durante execute fica em chat.tools ANTES da próxima fire_tool_call (mesmo ask)" do
  chat = FakeChat.new
  search = described_class.new(catalog, ["send_email"], chat,
                                tool_registry: registry, event_stream: events,
                                checkpoint_store: checkpoint_store, state: state)
  chat.with_tools(search) # só a builtin cabeada — send_email é deferred

  chat.script = -> do
    fire_tool_call(name: "tool_search", arguments: { "query" => "enviar email" })
    # dentro do execute acima, ToolSearch#promote já rodou chat.with_tools —
    # a asserção abaixo prova que a promoção é visível DENTRO do mesmo script/ask,
    # antes de qualquer "próxima rodada" acontecer.
    raise "send_email não promovida a tempo" unless chat.tools.any? { |t| t.name == "send_email" }
    fire_tool_call(name: "send_email", arguments: { "to" => "a@b.com" }) # prova que é CHAMÁVEL
  end

  chat.ask("envie um email")

  expect(chat.tools.map(&:name)).to include("send_email")
end
```

Isso prova a propagação usando o double que a suíte inteira já usa (sem gem,
sem chave de API) — mas note que `fire_tool_call`/`FakeChat` **não
reimplementam** o `handle_tool_calls` real: quem de fato invoca
`search.call(args)` dentro de `fire_tool_call` é o `before_tool_call` que o
`Executor#wire_callbacks` registra, então o teste acima precisa rodar através
do `Executor` (ou de um harness equivalente) para que `execute` realmente
seja chamado — não basta instanciar `ToolSearch` isolada e invocar `execute`
manualmente sem passar pelo `chat`. Ajustar o setup do spec para refletir
isso (reaproveitar o padrão de `executor_chat_spec.rb`: `Executor#configure_chat`
+ `Executor#wire_callbacks` reais, com `FakeChat`).

A prova de que isso **também vale para o `ruby_llm` 1.16.0 de verdade** (não
só o double) foi feita ad-hoc (ver `## Notas`) — não precisa entrar como spec
desta task (exigiria stubar um `Provider` real, o que é mais propriamente um
smoke/integração — candidato a reforçar a task 12), mas o achado deve ser
citado no PR.

## Definition of Done

- [ ] Propagação mid-loop PROVADA com `FakeChat` (o cenário crítico acima,
      rodando através do `Executor` real ou equivalente) — o teste falha se
      `chat.with_tools` chamado dentro de `execute` não for visível antes da
      chamada seguinte no mesmo `ask`
- [ ] `def name = "tool_search"` presente e coberto por spec (não depender do
      default de `RubyLLM::Tool#name`)
- [ ] Matcher restrito a `deferred_allowed` via `within:` (L1) — tool fora da
      allowlist nunca aparece nem é promovida
- [ ] Promovidas embrulhadas em `ToolEnvelope` com os MESMOS kwargs das
      eager (`timeout` do profile, `skip_side_effects` do state)
- [ ] `:tool_search` emitido com `{ query, matched }` e `meta` correto
      (task_id/session_id)
- [ ] Re-promoção idempotente (sem duplicar em `chat.tools`, sem re-resolver
      no `tool_registry`)
- [ ] `attr_accessor :skip_side_effects` adicionado ao `TurnState`
      (consumido aqui; atribuído de verdade só na task 10 — documentar a
      dependência no PR)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**RISCO PRINCIPAL (D6) — resultado da verificação:** a promoção mid-loop via
`chat.with_tools` dentro de `execute` **FOI CONFIRMADA** contra o `ruby_llm`
1.16.0 realmente instalado (Gemfile.lock: `ruby_llm (1.16.0)`), não só por
leitura do código-fonte: um script ad-hoc instanciou um `RubyLLM::Chat` real
(`assume_model_exists: true`, `@provider.complete` stubado sem rede),
promoveu uma tool dentro do `execute` de outra, e a rodada SEGUINTE do MESMO
`chat.ask` conseguiu chamá-la — sem erro de "unavailable tool". A razão
estrutural (`lib/ruby_llm/chat.rb` da gem): `@tools` é um `Hash` de instância
mutado IN-PLACE por `with_tool`/`with_tools`; `handle_tool_calls` executa
todos os tool_calls da resposta corrente e SÓ DEPOIS chama `complete(&)` de
novo — que lê `@tools` já mutado. Não existe uma cópia/snapshot da lista de
tools tirada no início da rodada. **Isso vale tanto para `handle_sequential_tool_calls`
quanto para `handle_concurrent_tool_calls`** — ambos completam antes da
chamada recursiva a `complete`.

Consequência prática: **o fallback "tool promovida fica chamável no próximo
turno" (citado no `00-overview` §Riscos e no D6 do P2B-02) não é necessário
para 1.16.0** — mas se uma atualização futura da gem mudar esse
comportamento (por exemplo, se `@tools` passar a ser copiado/congelado por
rodada), o teste crítico desta task (FakeChat) PEGA a regressão no double,
mas **não pega automaticamente no `ruby_llm` real** (o double não pode, por
construção, reproduzir um bug interno da gem). Se algum dia isso quebrar de
verdade: hoje **o fallback também não está pronto** — `create_chat`/
`configure_chat` (`executor.rb:590-615`) recriam o `chat` do ZERO a cada
turno físico, a partir só de `state.allowed_tools` (Resolution/Policy do
estágio 3); nada persiste quais tools foram promovidas por `tool_search` num
turno anterior. Fazer o fallback funcionar de verdade exigiria uma task nova:
persistir os nomes promovidos no checkpoint/`TurnState` e fazer
`configure_chat` reincluí-los como eager no turno seguinte. Não implementar
isso agora (não é necessário, dado o resultado acima) — só deixar registrado
para não ser surpresa se a suíte um dia começar a falhar nesse ponto após um
bump de `ruby_llm`.

**BUG LATENTE (fora do escopo, sinalizar no PR):** `RubyLLM::Tool#name` sem
override, para `Harness::Tools::LoadSkill`, produz `"harness--tools--load_skill"`
(verificado), não `"load_skill"`. Como os testes de `wire_callbacks`
(`executor_chat_spec.rb`) constroem o `tool_call` com o nome LITERAL
`"load_skill"` (nunca derivado da classe real), isso nunca foi pego. Em
produção, com a gem real, o modelo provavelmente não consegue chamar
`load_skill` pelo nome que o `SkillCatalog` anuncia no prompt. `ToolSearch`
desta task NÃO tem esse problema (override explícito no Passo 1), mas
`LoadSkill` continua exposto — recomendar um fix separado (um `def name`
análogo), não misturar no diff desta task.

**Coordenação de arquivo compartilhado:** `lib/harness/turn_state.rb` ganha
`skip_side_effects` aqui; a task 10 é quem de fato atribui
`state.skip_side_effects = skip` dentro de `Executor#run_pipeline` (mesma
linha onde `skip` já existe hoje, `executor.rb:363`, ao lado de onde
`state.allowed_tools = wrap_tools(...)` já usa essa variável). Sequenciar ou
revisar com atenção se as duas PRs andarem em paralelo — soma-se à
coordenação já conhecida de `configure_chat` entre tasks 5/10 (`tasks.md`).

Muda o critério 3 da fatia (`00-overview.md`) na medida em que ele já assumia
a promoção funcionando "no mesmo turno" — este resultado CONFIRMA que
nenhuma reformulação é necessária. Também informa o smoke da task 12: o
cenário "agente com `tools_deferred` chama `tool_search` e depois a tool
promovida no MESMO turno" pode ser escrito como um único turno (não dois),
já que a propagação mid-loop está provada.
