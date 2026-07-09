# Task 03: Backend `Stores::Memory` com rollback real de transação

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [01-persistence-stores.md](../01-persistence-stores.md)
> **Status:** ✅ DONE
> **Complexity:** Low

---

## Objective

Implementar `Harness::Stores::Memory` — backend KV em memória para dev/teste que serializa JSON mesmo em memória (doc 01 L2) e tem rollback **real** de transação por snapshot — passando integralmente a suíte de contrato da task 2.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 2 | Interface `Harness::Store` + suíte de contrato compartilhada (shared examples) | ⬜ TODO |

(Grafo do tasks.md: `3 (Memory) → 2`.)

## Context

Implementa o doc 01 §2 (interface `Stores::Memory`) e §3 (modelo Memory). É o backend de dev/teste e a primeira execução real da suíte de contrato — os stores de domínio da Etapa B (tasks 5-7) rodam seus specs em cima dele, sem SQLite.

As duas decisões que governam esta task:

- **L2 (doc 01 §9): serializar JSON também no Memory.** `@data[scope][key]` guarda a **string JSON**, não o objeto. Assim Memory e SQLite têm exatamente a mesma semântica de tipos (symbols→strings, chaves de Hash→strings) e "um teste que passa em Memory passa em SQLite" (doc 01 §3).
- **Rollback REAL por snapshot (doc 01 §2):** "snapshot (dup profundo dos scopes tocados) no início; exceção no bloco → restaura o snapshot. Rollback REAL — Memory e SQLite têm a mesma semântica e passam a mesma suíte (§7, L2)."

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/stores/memory.rb` | Backend Memory (`include Store`), Hash de dois níveis + snapshot de transação |
| CREATE | `spec/harness/stores/memory_spec.rb` | `it_behaves_like "a harness store"` |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/stores/memory"` |

### Step-by-Step Instructions

#### Step 1: Estrutura e operações KV

**File:** `lib/harness/stores/memory.rb`

Conforme doc 01 §2-§3: `Hash` de dois níveis `@data[scope][key] = serialized_value`, com serialização JSON na borda.

```ruby
# frozen_string_literal: true

require "json"

module Harness
  module Stores
    # Backend em memória para dev/teste (doc 01 §2-§3).
    # Serializa JSON mesmo em memória (L2): paridade exata de semântica de
    # tipos com o SQLite — a suíte de contrato é honesta.
    # Sem lock: fibers cooperativos não preemptam no meio de uma operação
    # de Hash (doc 01 §5).
    class Memory
      include Store

      def initialize
        @data = Hash.new { |h, scope| h[scope] = {} }
        @tx_depth = 0
        @snapshot = nil
      end

      def get(scope, key)
        raw = @data[scope][key]
        return nil if raw.nil?

        JSON.parse(raw)
      end

      def set(scope, key, value)
        @data[scope][key] = serialize(value)
        value
      end

      def delete(scope, key)
        !@data[scope].delete(key).nil?
      end

      def list(scope, prefix = nil)
        keys = @data[scope].keys.sort
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      end

      # ... transaction no Step 2

      private

      # JSON estrito: tipo fora do modelo JSON -> StoreError na ESCRITA
      # (fail-fast; nunca grava lixo — doc 01 §6).
      def serialize(value)
        JSON.generate(value, strict: true)
      rescue JSON::GeneratorError => e
        raise Harness::StoreError, "valor não serializável: #{e.message}"
      end
    end
  end
end
```

Notas de precisão:

- `get` parseia a string a cada leitura — devolve sempre um objeto **novo** (mutar o retorno de `get` não corrompe o store; mesmo comportamento do SQLite).
- `JSON.parse` sem `symbolize_names` — o contrato manda chaves string (C1/C8); os stores de domínio normalizam na borda (doc 02).
- Round-trip de scalars: `JSON.generate(42, strict: true)` e `JSON.parse("42")` funcionam com a stdlib atual (generator/parser aceitam scalar no topo). Se a versão de Ruby do projeto recusar scalar no topo, envelopar é **proibido** sem atualizar o doc 01 — registre em Notes e resolva com `JSON.parse(raw, quirks_mode: true)` se necessário (mesma semântica).
- `delete` retorna o booleano "existia?" (C12/C13): `Hash#delete` retorna o valor removido ou `nil`.
- Sem `dup`/lock nas operações simples — doc 01 §5: fibers cooperativos não preemptam operação de Hash.

