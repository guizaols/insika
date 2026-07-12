# Task 01 (P2C): `MemoryStore` (profile + notes, scope por tenant)

> **Techspec:** [P2C-01-memory-store-and-read.md](../P2C-01-memory-store-and-read.md) (§MemoryStore, L1–L4) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Criar o `Harness::MemoryStore` — store de domínio sobre `Harness::Store` que
persiste memória cross-session escopada por **tenant**, em duas camadas
determinísticas: `profile` (fatos chave-valor, upsert) e `notes` (anotações
livres, append-only). É a fundação de dados da fatia C: sem ele, nem o read
path (task 4, `Context::Providers::Memory`) nem o write path (task 5,
`Tools::Remember`) têm onde gravar/ler. Nenhum modelo, nenhum vetor — 100%
determinístico e testável mockado (store PURO).

## Dependências

Nenhuma — pode começar já.

## Contexto

O `MemoryStore` **espelha exatamente** o `Harness::PendingActionStore`
(`lib/harness/pending_action_store.rb`, Fase 2-A): store de domínio fino sobre
um `Harness::Store` injetado, que normaliza `symbol → string` na escrita
(`deep_stringify`) e lê por scan O(n) (`list(scope, prefix)` + `get`) — mesma
disciplina, mesmo padrão de records com timestamp de auditoria (`updated_at`
para fatos, `created_at` para notes), mesmo estilo de nomenclatura de chave
(`"<prefixo>:<sufixo>"`).

**D7 do overview — não confundir nomes:** `Harness::Stores::Memory`
(`lib/harness/stores/memory.rb`, Fase 1) é o **backend** KV em memória (uma das
duas implementações de `Harness::Store`, ao lado do SQLite). `Harness::MemoryStore`
(esta task) é o **store de domínio** de memória-do-agente — funciona sobre
QUALQUER backend (Memory ou SQLite) que implemente o contrato `Harness::Store`.
Namespaces diferentes (`Harness::Stores::Memory` vs `Harness::MemoryStore`,
top-level) resolvem a colisão de nome; o comentário no topo da classe deve
deixar isso explícito para quem ler o arquivo isoladamente.

**D1 do overview:** só as camadas `profile` + `notes` nesta fatia — sem
embeddings, sem ranking por similaridade. A camada `semantic` (RFC-0005 §6.1)
é evolução (fatia D) e não faz parte desta task.

**D2 do overview:** escopo é **por tenant** (`memory:<tenant>`), nunca por
`session_id` (anularia o "cross-session") nem por `agent_id` por default. Sem
tenant no Command → scope `memory:_default` (`DEFAULT_TENANT`), documentado
como fallback válido para deployments single-tenant.

Esta task é **puramente de dados** — não hoje se conecta a nenhum `Context
Provider` nem `Tool` (isso vem nas tasks 4 e 5, que dependem desta). O
`MemoryStore` deve poder ser instanciado e testado isoladamente com
`Harness::Stores::Memory.new` como backend, sem tocar em `AgentProfile`,
`Executor` ou wiring.

## Arquivos

| Ação | Arquivo | O quê |
|------|---------|-------|
| CREATE | `lib/harness/memory_store.rb` | `Harness::MemoryStore` — classe completa |
| MODIFY | `lib/harness.rb` | `require_relative "harness/memory_store"`, logo após `require_relative "harness/pending_action_store"` |
| CREATE | `spec/harness/memory_store_spec.rb` | Suíte de contrato do `MemoryStore` |

## Passo a passo

### Passo 1 — Esqueleto da classe + constantes + `Data.define`

Criar `lib/harness/memory_store.rb` com o cabeçalho de comentário (D7),
constantes de scope/prefixo e os dois records (`Fact`, `Note`), seguindo
exatamente o layout do `PendingActionStore`:

**Padrão de referência (codebase) — `PendingActionStore` (topo + records):**
```ruby
# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Store de domínio das AÇÕES PENDENTES de aprovação (P2-02, D2: "estado como
  # record, não flag"). [...]
  #
  # Normaliza symbol→string na ESCRITA (o backend só garante round-trip de
  # tipos JSON, doc 01 §2), como os demais stores de domínio da Fase 1.
  class PendingActionStore
    SCOPE = "pending_actions"
    KEY_PREFIX = "pending:"

    STATUSES = %i[pending approved rejected].freeze

    PendingAction = Data.define(:id, :task_id, :turn, :tool, :args,
                                :status, :requested_at, :resolved_by, :resolved_at)

    def initialize(store:)
      @store = store
    end
```

