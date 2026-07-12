# P2C-01 — `MemoryStore` + read path (`Context::Providers::Memory`)

> **RFC base:** 0005 §6 (Memory: camadas, read path), 0006 (Stores).
> **Evolui:** `lib/harness/agent_profile.rb`, `lib/harness/executor.rb`.
> **Novo:** `lib/harness/memory_store.rb`, `lib/harness/context/providers/memory.rb`.
> **Overview:** D1, D2, D5, D6, D7.

## Objetivo

Persistir e recuperar memória cross-session escopada por tenant, em duas camadas
determinísticas (`profile` + `notes`), e injetá-la no contexto do turno via um
Context Provider — sem modelo, sem vetor. É a metade de LEITURA da fatia (a
escrita é P2C-02).

## `MemoryStore` (`lib/harness/memory_store.rb`)

Espelha o `PendingActionStore` (store de domínio sobre `Harness::Store`:
normaliza symbol→string na escrita, scan O(n) na leitura). **NÃO** confundir com
`Harness::Stores::Memory` (backend KV em memória) — este é o store de DOMÍNIO de
memória-do-agente, sobre um `Harness::Store` qualquer (D7).

```ruby
module Harness
  class MemoryStore
    SCOPE_PREFIX = "memory"           # scope = "memory:<tenant>" (D2)
    FACT_PREFIX  = "fact:"
    NOTE_PREFIX  = "note:"
    DEFAULT_TENANT = "_default"       # sem tenant no Command (D2)

    Fact = Data.define(:key, :value, :updated_at)
    Note = Data.define(:id, :text, :created_at)

    def initialize(store:)

    # Upsert (last-write-wins, contrato Store D7). -> Fact
    def put_fact(tenant:, key:, value:)
    def get_fact(tenant:, key:)                 # -> Fact | nil
    def facts(tenant:)                          # -> [Fact] ordenados por key (list lexicográfico)
    def forget_fact(tenant:, key:)              # -> bool (existia?)

    # Append. `at`/`id` injetáveis p/ teste determinístico. -> Note
    def add_note(tenant:, text:, id: SecureRandom.uuid, at: nil)
    def notes(tenant:, limit: nil)              # -> [Note] MAIS RECENTES primeiro, capadas
  end
end
```

### Decisões

- **L1 — scope por tenant.** `scope_for(tenant) = "#{SCOPE_PREFIX}:#{tenant || DEFAULT_TENANT}"`.
  Fact key = `"fact:<key>"`; Note key = `"note:<at>:<id>"`. O `at` (ISO8601) no
  começo da NOTE key faz `list` (lexicográfico) devolver as notes em ordem
  **cronológica** — `notes(limit:)` = `list.reverse.take(limit)` (mais recentes
  primeiro), determinístico. Ties de timestamp quebram pelo `id` no sufixo da key.
- **L2 — records, não valores crus.** `Fact`/`Note` guardam `updated_at`/`created_at`
  (auditoria), como o `PendingAction`. `put_fact` sobrescreve (upsert) — o
  `updated_at` reflete a última escrita.
- **L3 — normaliza symbol→string na escrita** (o backend só garante round-trip de
  tipos JSON, contrato Store) — `deep_stringify` como no `PendingActionStore`.
- **L4 — leitura por scan O(n)** (`list(scope, prefix)` + `get`), single-node
  Fase 1/2 (RFC-0006 §5), igual `PendingActionStore#open_for`.

### Suíte de contrato (`spec/harness/memory_store_spec.rb`)

Roda sobre `Stores::Memory` real (e idealmente `Stores::SQLite` via shared
examples, como os outros stores). Casos: put/get/upsert de fato; `facts` ordenado
por key; `forget_fact`; `add_note` + `notes` mais-recentes-primeiro; `limit` capa;
isolamento por tenant (tenant A não vê memória de B); tenant nil → `_default`;
round-trip de tipos (symbol→string).

## `AgentProfile.memory` (opt-in, D5)

```ruby
# memory: opt-in de memória cross-session (P2C, RFC-0005 §6). nil/false =
# desligado (paridade Fase 1 — provider retorna [], tool `remember` não cabeada);
# true = ligado.
AgentProfile = Data.define(..., :memory)   # + build(memory: nil)
```
> Mesma assimetria opt-in de `capabilities`/`tools_deferred`: `nil` = OFF, não "todos".