#### Step 2: `transaction` com rollback real por snapshot

**File:** `lib/harness/stores/memory.rb` (continuação)

Semântica exigida (doc 01 §2 + regras de §2 "transaction aninhada: reusa a transação externa"):

```ruby
      # Snapshot no início da transação mais externa; exceção em qualquer
      # nível -> restaura o snapshot e re-propaga (rollback REAL, doc 01 §2).
      # Aninhada reusa a externa (sem SAVEPOINT na Fase 1).
      def transaction
        if @tx_depth.positive?
          @tx_depth += 1
          begin
            return yield
          ensure
            @tx_depth -= 1
          end
        end

        @snapshot = deep_snapshot
        @tx_depth = 1
        begin
          result = yield
          result
        rescue StandardError
          restore_snapshot
          raise
        ensure
          @tx_depth = 0
          @snapshot = nil
        end
      end

      private

      # Dup profundo: os valores já são strings JSON (imutáveis na prática),
      # então dup por scope basta — não há estrutura aninhada mutável.
      def deep_snapshot
        @data.each_with_object({}) { |(scope, kv), acc| acc[scope] = kv.dup }
      end

      def restore_snapshot
        @data = Hash.new { |h, scope| h[scope] = {} }
        @snapshot.each { |scope, kv| @data[scope] = kv }
      end
```

Notas de precisão:

- O snapshot é da **estrutura inteira** no início da transação externa. O doc 01 fala em "scopes tocados", mas quais scopes serão tocados só se sabe ao final; copiar todos os scopes é a implementação mais simples que cumpre a mesma semântica observável (os valores internos são strings JSON — o custo é um `dup` de Hash por scope). Se preferir literalidade, copy-on-write por scope na primeira escrita também vale — a suíte de contrato não distingue. Não é decisão arquitetural: a semântica observável (C19-C21) é a mesma.
- Exceção em transação **aninhada** propaga para a externa, que faz o rollback total (C21) — a interna não faz rollback parcial (sem SAVEPOINT na Fase 1, doc 01 §2).
- `restore_snapshot` recria o Hash com default proc (senão `@data[scope]` após rollback levantaria `NoMethodError` em scope novo).
- Rollback cobre `set` E `delete` (C20): restaurar o snapshot desfaz ambos naturalmente.
- Re-raise da exceção original, **sem** encapsular em `StoreError` — encapsular é para erros *do backend* (doc 01 §6); a exceção do bloco é do chamador. `StoreError` levantado dentro do bloco (ex.: C22 dentro de transação) também propaga após rollback.

#### Step 3: Spec com a suíte de contrato

**File:** `spec/harness/stores/memory_spec.rb`

```ruby
# frozen_string_literal: true

require_relative "../store_contract"

RSpec.describe Harness::Stores::Memory do
  subject(:store) { described_class.new }

  it_behaves_like "a harness store"
end
```

Conforme doc 01 §7: Memory **não** tem testes específicos além da suíte — se você sentir falta de um teste, o lugar dele é a suíte compartilhada (task 2), não aqui.

#### Step 4: Registrar no entry point

**File:** `lib/harness.rb`

Adicionar `require_relative "harness/stores/memory"` após `harness/store`.

**Reference pattern from codebase** (Fase 0 — `docs/harness_handoff/reference-implementation/lib/agent_runtime.rb`, aggregator de requires):

```ruby
# frozen_string_literal: true

require_relative "agent_runtime/event"
require_relative "agent_runtime/skill_catalog"
...
```

### Edge Cases to Handle

1. **`set(scope, key, nil)`** — grava a string `"null"`; `get` retorna `nil` (C7). Chave **existe** para `list`/`delete` (diferente de chave ausente). O `raw.nil?` do `get` distingue ausência (`nil` do Hash) de valor nulo (`"null"` string).
2. **Mutação do objeto após `set`** — como o valor é serializado na escrita, mutar o objeto original depois do `set` não altera o que está no store. Comportamento idêntico ao SQLite (é o ponto de L2).
3. **Rollback com scope criado dentro da transação** — scope que não existia no snapshot deve sumir após rollback (o `restore_snapshot` recria `@data` do zero, então cobre).
4. **Exceções não-StandardError** — o `rescue StandardError` do `transaction` não captura `Exception` cruas; suficiente para a Fase 1 (a suíte usa `RuntimeError`). Não adicione `rescue Exception`.
5. **Transação aninhada que faz `set` e a externa completa** — commit normal, valor persiste (variante feliz de C21).
6. **`Float` como `42.0`** — `JSON.parse("42.0")` retorna Float (C5); não converta.

