# P2C-02 — `Tools::Remember` (write) + integração no Executor + wiring

> **RFC base:** 0005 §6 (write path), 0002 §6 (Tool Execution / builtin de sistema).
> **Evolui:** `lib/harness/executor.rb`, `config/wiring.rb`, `lib/harness/event.rb`,
> `docs/techspec/00-overview.md`. **Novo:** `lib/harness/tools/remember.rb`.
> **Overview:** D3, D4, D8.

## Objetivo

Dar ao agente o meio de GRAVAR memória sob demanda (fato ou note), de forma
determinística (sem LLM), e ligar a fatia inteira no composition root. É a metade
de ESCRITA + o fechamento da fatia C.

## `Tools::Remember` (`lib/harness/tools/remember.rb`)

Builtin `RubyLLM::Tool` — mesmo padrão de `load_skill`/`tool_search` (require
lazy da gem, `def name` explícito, wired de SISTEMA no `configure_chat`).

```ruby
require "ruby_llm"

module Harness
  module Tools
    class Remember < RubyLLM::Tool
      description "Guarda uma informação para lembrar em conversas futuras. " \
                  "Use `key` para um fato durável chave-valor (sobrescreve o " \
                  "anterior); omita `key` para uma anotação livre."
      param :value, desc: "O conteúdo a lembrar"
      param :key, desc: "Chave do fato (ex.: 'plano', 'nome'); omita para uma nota", required: false

      def name = "remember"   # senão RubyLLM deriva "harness--tools--remember" (P2B-02 L7)

      def initialize(store, tenant, event_stream:, state:)
        @store = store
        @tenant = tenant
        @event_stream = event_stream
        @state = state
        super()
      end

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

      private

      def emit(kind, ref)
        @event_stream.emit(Harness::Event.new(
                             type: :memory_written,
                             data: { kind: kind.to_s, key: ref },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end
    end
  end
end
```

### Decisões

- **L1 — uma tool, dois modos** (D3): `key` presente → fato (upsert); ausente →
  note. Evita duas tools quase-idênticas. `param :key` é `required: false`.
- **L2 — nunca envelopada** (tool de sistema, como `load_skill`/`tool_search`):
  sem side-effect de negócio a checkpointar (o write é idempotente-por-key p/
  fatos; notes são append — reexecução no resume duplicaria uma note, ver L5).
- **L3 — `def name = "remember"`** — o mesmo fix de nome derivado da classe
  (P2B-02 L7, verificado).
- **L4 — emite `:memory_written { kind, key }`** (D4/D8) — simétrico ao
  `:tool_search`. `key` = a chave do fato ou o id da note.
- **L5 — resume/idempotência (limitação registrada):** `remember` NÃO é
  envelopada, então não participa do `skip_side_effects`. Um fato é
  idempotente-por-key (reescrever "premium" é no-op efetivo). Uma **note** é
  append: se o turno crashar após a note e for retomado, a note pode duplicar. É
  aceitável nesta fatia (memória não é transação de negócio) e fica documentado —
  o fix (envelopar `remember` como side-effect) é evolução se necessário.

## Integração no Executor (`executor.rb`)

- Novo `@memory_store` no construtor (default `nil` → sem memória, paridade).
- `run_pipeline`: `state.tenant = command_tenant(task)` (helper de P2C-01, D6) —
  já necessário para o provider; o tool reusa.
- `configure_chat`: cabeia `Tools::Remember` como tool de SISTEMA quando
  `@memory_store` presente E `profile.memory` — ao lado de `load_skill`/
  `tool_search`, nunca envelopada:
  ```ruby
  if @memory_store && state.profile.memory
    tools << Tools::Remember.new(@memory_store, state.tenant,
                                 event_stream: @event_stream, state: state)
  end
  ```
- `create_chat`: `require_relative "tools/remember"` lazy (como load_skill/tool_search).

O gate duplo (`@memory_store` presente + `profile.memory`) espelha o Tool Search
(`@tool_catalog` + `tools_deferred`) — paridade Fase 1 por omissão de qualquer um
dos dois.

## Wiring (`config/wiring.rb`)

```ruby
# --- Memória cross-session (P2C, RFC-0005 §6) sobre o BACKEND durável -----
MEMORY_STORE = Harness::MemoryStore.new(store: BACKEND)
```
- `CONTEXT_PROVIDERS`: acrescentar `Context::Providers::Memory.new(store: MEMORY_STORE)`
  (inerte p/ agentes sem `memory` via `enabled_for?`).
- `EXECUTOR.new(...)`: `memory_store: MEMORY_STORE`.
- `MEMORY_STORE` usa `BACKEND` (SQLite quando `HARNESS_DB` setado — memória
  durável, sobrevive a restart; Memory efêmero em dev), consistente com os demais
  stores de domínio.

## Catálogo de eventos D5 (D8)

Estender `docs/techspec/00-overview.md` (tabela D5) e o doc-comment de
`lib/harness/event.rb`:
```markdown
| `:memory_written` | `{ kind, key }` | Tools::Remember (P2C) |
```

## Smoke E2E (`spec/e2e/smoke_phase2c_spec.rb`)

Mesmo padrão do `smoke_phase2b_spec.rb` (CommandBus + SendMessage + Executor +
stores REAIS, só o chat mockado). Cenários (critérios de conclusão):

1. **Grava fato na sessão 1** — agente `memory:true` chama `remember(key:
   "plano", value: "premium")`; `:memory_written { kind: "fact", key: "plano" }`
   emitido; `MemoryStore.get_fact(tenant:, key: "plano").value == "premium"`.
2. **Lembra na sessão 2** — novo turno (mesmo tenant), o `system` do chat
   (capturado no script do `FakeChat`) inclui `<memory>` com `plano=premium`.
3. **Note** — `remember(value: "prefere email")` sem key → `:memory_written {
   kind: "note" }`; a note aparece no contexto do turno seguinte.
4. **Paridade** — agente `memory:nil` não recebe `<memory>` no system nem a tool
   `remember` no chat.

> Tenant no smoke: `Command.build(:send_message, payload, tenant: "acme")` — prova
> o threading D6 ponta a ponta.

## Testes

- **`Tools::Remember`** (unit, sem gem no núcleo — herda de RubyLLM::Tool, então
  spec requer a gem como load_skill/tool_search): grava fato via store; grava note
  sem key; emite `:memory_written` com kind/key corretos; `def name`.
- **Executor `configure_chat`**: `remember` cabeada só com `@memory_store` +
  `profile.memory`; nunca envelopada; ausência de qualquer gate → sem tool
  (paridade).
- **Wiring load**: `MEMORY_STORE` construído; provider em `CONTEXT_PROVIDERS`;
  `EXECUTOR` aceita `memory_store:`.
- **Smoke E2E**: os 4 cenários acima.

## Fora de escopo (fatia D)

Extractor automático por LLM; envelopamento de `remember` (resume-safety de
notes); tela de memória no `/admin`; `forget`/edição via tool.