## Threading de tenant (D6)

O objeto que os providers REALMENTE recebem é o `Executor::ContextRequest`
(Struct, `executor.rb:326`) — que hoje **não** tem `tenant` (débito Fase 1: o
`Request` provider já chama `request.tenant`). Esta fatia:

1. Adiciona `:tenant` ao Struct `Executor::ContextRequest`.
2. `build_context_request` popula `tenant: command_tenant(task)`.
3. Novo helper privado:
   ```ruby
   # tenant vem do Command (Command.build(..., tenant:) -> meta[:tenant],
   # command.rb:21). Ausente -> nil (o MemoryStore aplica DEFAULT_TENANT).
   def command_tenant(task)
     meta = rebuild_command(task).meta
     meta["tenant"] || meta[:tenant]
   end
   ```
4. `run_pipeline` guarda o mesmo valor no `TurnState` (`state.tenant =
   command_tenant(task)`, novo `attr_accessor :tenant`) para o `remember` tool
   (P2C-02) usar o MESMO scope no write path.

Não reabrimos o seam `vars` — só `tenant`, que é o necessário aqui.

## `Context::Providers::Memory` (`lib/harness/context/providers/memory.rb`)

Espelha o `Skill`/`ToolSearch` provider (adaptador fino, fragmento `:system`):

```ruby
module Harness
  module Context
    module Providers
      class Memory < ContextProvider
        def initialize(store:, notes_limit: 10)
          @store = store
          @notes_limit = notes_limit
        end

        # Opt-in por agente (D5). Além disto, o Builder ainda aplica a allowlist
        # `context_providers` do perfil (dois gates, como os demais providers).
        def enabled_for?(profile) = !!profile.memory

        def call(request)
          tenant = request.respond_to?(:tenant) ? request.tenant : nil
          facts = @store.facts(tenant: tenant)
          notes = @store.notes(tenant: tenant, limit: @notes_limit)
          return [] if facts.empty? && notes.empty?

          [ContextFragment.build(content: format_block(facts, notes),
                                 placement: :system, priority: 75, source: id)]
        end
      end
    end
  end
end
```

### Decisões

- **L5 — priority 75** (entre skills=80 e tool search=70). Ordem de sacrifício:
  identidade(pinned) → skills(80) → **memória(75)** → tools deferred(70) →
  histórico. Memória é fato do usuário: sobrevive mais que o catálogo de tools,
  menos que skills. `pinned: false` (é cortável sob orçamento apertado).
- **L6 — recuperação da entrada:** **todos** os fatos (conjunto pequeno, k/v) +
  as **`notes_limit` notes mais recentes**. Sem ranking por similaridade (D1). O
  orçamento fino é do Builder (evicção por priority) + o cap de contagem de notes.
- **L7 — `required? == false`** (default): falha do provider (ex.: store
  indisponível) → `:provider_warning` + degradação graciosa (o turno segue sem
  memória), nunca aborta. D4 do overview.
- **L8 — formato `<memory>`:** análogo ao `<available_skills>`/`<available_tools>`:
  ```
  <memory>
    <fact key="plano">premium</fact>
    <note>cliente prefere email</note>
  </memory>
  ```
  Sem instrução extra (diferente do Skill, que manda "chame load_skill") — a
  memória é contexto passivo; a instrução de COMO gravar vive na descrição da
  tool `remember` (P2C-02).

## Testes (fazem parte de cada task)

- **`MemoryStore`** (puro, sem gem): suíte de contrato acima.
- **`AgentProfile.memory`**: default nil; valor true; retrocompat.
- **Threading de tenant** (`executor` unit): `build_context_request` popula
  `tenant`; `command_tenant` extrai do Command; `state.tenant` setado no
  `run_pipeline`. Fake tenant no Command → chega ao provider.
- **`Context::Providers::Memory`**: `enabled_for?` gate por `profile.memory`;
  fragmento `:system` priority 75 == format(facts, notes); `[]` quando vazio OU
  quando memory off; `notes_limit` respeitado; tenant repassado ao store.

## Fora de escopo (fatia D)

Camada semantic (embeddings/vetor); extractor pós-turno por LLM; múltiplos
escopos além de tenant; TTL/expiração de notes; UI de memória no `/admin`.