Adaptar para `MemoryStore`:
```ruby
module Harness
  # Store de domínio de MEMÓRIA-DO-AGENTE cross-session (P2C-01, RFC-0005 §6),
  # escopado por TENANT (D2). Duas camadas determinísticas: `profile` (fatos
  # chave-valor, upsert) e `notes` (anotações livres, append-only). Sem
  # embeddings/ranking (camada semantic é evolução, fatia D).
  #
  # NÃO CONFUNDIR com `Harness::Stores::Memory` (backend KV em memória, Fase 1)
  # — este é o store de DOMÍNIO, funciona sobre QUALQUER `Harness::Store`
  # injetado (Memory ou SQLite). Namespaces distintos resolvem a colisão (D7).
  #
  # Espelha o `PendingActionStore` (Fase 2-A): normaliza symbol→string na
  # escrita (deep_stringify), lê por scan O(n) (list + get), records com
  # timestamp de auditoria.
  class MemoryStore
    SCOPE_PREFIX  = "memory"    # scope efetivo = "memory:<tenant>" (D2)
    FACT_PREFIX   = "fact:"
    NOTE_PREFIX   = "note:"
    DEFAULT_TENANT = "_default" # sem tenant no Command -> scope "memory:_default"

    Fact = Data.define(:key, :value, :updated_at)
    Note = Data.define(:id, :text, :created_at)

    def initialize(store:)
      @store = store
    end
  end
end
```

### Passo 2 — `scope_for` + helpers de chave

Método privado `scope_for(tenant)`, análogo ao `key_for(id)` do
`PendingActionStore`:

```ruby
def scope_for(tenant) = "#{SCOPE_PREFIX}:#{tenant || DEFAULT_TENANT}"

def fact_key(key) = "#{FACT_PREFIX}#{key}"

# `at` (ISO8601) primeiro no sufixo -> list (lexicográfico) devolve as notes
# em ordem cronológica; ties de timestamp quebram pelo `id`.
def note_key(at, id) = "#{NOTE_PREFIX}#{at}:#{id}"
```

### Passo 3 — `put_fact` / `get_fact` / `facts` / `forget_fact`

**Padrão de referência (codebase) — `PendingActionStore#create`/`#find` (escrita + leitura por get direto):**
```ruby
def create(task_id:, turn:, tool:, args: {}, id: SecureRandom.uuid)
  record = {
    "id" => id.to_s,
    "task_id" => task_id.to_s,
    "turn" => turn,
    "tool" => tool.to_s,
    "args" => deep_stringify(args),
    "status" => "pending",
    "requested_at" => timestamp,
    "resolved_by" => nil,
    "resolved_at" => nil
  }
  @store.set(SCOPE, key_for(id), record)
  to_pending(record)
end

def find(id)
  record = @store.get(SCOPE, key_for(id))
  record && to_pending(record)
end
```

Implementar (upsert last-write-wins, D7 do contrato `Store`):

```ruby
# Upsert (last-write-wins, contrato Store). -> Fact
def put_fact(tenant:, key:, value:)
  now = timestamp
  record = { "key" => key.to_s, "value" => deep_stringify(value), "updated_at" => now }
  @store.set(scope_for(tenant), fact_key(key.to_s), record)
  to_fact(record)
end

# -> Fact | nil
def get_fact(tenant:, key:)
  record = @store.get(scope_for(tenant), fact_key(key.to_s))
  record && to_fact(record)
end

# -> [Fact] ordenados por key (list já é lexicográfico -> ordem por key vem de graça)
def facts(tenant:)
  scope = scope_for(tenant)
  @store.list(scope, FACT_PREFIX).filter_map do |k|
    record = @store.get(scope, k)
    record && to_fact(record)
  end
end

# -> bool (existia?)
def forget_fact(tenant:, key:)
  @store.delete(scope_for(tenant), fact_key(key.to_s))
end
```

### Passo 4 — `add_note` / `notes`

