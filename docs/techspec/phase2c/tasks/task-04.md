# Task 04 (P2C): `Context::Providers::Memory` (read path)

> **Techspec:** [P2C-01-memory-store-and-read.md](../P2C-01-memory-store-and-read.md) (§Provider, L5–L8) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Criar `Harness::Context::Providers::Memory`, o adaptador de contexto que injeta
a memória cross-session (facts + notes) do `MemoryStore` (task 1) no prompt de
sistema do turno, como um fragmento `<memory>` — a metade de LEITURA da fatia C
(RFC-0005 §6). É um adaptador FINO: não reimplementa persistência nem
ranking — só lê `@store.facts`/`@store.notes`, formata e devolve `[]` quando
não há nada. `enabled_for?` é o gate de opt-in por agente (D5,
`profile.memory`); sem este provider, um `MemoryStore` escrito via `remember`
(task 5, P2C-02) nunca chegaria ao modelo — a escrita ficaria muda.

Este provider é **real e ativo assim que registrado** — não um contrato
preparado à espera de wiring (mesma disciplina do `ToolSearch`, P2B task 8).
A única coisa que falta para produzir efeito em produção é o registro em
`CONTEXT_PROVIDERS` (task 7, fora do escopo desta task).

## Dependências

| Task | Componente | Necessário para |
|---|---|---|
| [Task 01](./task-01.md) | `MemoryStore` (`lib/harness/memory_store.rb`) | `facts(tenant:)` / `notes(tenant:, limit:)` — este provider é um adaptador FINO sobre ele, igual o `Skill` provider é sobre o `SkillCatalog` |
| [Task 02](./task-02.md) | `AgentProfile.memory` (opt-in, D5) | `enabled_for?(profile)` — gate de ativação do provider |
| [Task 03](./task-03.md) | Threading de tenant (`Executor::ContextRequest#tenant`, `state.tenant`) | `request.tenant` chega populado do Command; sem a task 3 o provider ainda funciona (fallback `tenant: nil` → `MemoryStore::DEFAULT_TENANT`), mas ficaria sempre no escopo `_default` em produção |

## Contexto

### Espelha o `Skill`/`ToolSearch` provider, ponto a ponto

`lib/harness/context/providers/skill.rb` e `lib/harness/context/providers/
tool_search.rb` são o precedente direto: recebem uma dependência de domínio no
`initialize` (catálogo lá, `MemoryStore` aqui), no `call(request)` pedem o
recorte relevante, formatam com um método de formatação dedicado, devolvem
`[]` se vazio, senão devolvem `[ContextFragment.build(...)]` com
`placement: :system`, `pinned: false`. `Memory` replica essa forma trocando:

- catálogo → `@store` (`MemoryStore`, task 1);
- `@catalog.effective(profile.skills)` / `@catalog.subset(profile.
  tools_deferred)` → `@store.facts(tenant:)` + `@store.notes(tenant:,
  limit:)` — duas chamadas em vez de uma, porque memória tem duas camadas
  (P2C-01 §"MemoryStore");
- `@catalog.format_for_prompt(...)` → `format_block(facts, notes)` privado
  deste provider (o `MemoryStore`, ao contrário dos catálogos, não formata
  para prompt — é um store de domínio puro, task 1 não expõe esse método);
- `priority: 80` (Skill) / `70` (ToolSearch) → **`priority: 75`** — entre os
  dois, ver ordem de sacrifício abaixo;
- sem instrução extra no texto (diferente de Skill/ToolSearch, que mandam
  "chame `load_skill`"/"chame `tool_search`") — memória é contexto passivo
  (L8); a instrução de COMO gravar vive na descrição da tool `remember`
  (task 5, P2C-02), não aqui.

### `enabled_for?` — opt-in por agente (D5)

