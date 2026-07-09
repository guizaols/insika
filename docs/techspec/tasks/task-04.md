# Task 04: Backend `Stores::SQLite` (WAL, tabela `kv`, semáforo de escrita)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [01-persistence-stores.md](../01-persistence-stores.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Implementar `Harness::Stores::SQLite` — backend default de produção (RFC-0006 §3) com tabela única `kv`, WAL, `busy_timeout`, transações `BEGIN IMMEDIATE` serializadas por `Async::Semaphore` e `require "sqlite3"` lazy — passando a mesma suíte de contrato da task 2 mais os testes de durabilidade/WAL/concorrência do doc 01 §7.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 2 | Interface `Harness::Store` + suíte de contrato compartilhada (shared examples) | ⬜ TODO |

(Grafo do tasks.md: `4 (SQLite) → 2`. A task 3 é irmã, não dependência — mas na prática a suíte de contrato já terá rodado contra o Memory.)

## Context

Implementa o doc 01 §3 (DDL), §5 (concorrência), §6 (erros) e §8 (require lazy). É o backend que dá durabilidade real ao critério de conclusão da fase (00-overview §6: sobreviver a `kill -9` + reboot) — os stores de domínio (tasks 5-7) e o Recovery (task 8) gravam através dele em produção.

Decisões que governam esta task (doc 01 §9 + 00-overview):

- **L1:** tabela única `kv`; os stores de domínio são **scopes**, não tabelas.
- **L3:** JSON, não MessagePack — inspecionável no SQLite CLI; trocável via `serializer:`.
- **L4:** `WITHOUT ROWID` + PK composta `(scope, key)`.
- **L5:** escrita síncrona no fiber (sem thread-pool) — exceção controlada do handoff §5; latência local WAL < 1ms.
- **L6:** `busy_timeout` 5000 fixo.
- **D7:** last-write-wins; lease/lock é Fase 2 (nenhum campo extra aqui — a reserva de schema é no Task Store, doc 02).
- **D9:** `sqlite3 ~> 2.0` no Gemfile, mas **carregado lazy** dentro do `initialize` (doc 01 §8) — o núcleo continua instalável sem a gem quando só Memory é usado.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/stores/sqlite.rb` | Backend SQLite (`include Store`): DDL idempotente, PRAGMAs, semáforo de escrita, `close` |
| CREATE | `spec/harness/stores/sqlite_spec.rb` | Suíte de contrato (`:memory:` e arquivo em tmpdir) + durabilidade + WAL + concorrência Async |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/stores/sqlite"` (o arquivo em si não requer `sqlite3` no load) |
| MODIFY | `Gemfile` | Adicionar `gem "sqlite3", "~> 2.0"` e `gem "async", "~> 2.0"` (D9) |

### Step-by-Step Instructions

#### Step 1: Inicialização — require lazy, DDL idempotente, PRAGMAs

**File:** `lib/harness/stores/sqlite.rb`

Assinatura do doc 01 §2: `def initialize(path:, serializer: JSON)`; `":memory:"` válido para teste; `close -> nil`.

```ruby
# frozen_string_literal: true

require "json"
require "time"
require "async/semaphore"

module Harness
  module Stores
    # Backend SQLite — default de produção (doc 01 §3, RFC-0006 §3).
    # Tabela única kv (L1); domínio vive nos scopes. Um handle por processo,
    # escritas em transação serializadas por Async::Semaphore (doc 01 §5).
    class SQLite
      include Store

      DDL = <<~SQL
        CREATE TABLE IF NOT EXISTS kv (
          scope      TEXT    NOT NULL,
          key        TEXT    NOT NULL,
          value      TEXT    NOT NULL,
          updated_at TEXT    NOT NULL,
          PRIMARY KEY (scope, key)
        ) WITHOUT ROWID;
      SQL

      # require lazy (doc 01 §8): o núcleo instala sem a gem sqlite3
      # quando só o Memory é usado.
      def initialize(path:, serializer: JSON)
        require "sqlite3"

        @serializer = serializer
        @db = SQLite3::Database.new(path)
        @write_semaphore = Async::Semaphore.new(1)
        @tx_owner = nil

        @db.execute("PRAGMA journal_mode = WAL")   # RFC-0006 §6
        @db.execute("PRAGMA synchronous = NORMAL")
        @db.busy_timeout = 5_000                   # L6 — rede de segurança
        @db.execute_batch(DDL)
        @db.execute(
          "CREATE INDEX IF NOT EXISTS kv_scope_prefix ON kv (scope, key)"
        )
      rescue ::SQLite3::Exception => e
        raise Harness::StoreError, "falha ao abrir #{path}: #{e.message}"
      end

      def close
        @db&.close
        nil
      end

      # ... Steps 2-3
    end
  end
end
```