**Padrão de referência (codebase) — `PendingActionStore#open_for` (scan O(n) via `list` + `get`, filter_map):**
```ruby
def open_for(task_id)
  id = task_id.to_s
  @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
    record = @store.get(SCOPE, key)
    next if record.nil?

    pa = to_pending(record)
    pa if pa.status == :pending && pa.task_id == id
  end
end
```

Implementar (`at`/`id` injetáveis para determinismo em teste — cf. L1/L2 do
componente):

```ruby
# Append. `at`/`id` injetáveis p/ teste determinístico. -> Note
def add_note(tenant:, text:, id: SecureRandom.uuid, at: nil)
  created_at = at || timestamp
  record = { "id" => id.to_s, "text" => text.to_s, "created_at" => created_at }
  @store.set(scope_for(tenant), note_key(created_at, id), record)
  to_note(record)
end

# -> [Note] MAIS RECENTES primeiro, capadas por `limit`
def notes(tenant:, limit: nil)
  scope = scope_for(tenant)
  ordered = @store.list(scope, NOTE_PREFIX).filter_map do |k|
    record = @store.get(scope, k)
    record && to_note(record)
  end
  recent_first = ordered.reverse
  limit ? recent_first.take(limit) : recent_first
end
```

> Atenção: `text` NÃO passa por `deep_stringify` porque é sempre uma String
> (não um Hash/Array aninhado) — mas normalize com `.to_s` na escrita
> (paridade com `tool.to_s` no `PendingActionStore`, defensivo contra Symbol
> acidental).

### Passo 5 — conversores privados + `deep_stringify` + `timestamp`

**Padrão de referência (codebase) — conversor + normalização + timestamp:**
```ruby
private

def to_pending(record)
  PendingAction.new(
    id: record["id"],
    # ...
  )
end

def timestamp = Time.now.utc.iso8601

def deep_stringify(obj)
  case obj
  when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
  when Array then obj.map { |v| deep_stringify(v) }
  when Symbol then obj.to_s
  else obj
  end
end
```

Implementar `to_fact`, `to_note` (símiles de `to_pending`), reusar
`deep_stringify`/`timestamp` tal qual (copiar o método privado — o
`MemoryStore` não herda do `PendingActionStore`, cada store de domínio é
independente por design nesta fatia, igual aos demais stores da Fase 1).

```ruby
private

def to_fact(record)
  Fact.new(key: record["key"], value: record["value"], updated_at: record["updated_at"])
end

def to_note(record)
  Note.new(id: record["id"], text: record["text"], created_at: record["created_at"])
end

def timestamp = Time.now.utc.iso8601

def deep_stringify(obj)
  case obj
  when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
  when Array then obj.map { |v| deep_stringify(v) }
  when Symbol then obj.to_s
  else obj
  end
end
```

### Passo 6 — requer em `lib/harness.rb`

**Padrão de referência (codebase) — `lib/harness.rb` (trecho atual):**
```ruby
require_relative "harness/store"
require_relative "harness/stores/memory"
require_relative "harness/stores/sqlite"
require_relative "harness/session_store"
require_relative "harness/task_store"
require_relative "harness/checkpoint_store"
require_relative "harness/pending_action_store"
require_relative "harness/recovery"
```

Adicionar logo após `pending_action_store` (mesma vizinhança de stores de
domínio da Fase 1/2-A):
```ruby
require_relative "harness/pending_action_store"
require_relative "harness/memory_store"
require_relative "harness/recovery"
```

## Edge cases

- **Tenant `nil`** → `scope_for(nil)` cai em `"memory:_default"`
  (`DEFAULT_TENANT`); `tenant: ""` (string vazia) NÃO cai no fallback (é um
  tenant válido, ainda que estranho) — só `nil` aciona o `||`.
- **Upsert de fato** → `put_fact` chamado duas vezes com a mesma `key`
  sobrescreve (last-write-wins, contrato `Store`); `updated_at` reflete
  SEMPRE a última escrita, nunca a primeira.
- **Ordenação de notes** → depende inteiramente da posição do `at` (ISO8601)
  no INÍCIO do sufixo da note key (`note:<at>:<id>`) — é isso que faz
  `list` (lexicográfico) devolver ordem cronológica. Se dois `add_note` usarem
  o MESMO `at` (injetado em teste), o desempate é pelo `id` (sufixo) — sem
  garantia de ordem "de inserção" nesse caso raro, só de ordem de key.