Diferente de `Skill`/`ToolSearch` (que herdam `enabled_for?` da base,
sempre `true`, e dependem só da allowlist `context_providers` do Builder),
`Memory` **sobrescreve** `enabled_for?(profile) = !!profile.memory`. Isso é a
mesma assimetria opt-in de `capabilities`/`tools_deferred` (agent_profile.rb):
`nil`/`false` = OFF — paridade Fase 1 exata (agente sem `memory: true` nunca
ganha o fragmento, mesmo que o `MemoryStore` tenha dados gravados por outro
agente/turno no mesmo tenant). Isso empilha com o gate de allowlist que o
`ContextBuilder#select_providers` já aplica para TODO provider
(`enabled_for?(profile) && allowlisted?(p, profile.context_providers)`,
`lib/harness/context/builder.rb:52-55`) — dois gates independentes, como os
demais providers.

### `required?` — degradação graciosa (L7, D4)

Não sobrescrever `required?` — o default da base (`ContextProvider#required? =
false`) já é o comportamento correto aqui. Se `@store.facts`/`@store.notes`
lançar (ex.: backend indisponível), o `ContextBuilder#handle_provider_failure`
emite `:provider_warning` e o turno segue sem memória (degradação graciosa,
nunca aborta) — ver `lib/harness/context/builder.rb:88-95`. Só providers com
`required? == true` abortam o turno via `ContextError`; memória, como
skills/tools deferred, nunca é crítica o suficiente para isso.

### Ordem de sacrifício (priority 75)

RFC-0005 §"ordem de sacrifício", agora com a fatia C encaixada: histórico
antigo → histórico recente (teto 79) → skills (80) → **memória (75)** → tools
deferred (70); identidade nunca (`pinned: true`, incortável). Memória é fato
do usuário — sobrevive mais que o catálogo de tools (menos relevante sob
pressão de orçamento que uma preferência gravada), menos que skills
(capacidades do agente, mais estruturais). `pinned: false`: sob orçamento
apertado, o `ContextBuilder#apply_budget` corta por `[priority, index]`
crescente — memória cai antes de skills, depois de tools deferred.

### Formato `<memory>` (L8) — sem instrução extra

```
<memory>
  <fact key="plano">premium</fact>
  <note>cliente prefere email</note>
</memory>
```

Todos os `facts` (conjunto pequeno, k/v — sem paginação) + as `notes_limit`
notes **mais recentes** (o `MemoryStore#notes(tenant:, limit:)` já devolve
nessa ordem, task 1 — o provider não reordena). Sem ranking por similaridade
(D1, fora de escopo — fatia D). O orçamento fino de token é responsabilidade
do `ContextBuilder` (evicção por priority); o cap de *contagem* de notes é
`@notes_limit` (default 10), aplicado aqui.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/context/providers/memory.rb` | CREATE | `Context::Providers::Memory < ContextProvider` |
| `lib/harness.rb` | MODIFY | `require_relative "harness/context/providers/memory"` |
| `spec/harness/context/providers/memory_spec.rb` | CREATE | specs isoladas (sem Executor, sobre `MemoryStore` real + `Stores::Memory`) |

## Passo a passo

### Passo 1 — relembrar `ToolSearch`, o precedente mais próximo

**Padrão de referência (codebase) — `ToolSearch` provider inteiro:**

```ruby
# lib/harness/context/providers/tool_search.rb (referência integral)

module Harness
  module Context
    module Providers
      class ToolSearch < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          entries = @catalog.subset(request.profile.tools_deferred)
          block = @catalog.format_for_prompt(entries)
          return [] if block.empty?

          [ContextFragment.build(content: block, placement: :system,
                                 priority: 70, source: id)]
        end
      end
    end
  end
end
```

**`ContextFragment.build` (assinatura exata, `lib/harness/context/fragment.rb`):**

```ruby
ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                              :source, :pinned) do
  def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                 pinned: false)
    new(content: content, placement: placement, priority: priority,
        tokens: tokens, source: source, pinned: pinned)
  end