Notas de precisão:

- O DDL é **exatamente** o do doc 01 §3 (tabela `kv`, `WITHOUT ROWID`, índice `kv_scope_prefix`). `updated_at` ISO8601 UTC existe para o GC da Fase 2 e depuração — **não** é exposto pela interface.
- PRAGMAs via `execute` (o `journal_mode` retorna o modo — ignorar o retorno); `busy_timeout` via API da gem.
- `require "sqlite3"` fica **dentro** do `initialize` (doc 01 §8). O `require "async/semaphore"` pode ficar no topo — `async` é dependência do núcleo (D9).
- Referencie a exceção do driver como `::SQLite3::Exception` (com `::`) — dentro de `Harness::Stores::SQLite`, `SQLite3` sem raiz colide com o próprio nome da classe.
- Guarde `path` se quiser mensagem de erro melhor; nada além disso (sem pool — um handle por processo, doc 01 §5).

#### Step 2: Operações KV

**File:** `lib/harness/stores/sqlite.rb` (continuação)

```ruby
      def get(scope, key)
        row = @db.get_first_value(
          "SELECT value FROM kv WHERE scope = ? AND key = ?", [scope, key]
        )
        row.nil? ? nil : @serializer.parse(row)
      rescue ::SQLite3::Exception => e
        raise Harness::StoreError, e.message
      end

      def set(scope, key, value)
        serialized = serialize(value)               # fail-fast ANTES de gravar
        write do
          @db.execute(
            "INSERT OR REPLACE INTO kv (scope, key, value, updated_at) " \
            "VALUES (?, ?, ?, ?)",
            [scope, key, serialized, Time.now.utc.iso8601]
          )
        end
        value
      end

      def delete(scope, key)
        write do
          @db.execute("DELETE FROM kv WHERE scope = ? AND key = ?", [scope, key])
          @db.changes.positive?
        end
      end

      def list(scope, prefix = nil)
        keys = @db.execute(
          "SELECT key FROM kv WHERE scope = ? ORDER BY key", [scope]
        ).map(&:first)
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      rescue ::SQLite3::Exception => e
        raise Harness::StoreError, e.message
      end

      private

      def serialize(value)
        @serializer.generate(value, strict: true)
      rescue JSON::GeneratorError => e
        raise Harness::StoreError, "valor não serializável: #{e.message}"
      end
```

Notas de precisão:

- `INSERT OR REPLACE` sobre a PK composta implementa a sobrescrita silenciosa (C10, last-write-wins D7).
- `list` ordena no SQL (`ORDER BY key` — lexicográfico em TEXT) e filtra prefixo em Ruby com `start_with?` — semântica idêntica ao Memory e ao contrato (C14/C15); `LIKE`/`GLOB` teriam armadilhas de escaping com `%`/`*` nas chaves. O índice `kv_scope_prefix` mantém o scan barato.
- `serialize` roda **antes** do `write` (doc 01 §6: fail-fast na escrita; nunca grava lixo — e nunca abre transação à toa).
- `get`/`list` leem direto, sem semáforo — WAL permite leitores concorrentes com um escritor (doc 01 §5).
- Round-trip de `nil` (C7): grava `"null"`, `get` distingue linha ausente (`row.nil?`) de valor nulo (string `"null"` → `parse` → `nil`).

#### Step 3: `transaction` com `BEGIN IMMEDIATE` + semáforo

**File:** `lib/harness/stores/sqlite.rb` (continuação)

Doc 01 §2: "transaction: BEGIN IMMEDIATE ... COMMIT/ROLLBACK"; §5: "`Async::Semaphore.new(1)` em volta das escritas em transação para serializar `BEGIN IMMEDIATE` (evita `SQLITE_BUSY` entre fibers do mesmo processo)"; §2 regras: aninhada reusa a externa.