- **Normalização symbol→string** → `put_fact(key: :plano, value: {tipo: :premium})`
  deve voltar com `key == "plano"` e `value == {"tipo" => "premium"}`
  (`deep_stringify` recursivo, igual ao `PendingActionStore`).
- **Scan O(n)** → `facts`/`notes` fazem `list` + `get` por chave (aceitável
  single-node Fase 1/2, RFC-0006 §5) — não há índice secundário; não otimizar
  prematuramente (mesma decisão do `PendingActionStore#open_for`).
- **Isolamento por tenant** → `facts(tenant: "a")` NUNCA deve enxergar dado
  gravado com `tenant: "b"` — scopes diferentes (`memory:a` vs `memory:b`) no
  backend `Store`, isolamento vem de graça do contrato (`list(scope)` só
  retorna chaves do próprio scope).
- **`notes(limit:)` maior que o total de notes** → devolve todas, sem erro
  (comportamento de `Array#take`).
- **`forget_fact` de key inexistente** → `false` (contrato `Store#delete`:
  "existia?"), sem levantar exceção.

## Testes

**Arquivo:** `spec/harness/memory_store_spec.rb`

Instanciar com `Harness::Stores::Memory.new` como backend (mesmo padrão do
`spec/harness/pending_action_store_spec.rb`).

| Caso | O que testa | Esperado |
|------|-------------|----------|
| `put_fact` + `get_fact` | grava e recupera um fato | `Fact` com `key`/`value`/`updated_at` preenchidos |
| `get_fact` de key ausente | leitura de fato inexistente | `nil` |
| `put_fact` duas vezes (mesma key) | upsert last-write-wins | `get_fact` devolve o ÚLTIMO `value`; `updated_at` do último write |
| `facts` com múltiplos fatos | ordenação | devolve `[Fact]` ordenados por `key` (ordem lexicográfica) |
| `forget_fact` de key existente | remoção | devolve `true`; `get_fact` depois devolve `nil` |
| `forget_fact` de key ausente | remoção idempotente | devolve `false` |
| `add_note` + `notes` (múltiplas, `at` injetado) | ordem de leitura | `notes` devolve MAIS RECENTE primeiro (reverso de `at`) |
| `notes(limit: N)` | cap de contagem | devolve só as `N` mais recentes |
| `notes` sem nenhuma note gravada | caso vazio | `[]` |
| Isolamento por tenant | `put_fact`/`add_note` em tenant A não vaza pro B | `facts`/`notes` do tenant B não incluem dado do tenant A |
| `tenant: nil` | fallback `_default` | grava/lê no MESMO scope que `tenant: "_default"` explícito |
| Round-trip de tipos (symbol→string) | `deep_stringify` na escrita | `put_fact(key: :plano, value: {tipo: :premium})` → `get_fact` devolve `key == "plano"`, `value == {"tipo" => "premium"}` |

## Definition of Done

- [ ] `lib/harness/memory_store.rb` criado com `put_fact`/`get_fact`/`facts`/`forget_fact`/`add_note`/`notes`
- [ ] `lib/harness.rb` requer `memory_store` (logo após `pending_action_store`)
- [ ] `spec/harness/memory_store_spec.rb` cobre todos os casos da tabela acima
- [ ] Suíte verde sem chave de API (store PURO — `Stores::Memory` como backend, zero rede/modelo)
- [ ] Code review

## Notas

- Nomenclatura: `Harness::MemoryStore` (esta task, domínio) **≠**
  `Harness::Stores::Memory` (Fase 1, backend KV) — ver D7 do overview. Não
  renomear nenhum dos dois; a distinção de namespace + comentário no topo do
  arquivo é a mitigação combinada.
- Esta task **NÃO cobre** a camada `semantic` (embeddings/índice vetorial,
  RFC-0005 §6.1) — isso é evolução explícita da fatia D, fora de escopo aqui e
  de toda a fatia C (ver "Não faz" no `00-overview.md`).
- Esta task também não cabeia `AgentProfile.memory` (task 2), threading de
  `tenant` no Executor (task 3), o `Context::Providers::Memory` (task 4) nem
  `Tools::Remember` (task 5, P2C-02) — é só a fundação de dados; as tasks
  seguintes consomem esta interface.