end
```

**`ContextProvider` base (`lib/harness/context/provider.rb`) — os 4 hooks:**

```ruby
class ContextProvider
  def id = self.class.name       # override para nome estável
  def required? = false          # true -> falha aborta o turno (D4)
  def enabled_for?(_profile) = true
  def call(_request) = []        # -> [ContextFragment]; pode fazer IO
end

ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                             :checkpoint)
```

**`MemoryStore` (assinatura consumida, task 1 — `lib/harness/memory_store.rb`):**

```ruby
class MemoryStore
  Fact = Data.define(:key, :value, :updated_at)
  Note = Data.define(:id, :text, :created_at)

  def facts(tenant:)             # -> [Fact] ordenados por key
  def notes(tenant:, limit: nil) # -> [Note] mais recentes primeiro, capadas
end
```

### Passo 2 — implementar `Memory`

```ruby
# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Adapta o MemoryStore (task 1, RFC-0005 §6): injeta facts + notes
      # cross-session no prompt de sistema. Adaptador FINO — não reimplementa
      # persistência/ranking (o store é intocado), igual Skill/ToolSearch são
      # adaptadores finos sobre seus catálogos.
      #
      # enabled_for? sobrescreve a base: opt-in por agente (D5,
      # profile.memory). nil/false = OFF, mesma assimetria de
      # capabilities/tools_deferred — paridade Fase 1 por omissão do flag.
      # required? fica no default (false): falha do store -> :provider_warning
      # + degradação graciosa (L7), nunca aborta o turno.
      class Memory < ContextProvider
        def initialize(store:, notes_limit: 10)
          @store = store
          @notes_limit = notes_limit
        end

        def enabled_for?(profile) = !!profile.memory

        def call(request)
          tenant = request.respond_to?(:tenant) ? request.tenant : nil
          facts = @store.facts(tenant: tenant)
          notes = @store.notes(tenant: tenant, limit: @notes_limit)
          return [] if facts.empty? && notes.empty?

          # pinned: false, priority 75 — entre skills (80) e tools deferred
          # (70). Ordem de sacrifício: histórico -> tools deferred -> memória
          # -> skills -> (identidade pinned, nunca). Ver P2C-01 §L5.
          [ContextFragment.build(content: format_block(facts, notes),
                                 placement: :system, priority: 75, source: id)]
        end

        private

        # Sem instrução extra (diferente de Skill/ToolSearch, que mandam
        # "chame load_skill"/"tool_search") — memória é contexto passivo
        # (P2C-01 L8); a instrução de gravar vive na tool `remember` (task 5).
        def format_block(facts, notes)
          lines = ["<memory>"]
          facts.each { |f| lines << "  <fact key=\"#{f.key}\">#{f.value}</fact>" }
          notes.each { |n| lines << "  <note>#{n.text}</note>" }
          lines << "</memory>"
          lines.join("\n")
        end
      end
    end
  end
end
```

`request.respond_to?(:tenant) ? request.tenant : nil` é o MESMO padrão
defensivo já usado pelo `Request` provider (`lib/harness/context/providers/
request.rb`, citado no P2C-01 §"Threading de tenant" como o precedente que já
chamava `request.tenant` antes de o campo existir de fato no
`Executor::ContextRequest`). Aqui a defensividade cobre dois cenários: (a) a
task 3 ainda não mesclada — `Executor::ContextRequest` sem `.tenant` — e (b)
specs isoladas que constroem um dublê de request sem esse campo. Em ambos,
cai em `nil`, e o `MemoryStore` aplica `DEFAULT_TENANT` (task 1) — nunca
levanta.

### Passo 3 — registrar o require em `lib/harness.rb`

Inserir junto dos demais providers de contexto, depois de `tool_search`
(ordem alfabética informal do bloco existente):

```ruby
require_relative "harness/context/providers/request"
require_relative "harness/context/providers/prompt"
require_relative "harness/context/providers/skill"
require_relative "harness/context/providers/tool_search"
require_relative "harness/context/providers/memory"      # NOVO
require_relative "harness/context/providers/session"
```

### Passo 4 — nota para o wiring (task 7)

Esta task **não** mexe em `config/wiring.rb` — isso é escopo da task 7, que
constrói `MEMORY_STORE` e adiciona `Context::Providers::Memory.new(store:
MEMORY_STORE)` a `CONTEXT_PROVIDERS`. Igual ao precedente do `ToolSearch`
(P2B task 11), não há ambiguidade de rota: o provider é sempre ativo assim
que registrado — o único cenário de "sem efeito" é `profile.memory` nil
(gate D5), não uma decisão de wiring em aberto.

## Edge cases

- **`profile.memory` nil/false (`enabled_for?` → false):** o
  `ContextBuilder#select_providers` nem chama `call` — o provider é
  filtrado antes de produzir. Paridade Fase 1: agente sem `memory: true`
  nunca ganha o fragmento, mesmo que o `MemoryStore` tenha dados gravados
  (por outro agente ou turno anterior no mesmo tenant).