```ruby
      public

      # BEGIN IMMEDIATE ... COMMIT/ROLLBACK, serializado pelo semáforo
      # (doc 01 §5). Aninhada reusa a transação externa (doc 01 §2).
      def transaction(&blk)
        return yield if @tx_owner == Fiber.current

        @write_semaphore.acquire do
          begin
            @db.transaction(:immediate)
            @tx_owner = Fiber.current
            result = yield
            @db.commit
            result
          rescue StandardError
            @db.rollback if @db.transaction_active?
            raise
          ensure
            @tx_owner = nil
          end
        end
      rescue ::SQLite3::Exception => e
        raise Harness::StoreError, e.message
      end

      private

      # Toda escrita individual passa por transaction — assim TODAS as
      # escritas serializam no semáforo (doc 01 §5) e set/delete dentro de
      # uma transação externa participam dela (reuso por aninhamento).
      def write(&blk)
        transaction(&blk)
      end
```

Notas de precisão:

- **Reuso de aninhamento por fiber:** `@tx_owner == Fiber.current` detecta "já estou dentro da transação deste fiber" e só cede o bloco (C21). Sem esse check, um `set` dentro de `transaction { ... }` deadlockaria no semáforo. Como o semáforo serializa (1 permit), nunca há duas transações ativas — um único `@tx_owner` basta.
- **`set`/`delete` avulsos** viram transação de uma operação via `write` → todas as escritas passam pelo semáforo, cumprindo §5 sem caminho especial. Leituras nunca tocam o semáforo.
- **Rollback + re-raise:** exceção do bloco → `ROLLBACK` e a exceção original propaga (C20; doc 01 §6 "transaction que levanta exceção → ROLLBACK e re-raise"). Erros do driver viram `StoreError` com `cause` preservada (o `raise` dentro de `rescue` preserva `cause` automaticamente).
- **`Async::Semaphore` fora de reactor:** `acquire` sem contenção não bloqueia nem exige reactor — a suíte de contrato (single fiber, sem `Async { }`) roda normalmente. Contenção real só ocorre sob `Async`, que é exatamente o cenário do teste de concorrência (§7).
- Use `@db.transaction(:immediate)` + `commit`/`rollback` explícitos (a forma com bloco da gem re-levanta de um jeito que atrapalha o controle de `@tx_owner`). `transaction_active?` evita `ROLLBACK` sem transação (ex.: falha no próprio `BEGIN`).

#### Step 4: Specs — contrato + específicos de backend

**File:** `spec/harness/stores/sqlite_spec.rb`

```ruby
# frozen_string_literal: true

require "tmpdir"
require_relative "../store_contract"

RSpec.describe Harness::Stores::SQLite do
  context "com banco :memory:" do
    subject(:store) { described_class.new(path: ":memory:") }

    after { store.close }

    it_behaves_like "a harness store"
  end

  context "com arquivo em tmpdir" do
    subject(:store) { described_class.new(path: db_path) }

    let(:db_path) { File.join(Dir.mktmpdir, "harness-test.db") }

    after { store.close }

    it_behaves_like "a harness store"

    # + os 3 testes específicos permitidos pelo doc 01 §7 (tabela abaixo)
  end
end
```

Os únicos testes específicos de backend permitidos (doc 01 §7 — nada além disso):

1. **Durabilidade real:** grava, `close`, reabre `described_class.new(path: db_path)` e enxerga os dados.
2. **WAL ativo:** `PRAGMA journal_mode` retorna `"wal"` (teste no contexto de **arquivo** — em `:memory:` o SQLite reporta `"memory"`, o que não é falha).
3. **Concorrência Async:** N fibers escrevendo em scopes distintos + um leitor concorrente — sem `SQLITE_BUSY` vazando:

```ruby
    it "N fibers escrevendo + leitor concorrente sem SQLITE_BUSY" do
      require "async"

      Async do |task|
        writers = 8.times.map do |i|
          task.async do
            20.times { |n| store.transaction { store.set("scope-#{i}", "k#{n}", n) } }
          end
        end
        reader = task.async do
          50.times { store.list("scope-0") }
        end
        (writers + [reader]).each(&:wait)
      end

      expect(store.list("scope-3").length).to eq(20)
    end
```

Para o PRAGMA, exponha a leitura via o próprio contrato? Não — use um teste direto com uma segunda conexão de inspeção (`SQLite3::Database.new(db_path).get_first_value("PRAGMA journal_mode")`) ou, mais simples, um attr_reader interno é desnecessário: abra outra instância do store não, use a gem diretamente no spec (o spec pode requerer `sqlite3` — só o **núcleo** tem a regra de lazy require).