## Testing

### Unit Tests

**File:** `spec/harness/stores/memory_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| `it_behaves_like "a harness store"` | Os 22 casos C1-C22 da suíte de contrato (task 2): round-trips JSON, symbols→strings, nil em ausente, sobrescrita, delete bool, list c/ e s/ prefixo + ordenação, isolamento de scopes, transaction (retorno, commit, rollback real em exceção, aninhada), StoreError em valor não serializável | Suíte inteira verde contra `Stores::Memory.new` |

### Integration Tests (if applicable)

Não aplicável — Memory é o backend de teste; integração de domínio acontece nas tasks 5-7.

## Definition of Done

- [ ] `Stores::Memory` passa os 22 casos da suíte de contrato sem nenhuma modificação na suíte
- [ ] Serialização JSON interna (L2) — `@data` guarda strings, nunca objetos vivos
- [ ] Rollback real: C20/C21 verdes (snapshot restaurado em exceção, aninhada reusa a externa)
- [ ] `JSON.generate(..., strict: true)` na escrita; `StoreError` em valor não serializável
- [ ] Zero testes específicos de backend fora da suíte (doc 01 §7)
- [ ] `lib/harness.rb` atualizado
- [ ] Suíte roda **sem ruby_llm instalado** e sem chave de API
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- O snapshot copia todos os scopes (não só os "tocados") — simplificação registrada no Step 2 que preserva a semântica observável exigida pela suíte. Se o perfil de memória virar problema (não deve: valores são strings), otimizar para copy-on-write por scope sem mudar contrato.
- Memory não usa `Async::Semaphore` nem lock nenhum — doc 01 §5 é explícito ("fibers cooperativos não preemptam no meio de uma operação de Hash"). Não adicione sincronização especulativa.
- Este backend é o que os specs das tasks 5-8 injetam nos stores de domínio — mantenha o construtor sem argumentos (`Memory.new`), como no doc 01 §2 (`def initialize; end`).

---

## Conclusão

- **Concluído em:** 2026-07-07
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 23 novos (22 casos C1-C22 da suíte de contrato + edge case de ordenação lexicográfica, todos contra `Stores::Memory`); suíte total 60 exemplos, 0 falhas
- **Arquivos criados:** `lib/harness/stores/memory.rb`, `spec/harness/stores/memory_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (require do Memory)
- **Observações:**
  - **Correção de bug de especificação (afeta a task 4):** o task file mandava `JSON.generate(value, strict: true)`. Sob a versão de `json` que o bundle trava (2.7.1, default gem do Ruby 3.3.5), `strict: true` **rejeita Symbol**, o que quebra o caso de contrato C8 (Symbol→String). Sem `strict`, símbolos coerem (C8 ✓) mas `Object.new` vira a string-lixo `"#<Object...>"` em vez de levantar (C22 ✗). Ou seja, `strict: true` não satisfaz o próprio contrato. Substituído por validação explícita do modelo de tipos JSON (`ensure_jsonable!`: Symbol permitido/coerido, tipo fora do modelo → `StoreError`) + `JSON.generate` sem strict. Solução independente da versão do json e que dá semântica idêntica ao SQLite. **A task 4 NÃO deve usar `strict: true`** — deve reusar/replicar esta lógica (candidata a extração para um módulo compartilhado quando a task 4 chegar — evita a duplicação que o code review apontaria).
  - Consideração para a task 26 (D9): o split de versão do `json` (bundle=2.7.1 vs. ruby puro=2.18.1) é inofensivo agora porque a serialização ficou independente de versão; se quiser determinismo total, pinar `json` no Gemfile em D9.
  - Zero testes específicos de backend em `memory_spec.rb` (doc 01 §7) — só `it_behaves_like`.