- **`facts` e `notes` ambos vazios (store existe, mas tenant sem dados):**
  `call` retorna `[]` — nenhum fragmento "vazio" chega ao Builder (mesmo
  contrato de `Skill`/`ToolSearch` quando `format_for_prompt` produz string
  vazia).
- **`tenant` nil repassado:** `request.tenant` nil (Command sem tenant, ou
  request de teste sem o campo) → passado como `tenant: nil` para
  `@store.facts`/`@store.notes` — o `MemoryStore` (task 1) resolve para
  `DEFAULT_TENANT` internamente; este provider não faz esse fallback, só
  repassa (mesma divisão de responsabilidade do `ToolSearch` com `Array(nil)`
  no `ToolCatalog`).
- **`request` sem `.tenant` (Struct antigo, task 3 não mesclada, ou dublê de
  teste):** `respond_to?(:tenant)` → `false` → `nil` — nunca levanta
  `NoMethodError`.
- **`notes_limit` respeitado:** `@store.notes(tenant:, limit: @notes_limit)`
  — o cap é aplicado PELO STORE (task 1), este provider só repassa o valor
  do `initialize` (default 10). Testar com um store real com mais notes que
  o limite e confirmar que só as N mais recentes aparecem no bloco.
- **Formato `<memory>`:** `<fact key="...">` para cada fact (todas, sem
  paginação — conjunto pequeno k/v), `<note>texto</note>` para cada note (na
  ordem que `@store.notes` devolve — mais recente primeiro, sem reordenar
  aqui). Sem instrução extra de "chame X" (diferente de Skill/ToolSearch) —
  testar que o bloco NÃO contém nenhuma menção a `remember`.
- **`required?` fica `false` (default, não sobrescrito):** uma falha do
  `@store` (ex.: `facts`/`notes` levanta) propaga para o
  `ContextBuilder#handle_provider_failure`, que emite `:provider_warning` e
  degrada graciosamente — não é responsabilidade desta task testar o
  Builder, mas o provider não deve capturar a exceção internamente (deixar
  subir é o contrato certo, como `Skill`/`ToolSearch` também não capturam).
- **`priority: 75` / ordem de sacrifício:** testar que fica estritamente
  entre `ToolSearch` (70) e `Skill` (80), e que `pinned` é `false`.

## Testes

**Arquivo:** `spec/harness/context/providers/memory_spec.rb`