#### Step 5: Entry point e Gemfile

**File:** `lib/harness.rb` — adicionar `require_relative "harness/stores/sqlite"`. Atenção: o arquivo `sqlite.rb` **não** pode ter `require "sqlite3"` no topo (doc 01 §8) — verificar que `require "harness"` funciona sem a gem instalada (é o teste de sanidade da regra).

**File:** `Gemfile` — adicionar conforme D9:

```ruby
gem "async", "~> 2.0"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "sqlite3", "~> 2.0"   # backend SQLite; produção declara a gem no app
end
```

(`sqlite3` é "apenas backend SQLite" em D9 — quem usa só Memory não precisa dela; no Gemfile deste repo ela entra para os testes. A pinagem final e o `Gemfile.lock` commitado são a task 26.)

### Edge Cases to Handle

1. **Transação aninhada via `set` interno** — `store.transaction { store.set(...) }`: o `set` chama `write` → `transaction`, que detecta `@tx_owner == Fiber.current` e só cede. Sem isso: deadlock no semáforo. Coberto por C19/C21.
2. **Exceção no bloco com escrita já feita** — `ROLLBACK` desfaz `set` e `delete` (C20); `transaction_active?` protege contra rollback duplo.
3. **`:memory:` + `close` + reopen** — banco some (é o esperado); durabilidade só se testa com arquivo. Não escreva teste de reopen para `:memory:`.
4. **Duas instâncias no mesmo arquivo (spec de PRAGMA)** — permitido para inspeção em teste; em produção a premissa é um handle por processo (doc 01 §5). Não crie proteção contra multi-handle — está fora do escopo (D7/Fase 2).
5. **Disco cheio / corrupção / `SQLITE_BUSY` estourado** — qualquer `::SQLite3::Exception` vira `Harness::StoreError` com `cause` preservada (doc 01 §6); chamadores tratam um tipo só (D4).
6. **Valor não serializável dentro de transação** — `serialize` levanta `StoreError` antes do SQL; se já dentro de transação externa, a exceção propaga e a externa faz rollback (comportamento correto por construção).
7. **Chaves com `%`, `*`, `_`** — o filtro de prefixo é Ruby `start_with?`, imune a curingas de `LIKE`/`GLOB` (por isso não usar SQL para o prefixo).
8. **`updated_at`** — sempre `Time.now.utc.iso8601`; nunca exposto em `get`/`list` (doc 01 §3).

## Testing

### Unit Tests

