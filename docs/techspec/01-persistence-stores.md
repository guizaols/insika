# Techspec 01 — Persistence & Stores (interface + Memory/SQLite)

> Implementa RFC-0006 §1–§3. Dependência de todo o resto da Fase 1: hoje o
> sistema é stateless (RFC-0006 §8). Decisões globais em `00-overview.md` (D#).

## 1. Objetivo e fronteira

**Faz:** define o contrato `Harness::Store` (KV escopado por namespace,
transacional quando o backend suporta) e entrega dois backends: `Memory`
(dev/teste) e `SQLite` (default de produção, RFC-0006 §3). O backend é
resolvido e injetado no composition root (`config/wiring.rb`) — troca de
backend sem tocar na lógica, que é o objetivo da RFC-0006 §1 (um registry
formal de stores só se justifica quando plugins registrarem backends, Fase 2).

**Não faz:** semântica de domínio (Session/Task/Checkpoint — doc 02); backends
Filesystem/Postgres/ActiveRecord (Fase 2); retenção/GC (Fase 2); lease/lock
(D7 — apenas reserva de schema); cache.

## 2. Interfaces públicas

```ruby
module Harness
  # Contrato mínimo (RFC-0006 §1). Toda implementação passa a mesma suíte
  # de contrato (§7). Valores devem ser serializáveis em JSON.
  module Store
    # scope: String — separa domínios/tenants (ex.: "sessions", "tasks:tenant_x")
    # key:   String hierárquica (ex.: "task:123", "checkpoint:123:turn:4")

    def get(scope, key)             # -> Object | nil (desserializado)
    def set(scope, key, value)      # -> value (o mesmo objeto passado)
    def delete(scope, key)          # -> true | false (existia?)
    def list(scope, prefix = nil)   # -> [String] chaves ordenadas lexicograficamente
    def transaction(&blk)           # -> resultado do bloco; atômico se o backend suportar
  end

  module Stores
    class Memory
      include Store
      def initialize; end
      # transaction: snapshot (dup profundo dos scopes tocados) no início;
      # exceção no bloco → restaura o snapshot. Rollback REAL — Memory e
      # SQLite têm a mesma semântica e passam a mesma suíte (§7, L2).
    end

    class SQLite
      include Store
      # path: arquivo .db; ":memory:" válido para teste
      def initialize(path:, serializer: JSON)
      def close                      # -> nil (libera o handle)
      # transaction: BEGIN IMMEDIATE ... COMMIT/ROLLBACK
    end
  end
end
```

Regras do contrato (valem para qualquer backend, verificadas pela suíte §7):

- `get` de chave inexistente → `nil` (nunca exceção).
- `set` sobrescreve silenciosamente (last-write-wins, D7).
- Round-trip preserva tipos JSON (Hash com chaves string, Array, String,
  Integer, Float, bool, nil). **Symbols viram strings** — os stores de domínio
  (doc 02) normalizam na borda.
- `list(scope)` retorna só as chaves do scope; `prefix` filtra por
  `start_with?`.
- `transaction` aninhada: reusa a transação externa (SAVEPOINT não é exigido
  na Fase 1).

## 3. Modelos de dados / schemas

### SQLite — DDL (criado idempotente no `initialize`)

```sql
PRAGMA journal_mode = WAL;          -- RFC-0006 §6
PRAGMA synchronous  = NORMAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS kv (
  scope      TEXT    NOT NULL,
  key        TEXT    NOT NULL,
  value      TEXT    NOT NULL,      -- JSON serializado
  updated_at TEXT    NOT NULL,      -- ISO8601 UTC
  PRIMARY KEY (scope, key)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS kv_scope_prefix ON kv (scope, key);
```

Uma tabela única `kv`: os cinco stores de domínio são **scopes**, não tabelas
(o núcleo não sabe onde grava — RFC-0006 preâmbulo). `updated_at` existe para
o GC da Fase 2 e para depuração; não é exposto pela interface.

### Memory

`Hash` de dois níveis: `@data[scope][key] = serialized_value`. Serializa
mesmo em memória (`JSON.generate`/`parse`) para que Memory e SQLite tenham
**exatamente** a mesma semântica de tipos — um teste que passa em Memory passa
em SQLite.

## 4. Fluxo de controle

Stores participam da pipeline apenas no **estágio 8 (Persistence)** e nas
leituras dos providers/handlers:

```
CommandBus ──(controle)──► SessionStore/TaskStore ──► Harness::Store backend
Executor ──(estágio 8)──► CheckpointStore.save ──► transaction { set(...) }
Recovery (boot) ──► TaskStore.list ──► get(...) ──► ResumeTask
```

Nenhum outro estágio escreve em store (RFC-0002 §5: "Persistence fora da
lógica de negócio"). O backend concreto é resolvido no composition root
(`config/wiring.rb`) e injetado nos stores de domínio — o Executor nunca vê
`Harness::Store` diretamente.

## 5. Concorrência

- **Regra:** nenhuma chamada de store pode bloquear o reactor por tempo
  relevante. SQLite é IO síncrono de baixa latência local (<1ms típico em WAL);
  a Fase 1 **aceita a chamada síncrona no fiber** — é a exceção controlada
  prevista no handoff §5 ("threads só na exceção CPU-bound isolada" — aqui nem
  thread há, só syscall curta).
- **Premissa da Fase 1: um único processo escritor.** Com o semáforo abaixo, o
  busy-wait do SQLite é inalcançável dentro do processo; `busy_timeout 5000`
  existe como rede de segurança. Multi-processo no mesmo arquivo exige
  revisitar esta seção (reduzir o busy_timeout e/ou driver async) **antes** do
  lease/lock da Fase 2 — um busy-wait de 5s numa chamada síncrona congelaria
  todos os fibers do processo. WAL permite leitores concorrentes com um
  escritor.
- Um **handle SQLite por processo**, `Async::Semaphore.new(1)` em volta das
  escritas em transação para serializar `BEGIN IMMEDIATE` (evita
  `SQLITE_BUSY` entre fibers do mesmo processo).
- `Memory` não precisa de lock: fibers cooperativos não preemptam no meio de
  uma operação de Hash.

## 6. Erros e timeouts

- Qualquer erro do driver (`SQLite3::Exception`, corrupção, disco cheio) é
  encapsulado em `Harness::StoreError` com `cause` preservada — chamadores
  tratam **um** tipo (D4).
- Falha de serialização (`JSON::GeneratorError` — ex.: objeto não serializável)
  → `StoreError` na **escrita** (fail-fast; nunca grava lixo).
- `transaction` que levanta exceção → ROLLBACK e re-raise (encapsulado).
- Timeout: `busy_timeout` do SQLite é o único; estourou → `StoreError`.
  Conforme D4, `StoreError` no estágio Persistence → task `:failed` com
  checkpoint anterior intacto.

## 7. Estratégia de testes

- **Suíte de contrato compartilhada** (handoff §6): RSpec shared examples
  `it_behaves_like "a harness store"` cobrindo: round-trip de todos os tipos
  JSON; nil em chave ausente; sobrescrita; delete com retorno bool; list com e
  sem prefixo + ordenação; isolamento entre scopes; transaction com rollback
  em exceção; transaction aninhada.
- `Stores::Memory` e `Stores::SQLite` (com `:memory:` e com arquivo em tmpdir)
  passam a **mesma** suíte, sem nenhum teste específico de backend além de:
  SQLite reabre o arquivo e enxerga os dados (durabilidade real); WAL ativo
  (`PRAGMA journal_mode` == "wal").
- Concorrência: teste Async com N fibers escrevendo scopes distintos e um
  leitor concorrente — sem `SQLITE_BUSY` vazando.
- Zero dependência de RubyLLM ou chave de API (handoff §6).

## 8. Evolução a partir da Fase 0

Componente **novo** — a Fase 0 não tem persistência (RFC-0006 §8). Nada é
substituído. Adiciona `sqlite3 ~> 2.0` ao Gemfile (D9), carregado **lazy**
(`require "sqlite3"` dentro de `Stores::SQLite#initialize`) para que o núcleo
continue instalável sem a gem quando só Memory é usado.

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Tabela única `kv` em vez de tabela por store | o contrato é KV; o domínio vive nos scopes. Menos DDL, migração de backend trivial (RFC-0006 §9.2 fica mais fácil) |
| L2 | Serializar JSON também no Memory | paridade exata de semântica entre backends; a suíte de contrato é honesta |
| L3 | JSON, não MessagePack | RFC-0006 §1 permite ambos; JSON é inspecionável no SQLite CLI e não adiciona gem. Trocável via `serializer:` |
| L4 | `WITHOUT ROWID` + PK composta | lookup por (scope,key) é o único acesso; economiza um índice |
| L5 | Escrita síncrona no fiber (sem thread-pool de IO) | latência local de SQLite WAL não justifica a complexidade; revisitar na Fase 2 com Postgres (aí sim IO de rede → driver async) |
| L6 | `busy_timeout` 5s fixo no backend | contenção de um nó; configurável só se a prática pedir |