| Cenário | Expectativa |
|---|---|
| `profile.memory` nil | `enabled_for?(profile)` → `false` |
| `profile.memory: true` | `enabled_for?(profile)` → `true` |
| store com 1 fact + 1 note, `profile.memory: true` | `call` retorna 1 fragmento `:system`, `priority: 75`, `pinned: false`, `content` contém `<memory>`, `<fact key="...">`, `<note>...</note>` |
| store vazio (sem facts, sem notes) | `call` retorna `[]` |
| `tenant` repassado ao store: fact gravado no tenant "a", request com `tenant: "a"` | fragmento contém o fact; request com `tenant: "b"` → `[]` (isolamento, contrato já coberto na suíte da task 1, aqui só a integração via provider) |
| `tenant` nil no request | `@store.facts(tenant: nil)`/`notes(tenant: nil, ...)` chamados sem levantar (delega ao `DEFAULT_TENANT` do `MemoryStore`) |
| `notes_limit: 2`, store com 3 notes | bloco contém só as 2 mais recentes |
| `priority`/`pinned` | `priority == 75`, `pinned == false` — estritamente entre `ToolSearch` (70) e `Skill` (80) |
| bloco sem instrução extra | `content` não contém `remember` (diferente de Skill/ToolSearch, que mandam chamar uma tool) |

Usar `Harness::MemoryStore.new(store: Harness::Stores::Memory.new)` real
(task 1) — mesma disciplina do `tool_search_spec.rb`, que usa `ToolCatalog`
real sobre um `ToolRegistry` real, sem dublês de domínio. O `request` de
teste é construído com `Harness::ContextRequest.new(session: nil, message:
"oi", profile: profile, tenant: tenant, vars: {}, checkpoint: nil)`, onde
`profile` é um `AgentProfile.build(id: "a", model: "m", memory: true/false/nil)`
— mesmo padrão do `skill_spec.rb`/`tool_search_spec.rb`, sem depender de
`vars`.

## Definition of Done

- [ ] `Context::Providers::Memory` criado, espelhando a forma de
      `Skill`/`ToolSearch` (adaptador fino sobre `MemoryStore`)
- [ ] `enabled_for?(profile) = !!profile.memory` sobrescrito (D5) — os demais
      hooks (`required?`, `id`) ficam no default da base
- [ ] `priority: 75`, `pinned: false`, `placement: :system` — estritamente
      entre `ToolSearch` (70) e `Skill` (80)
- [ ] `[]` quando `facts` e `notes` estão ambos vazios
- [ ] `tenant` repassado como `request.respond_to?(:tenant) ? request.tenant
      : nil` (defensivo, não assume o campo já existir)
- [ ] `notes_limit` (default 10) respeitado, repassado ao `MemoryStore` sem
      reimplementar o cap
- [ ] Formato `<memory>` sem instrução extra (L8) — comentário inline
      explicando a diferença de Skill/ToolSearch
- [ ] `require_relative` adicionado em `lib/harness.rb`
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Sem evento no read path (D4/D3).** Diferente da escrita (`remember`,
  task 5, que emite `:memory_written`), a LEITURA aqui não emite evento algum
  — é um Context Provider comum, mesma disciplina de `Skill`/`ToolSearch`
  (nenhum dos dois emite evento ao formar o fragmento). Não adicionar
  `event_stream` ao `initialize` desta task.
- **Semantic/ranking é fatia D**, fora de escopo: este provider devolve
  **todos** os facts + as N notes mais recentes, sem embeddings, sem
  similaridade, sem extractor por LLM (D1). Se o `MemoryStore` crescer muito
  em `facts`, o corte fino de orçamento é do `ContextBuilder` (evicção por
  priority), não deste provider.
- **Task 7 wireia.** `config/wiring.rb` ganha `MEMORY_STORE` e adiciona
  `Context::Providers::Memory.new(store: MEMORY_STORE)` a
  `CONTEXT_PROVIDERS` — mesma lista onde `Providers::Skill`/`ToolSearch` já
  vivem. Ver `## Passo a passo`, Passo 4.
- **Task 3 é soft-dependency para o `tenant` real em produção**, não para a
  compilação/teste desta task: o `respond_to?(:tenant)` já degrada para
  `nil`/`DEFAULT_TENANT` mesmo se a task 3 atrasar — mas sem ela, TODO turno
  cairia no mesmo tenant `_default`, o que é paridade funcional (não quebra),
  só não isola por tenant de fato. Sequenciar 1→2→3→4 continua sendo a ordem
  recomendada (tasks.md), mas 4 não trava tecnicamente em 3.
