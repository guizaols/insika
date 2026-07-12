# Task 05 (P2C): `Tools::Remember` (write path)

> **Techspec:** [P2C-02-remember-tool-and-wiring.md](../P2C-02-remember-tool-and-wiring.md) (§Tools::Remember, L1–L5) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Med · **Etapa:** B

## Objetivo

Criar `Harness::Tools::Remember`: a builtin de SISTEMA que dá ao agente o meio
de GRAVAR memória sob demanda — um fato durável chave-valor ou uma nota livre
— de forma **determinística** (sem LLM, D3). É a metade de ESCRITA da fatia
(a leitura já foi resolvida pelas tasks 1–4 via `Context::Providers::Memory`).
Esta task cria só a classe da tool e seu spec isolado; a integração no
`Executor#configure_chat` (cabear a tool, gate `@memory_store` + `profile.memory`,
`require_relative` lazy) é a **task 6** — ver "Coordenação" nas Notas.

## Dependências

| Task | Componente | Motivo |
|---|---|---|
| Task 01 | `MemoryStore` (`lib/harness/memory_store.rb`) | fornece `put_fact(tenant:, key:, value:)` e `add_note(tenant:, text:)` — os dois métodos que `Remember#execute` chama. Sem o store não há onde persistir nem o que injetar no construtor. |

Não depende das tasks 2/3/4 (Etapa A — `AgentProfile.memory`, threading de
tenant, provider de leitura) nem da task 6 (wiring no Executor): os specs
desta task constroem `Remember` isoladamente, com um `tenant` literal e uma
`MemoryStore` real sobre `Stores::Memory`, sem precisar do perfil, do
`ContextRequest` ou do `configure_chat` de verdade.

## Contexto

### Builtin de sistema, mesmo padrão de `load_skill`/`tool_search`

`Tools::Remember` é uma terceira instância do MESMO padrão já estabelecido em
`lib/harness/tools/load_skill.rb` (Fase 0) e `lib/harness/tools/tool_search.rb`
(Fase 2-B): uma classe `RubyLLM::Tool` que **não** entra em `lib/harness.rb`
porque `require "ruby_llm"` fica no próprio arquivo — o Executor a carrega
lazy dentro de `create_chat`/`configure_chat` (D9, task 6), nunca no boot do
núcleo. Isso mantém o núcleo (`lib/harness.rb`) livre da gem para quem não usa
tools (paridade).

### Escrita determinística (D3) — sem envelope, sem LLM

Diferente das tools de negócio do agente (que passam por `ToolEnvelope` para
side-effects/resume-safety, fatia 2-B), `remember` é uma tool de SISTEMA: o
`write` é síncrono, sem custo de rede, e **nunca é envelopada** — não há
`ToolEnvelope`/`checkpoint_store`/`skip_side_effects` no construtor, ao
contrário de `Tools::ToolSearch` (que embrulha as tools que PROMOVE, mas ela
mesma também não é envelopada). Um fato é idempotente-por-key (reescrever é
no-op efetivo); uma note é append — a implicação de resume-safety disso está
documentada em L5 (ver `## Notas`), não é bloqueio desta task.

### Uma tool, dois modos (L1)

`key` presente → fato (upsert, sobrescreve o anterior); `key` ausente/vazia →
nota livre (append). Evita duas tools quase-idênticas expostas ao modelo —
mesma decisão de design que unificou `Tools::LoadSkill` num único ponto de
entrada por nome.

### `def name` explícito (L3, P2B-02 L7)

`RubyLLM::Tool#name` deriva de `self.class.name` quando não overridden — para
uma classe aninhada (`Harness::Tools::Remember`) isso produz
`"harness--tools--remember"`, não `"remember"` (verificado com `LoadSkill`/
`ToolSearch`, P2B-02 L7). Sem o override, o modelo não consegue chamar a tool
pelo nome que a `description` e o resto do sistema assumem. Esta task **deve**
definir `def name = "remember"` explicitamente — não repetir o bug latente.

### Emite `:memory_written { kind, key }` (L4, D4/D8)

Simétrico ao `:tool_search` emitido por `Tools::ToolSearch` (mesmo padrão:
emitido pela PRÓPRIA tool, que recebe `event_stream:`/`state:` no construtor,
não por `wire_callbacks`). `key` no evento é a chave do fato OU o `id` da
note — o nome do campo é sempre `key` nos dois casos (união de modos, não dois
esquemas de evento).

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/tools/remember.rb` | CREATE | `Harness::Tools::Remember < RubyLLM::Tool` — write determinístico (fato/note) + evento |
| `spec/harness/tools/remember_spec.rb` | CREATE | specs unitários: fato via store real, note, evento, `def name` |

## Passo a passo

### Passo 1 — esqueleto da classe, DSL da gem, override de `#name`

`require "ruby_llm"` fica NESTE arquivo (herda de `RubyLLM::Tool`), por isso
`Tools::Remember` **não** entra em `lib/harness.rb` — o Executor a carrega
lazy dentro de `configure_chat`/`create_chat` (task 6, mesma disciplina D9 do
`load_skill`/`tool_search`).