**File:** `spec/harness/stores/sqlite_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| contrato em `:memory:` | `it_behaves_like "a harness store"` (C1-C22 da task 2) | suíte verde |
| contrato em arquivo tmpdir | mesma suíte contra arquivo real | suíte verde |
| durabilidade | `set` → `close` → nova instância no mesmo path → `get` | dados presentes (doc 01 §7) |
| WAL ativo | `PRAGMA journal_mode` no banco de arquivo | `== "wal"` (doc 01 §7) |
| require lazy | `require "harness"` (sem instanciar SQLite) não carrega a gem | `defined?(SQLite3)` nil antes do primeiro `new` (rodar em subprocess `ruby -e` ou spec dedicado que roda primeiro — ver Notes) |

### Integration Tests (if applicable)

**File:** `spec/harness/stores/sqlite_spec.rb` (mesmo arquivo, contexto de concorrência)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| concorrência Async | 8 fibers × 20 `transaction{set}` em scopes distintos + leitor concorrente de `list` (doc 01 §7) | sem `SQLITE_BUSY`/`StoreError`; contagens finais corretas por scope |
| escrita concorrente serializada | 2 fibers em `transaction` no mesmo scope | ambas completam (semáforo serializa; nenhum `BEGIN IMMEDIATE` falha) |

## Definition of Done

- [ ] `Stores::SQLite` passa a **mesma** suíte de contrato da task 2 (em `:memory:` e em arquivo), sem modificação na suíte
- [ ] DDL idempotente exatamente como doc 01 §3 (kv, WITHOUT ROWID, índice, `updated_at` ISO8601 UTC não exposto)
- [ ] `PRAGMA journal_mode = WAL`, `synchronous = NORMAL`, `busy_timeout = 5000` aplicados no `initialize`
- [ ] `require "sqlite3"` apenas dentro de `initialize`; `require "harness"` funciona sem a gem instalada
- [ ] Todas as escritas serializadas via `Async::Semaphore.new(1)`; transação aninhada reusa a externa sem deadlock
- [ ] Erros do driver e de serialização encapsulados em `Harness::StoreError` com `cause` preservada
- [ ] Testes de durabilidade, WAL e concorrência verdes (únicos específicos de backend, doc 01 §7)
- [ ] Suíte roda **sem ruby_llm instalado** e sem chave de API
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Teste de require lazy:** dentro da suíte RSpec normal, outro spec pode já ter instanciado o SQLite (ordem random), poluindo `defined?(SQLite3)`. A forma robusta é um teste que roda `ruby -Ilib -e 'require "harness"; exit(defined?(SQLite3) ? 1 : 0)'` em subprocess via `system`. Se preferir não pagar o subprocess, cubra a regra por revisão de código (checar que não há `require "sqlite3"` fora do `initialize`) e registre — mas o subprocess é barato e objetivo.
- **API da gem sqlite3 2.x:** `Database#transaction(:immediate)`, `#commit`, `#rollback`, `#transaction_active?`, `#busy_timeout=`, `#get_first_value`, `#changes` — confirme os nomes contra a versão instalada; a gem 2.x manteve essa API da 1.x, mas se algo divergir, o contrato (doc 01 §2) manda, não o nome do método.
- **Premissa de um único processo escritor** (doc 01 §5): não implemente nada para multi-processo; `busy_timeout` 5s é rede de segurança. A revisão desta seção é pré-requisito da Fase 2 (lease/lock, D7).
- O parâmetro `serializer:` (L3) só precisa responder a `generate(value, strict: true)` e `parse(string)` — JSON da stdlib é o default; não crie adapter.
- `Checkpoint`/domínio não entram aqui — scopes são strings opacas para este backend (L1).

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada via `/execute-task 4`)
- **Testes:** 51 novos (contrato C1-C22 em `:memory:` + arquivo; durabilidade, WAL, 2× concorrência Async, require lazy em subprocess); 60 existentes; **111 no total, 0 falhas**
- **Arquivos criados:** `lib/harness/stores/sqlite.rb`, `spec/harness/stores/sqlite_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (require do backend), `Gemfile` + `Gemfile.lock` (`async ~> 2.0`, `sqlite3 ~> 2.0` em test)
- **Observações — desvio deliberado do plano (código real prevalece):**
  - **Serialização não usa `strict: true`.** O Step 2 planejado prescrevia `@serializer.generate(value, strict: true)`, mas o ambiente real (ruby 3.3.5 travado no `Gemfile.lock` → json **2.7.1**) faz `strict: true` **rejeitar Symbol**, o que quebraria **C8** (Symbol→String). Esse é exatamente o "alerta de strict:true p/ task 4" deixado no commit da task 3. Segui o código real do `Stores::Memory`: `ensure_jsonable!` (validação explícita do modelo de tipos JSON, independente da versão) + `@serializer.generate(value)` sem `strict`. Resultado: **paridade exata de semântica com o Memory (L2)** — mesmos C8 e C22.
  - **`JSONABLE`/`ensure_jsonable!` duplicados do Memory.** Mantive a validação self-contained em cada backend (a task só autoriza tocar `sqlite.rb`; não extraí para `Store` para não mexer no arquivo da task 2 nem arriscar o contrato). Candidato natural a extração para o módulo `Store` numa refatoração futura, se um terceiro backend surgir.
  - **`ensure_jsonable!` roda como parte do `serialize`, antes do `write`** (fail-fast, doc 01 §6): valor não serializável levanta `StoreError` sem abrir transação.
  - **Testes de concorrência:** além do caso do doc 01 §7 (8 fibers + leitor), adicionei o caso de 2 transações no mesmo scope (DoD "escrita concorrente serializada"). Ambos verdes sem `SQLITE_BUSY`.
  - **`require lazy`:** validado em subprocess (`ruby -Ilib -e 'require "bundler/setup"; require "harness"; ...'`) — `defined?(SQLite3)` é `nil` após `require "harness"` e passa a definido após o primeiro `new`. `async/semaphore` fica no topo do arquivo (dep do núcleo, D9); apenas `sqlite3` é lazy.
  - **Sem linter configurado** no repo — validação foi `ruby -c` (Syntax OK) nos dois arquivos.
  - `Gemfile.lock` foi atualizado pelo `bundle install`; a pinagem definitiva da fase segue sendo a task 26.