**Padrão de referência (codebase) — `Tools::LoadSkill` inteiro** (o mesmo
esqueleto: `require` lazy, DSL `description`/`param`, `def name` explícito,
allowlist/deps recebidas no construtor):

```ruby
# lib/harness/tools/load_skill.rb (arquivo completo, referência)
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    class LoadSkill < RubyLLM::Tool
      description "Carrega as instruções completas (SKILL.md) de uma skill pelo nome"
      param :name, desc: "Nome exato da skill, conforme listado em <available_skills>"

      def name = "load_skill"

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

**Padrão de referência (codebase) — `Tools::ToolSearch` inteiro** (a mesma
disciplina, mas já mostra o padrão de emitir evento pela PRÓPRIA tool via
`event_stream:`/`state:` no construtor — exatamente o que `Remember` precisa
para `:memory_written`):

```ruby
# lib/harness/tools/tool_search.rb (arquivo completo, referência)
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    class ToolSearch < RubyLLM::Tool
      description "Busca e habilita ferramentas adicionais por descrição da necessidade"
      param :query, desc: "O que você precisa fazer (ex.: 'enviar email', 'gerar fatura')"

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
        @promoted = []
        super()
      end

      # ... execute/promote/describe (ver arquivo real para o resto)

      private

      def emit_tool_search(query, matched_names)
        @event_stream.emit(Harness::Event.new(
                             type: :tool_search,
                             data: { query: query, matched: matched_names },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end
    end
  end
end
```

Esqueleto de `Remember` (Passo 1 propriamente dito):

```ruby
# lib/harness/tools/remember.rb — esqueleto (Passo 1)
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    class Remember < RubyLLM::Tool
      description "Guarda uma informação para lembrar em conversas futuras. " \
                  "Use `key` para um fato durável chave-valor (sobrescreve o " \
                  "anterior); omita `key` para uma anotação livre."
      param :value, desc: "O conteúdo a lembrar"
      param :key, desc: "Chave do fato (ex.: 'plano', 'nome'); omita para uma nota", required: false

      # RubyLLM::Tool#name deriva de self.class.name — p/ classe aninhada
      # (Harness::Tools::Remember) produz "harness--tools--remember", não
      # "remember" (P2B-02 L7, mesmo defeito já corrigido em LoadSkill/ToolSearch).
      def name = "remember"

      def initialize(store, tenant, event_stream:, state:)
        @store = store
        @tenant = tenant
        @event_stream = event_stream
        @state = state
        super()
      end
    end
  end
end
```

### Passo 2 — `execute`: dois modos (fato vs note)

`key.to_s.strip.empty?` decide o modo — trata `nil`, `""` e `"   "` (só
espaço) igualmente como "sem key" (evita um agente acidentalmente criar um
fato com chave em branco por mandar `key: "  "`):

```ruby
def execute(value:, key: nil)
  if key.to_s.strip.empty?
    note = @store.add_note(tenant: @tenant, text: value.to_s)
    emit(:note, note.id)
    { remembered: "note", id: note.id }
  else
    @store.put_fact(tenant: @tenant, key: key.to_s, value: value.to_s)
    emit(:fact, key.to_s)
    { remembered: "fact", key: key.to_s }
  end
end
```

`value.to_s`/`key.to_s` normalizam symbol/nil como o resto do sistema já faz
(`MemoryStore#put_fact`/`add_note` recebem string; `deep_stringify` é
responsabilidade do STORE, mas a tool não deve depender disso — passar string
já normalizada é mais barato de raciocinar no spec).

### Passo 3 — evento `:memory_written`

Espelha `emit_tool_search` do `ToolSearch` (Passo 1, referência acima):

```ruby
private

def emit(kind, ref)
  @event_stream.emit(Harness::Event.new(
                       type: :memory_written,
                       data: { kind: kind.to_s, key: ref },
                       meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                     ))
end
```

Note que o campo do evento é sempre `key` nos dois modos (fato: a chave real;
note: o `id` gerado por `MemoryStore#add_note`) — um único esquema `{ kind,
key }`, não dois payloads distintos por modo. `kind` é sempre string
(`"fact"`/`"note"`) mesmo passando um Symbol em `emit(:fact, ...)`.

## Edge cases

- **`key` ausente (`nil`) ou string vazia/só-espaço (`""`, `"  "`)** → modo
  note. `key.to_s.strip.empty?` cobre os três casos com uma única checagem —
  não usar só `key.nil?` (deixaria `key: ""` cair no modo fato com uma chave
  vazia, que o `MemoryStore` aceitaria mas não faz sentido semântico).
- **`key` presente (mesmo repetida)** → sempre modo fato, sempre upsert
  (`put_fact` sobrescreve — comportamento do store, task 1, não desta task).
  Chamar duas vezes com a mesma `key` e valores diferentes não deve criar dois
  registros nem duplicar o evento além de uma emissão por chamada.
- **`:memory_written` — `kind`/`key` corretos por modo:** fato →
  `{ kind: "fact", key: <a key passada> }`; note → `{ kind: "note", key: <id
  gerado pelo store> }`. O evento é emitido em AMBOS os modos, sempre uma vez
  por `execute`.
- **`value` vazio (`""`) ou só espaço:** não é tratado como erro — grava o
  fato/note com valor vazio mesmo assim (a tool não valida conteúdo
  semântico, só decide o MODO a partir de `key`; validação de "vale a pena
  lembrar isso" é responsabilidade do modelo/prompt, não desta tool
  determinística).
- **`def name` evita `"harness--tools--remember"`:** sem o override, o nome
  derivado da classe aninhada quebraria qualquer chamada do modelo à tool
  (mesma classe de bug já corrigida em `LoadSkill`/`ToolSearch`, P2B-02 L7) —
  coberto por spec explícito, não só assumido.

## Testes

**Arquivo:** `spec/harness/tools/remember_spec.rb`

Usa uma `Harness::MemoryStore` REAL sobre `Harness::Stores::Memory` (backend
em memória, task 1) — não um double do store: o valor do teste está em provar
que o fato/note realmente aparece no store depois de `execute`, não só que
`put_fact`/`add_note` foram chamados. O `event_stream` pode ser um fake
mínimo (mesmo padrão de `spec/harness/tools/tool_search_spec.rb`: um objeto
com `emit(e)` que empilha num Array, sem precisar do `Harness::EventStream`
real com fibers/Async).

| Cenário | Expectativa |
|---|---|
| `execute(value:, key: "plano")` | `store.get_fact(tenant:, key: "plano").value == <value>`; retorno `{ remembered: "fact", key: "plano" }` |
| `execute(value:)` sem `key` | `store.notes(tenant:).first.text == <value>`; retorno `{ remembered: "note", id: <id do Note> }` |
| `key: ""` / `key: "   "` | cai no modo note (mesmo comportamento de `key` ausente) |
| segunda chamada com a mesma `key`, valor diferente | `store.get_fact` reflete o ÚLTIMO valor (upsert); não cria dois fatos |
| evento no modo fato | `event_stream` recebe `Harness::Event` `:memory_written` com `data: { kind: "fact", key: "plano" }` e `meta[:task_id]`/`meta[:session_id]` corretos (do `state.task`) |
| evento no modo note | `data: { kind: "note", key: <id do Note> }` |
| isolamento por tenant | `execute` com `tenant: "acme"` não aparece em `store.facts(tenant: "outro")` (delega ao contrato do `MemoryStore`, task 1 — vale a pena um caso aqui para pegar um `@tenant` mal-fiado no construtor) |
| `def name` | `described_class.new(...).name == "remember"` (não o default derivado da classe) |

## Definition of Done

- [ ] `Tools::Remember` criada em `lib/harness/tools/remember.rb`, herdando
      `RubyLLM::Tool`, com `require "ruby_llm"` NESTE arquivo (não em
      `lib/harness.rb`)
- [ ] `def name = "remember"` presente e coberto por spec
- [ ] `key` vazia/whitespace/ausente → modo note; `key` presente → modo fato
      (upsert), com `value`/`key` normalizados para string
- [ ] `:memory_written { kind, key }` emitido em ambos os modos, com `meta`
      correto (`task_id`/`session_id` de `state.task`)
- [ ] Grava de fato no `MemoryStore` real (não só chamada de método —
      verificado lendo de volta via `get_fact`/`notes`)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**L5 — resume-safety (limitação registrada, não resolvida aqui):**
`Tools::Remember` NÃO é envelopada em `ToolEnvelope` (é uma tool de sistema,
como `load_skill`/`tool_search`), então não participa de `skip_side_effects`.
Um fato é idempotente-por-key (reescrever o mesmo valor é no-op efetivo — a
segunda escrita apenas sobrescreve com o mesmo conteúdo). Uma **note é
append**: se o turno crashar logo após `add_note` retornar e o turno for
retomado (resume), a note pode ser gravada de novo, duplicando-a no histórico
de memória. Isso é aceitável nesta fatia — memória não é uma transação de
negócio (cobrar duas vezes, por exemplo) — e fica documentado como concern
conhecido (`tasks.md`, "Concerns registrados"); envelopar `remember` como
side-effect é evolução futura, fora do escopo desta task.

**Coordenação com a task 6:** esta task só cria a classe e o spec isolado.
Cabear `Tools::Remember` dentro de `Executor#configure_chat` (gate duplo
`@memory_store` presente + `profile.memory`, ao lado de `load_skill`/
`tool_search`, nunca envelopada) e o `require_relative "tools/remember"` lazy
em `create_chat` são responsabilidade da task 6 — não adiantar essa integração
aqui para não colidir no mesmo arquivo (`executor.rb`) que a task 3 também
edita (ver aviso de coordenação em `tasks.md`).
