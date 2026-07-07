# Task 02: Interface `Harness::Store` + suíte de contrato compartilhada (shared examples)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [01-persistence-stores.md](../01-persistence-stores.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Definir o contrato `Harness::Store` (KV escopado por namespace, transacional) e a suíte de contrato compartilhada em RSpec shared examples (`it_behaves_like "a harness store"`) que **todo** backend deverá passar (doc 01 §2 e §7).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | ⬜ TODO |

(Grafo do tasks.md: `2 (Store + suíte) → 1`. Depende de 1 por `Harness::StoreError` e pelo esqueleto de specs.)

## Context

Implementa o doc 01 §1-§2: o contrato mínimo da RFC-0006 §1. É a fronteira entre o domínio (Session/Task/Checkpoint — doc 02, tasks 5-7) e a persistência concreta: o backend é resolvido e injetado no composition root (`config/wiring.rb`); a lógica nunca sabe onde grava.

A peça central desta task não é o módulo (que é pequeno) — é a **suíte de contrato compartilhada** (doc 01 §7, regra do handoff §6): um único conjunto de shared examples que as tasks 3 (`Stores::Memory`) e 4 (`Stores::SQLite`) executam sem nenhum teste duplicado. Isso é o que garante a decisão L2 do doc 01 ("paridade exata de semântica entre backends; a suíte de contrato é honesta"): um teste que passa em Memory passa em SQLite.

Componente **novo** — a Fase 0 não tem persistência (doc 01 §8); nada é substituído.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/store.rb` | Módulo `Harness::Store` — contrato documentado; métodos levantam `NotImplementedError` |
| CREATE | `spec/harness/store_contract.rb` | `RSpec.shared_examples "a harness store"` — a suíte de contrato (doc 01 §2 + §7) |
| CREATE | `spec/harness/store_spec.rb` | Verifica que o módulo puro levanta `NotImplementedError` em cada método |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/store"` |

### Step-by-Step Instructions

#### Step 1: Módulo `Harness::Store`

**File:** `lib/harness/store.rb`

Implementar exatamente a interface do doc 01 §2. O módulo serve de contrato documentado + guard: backends fazem `include Store` e sobrescrevem os cinco métodos; qualquer método esquecido levanta `NotImplementedError` (fail-fast, melhor que `NoMethodError` distante).

```ruby
# frozen_string_literal: true

module Harness
  # Contrato mínimo de persistência (doc 01 §2, RFC-0006 §1).
  # KV escopado por namespace, transacional quando o backend suporta.
  # Toda implementação passa a MESMA suíte de contrato
  # (spec/harness/store_contract.rb). Valores devem ser serializáveis em JSON.
  #
  # scope: String — separa domínios/tenants (ex.: "sessions", "tasks:tenant_x")
  # key:   String hierárquica (ex.: "task:123", "checkpoint:123:turn:4")
  #
  # Regras do contrato (verificadas pela suíte):
  # - get de chave inexistente -> nil (nunca exceção)
  # - set sobrescreve silenciosamente (last-write-wins, D7)
  # - round-trip preserva tipos JSON; Symbols viram Strings (domínio
  #   normaliza na borda, doc 02)
  # - list(scope) só retorna chaves do scope, ordenadas lexicograficamente;
  #   prefix filtra por start_with?
  # - transaction aninhada reusa a transação externa (sem SAVEPOINT na Fase 1)
  # - falha de serialização na escrita -> Harness::StoreError (fail-fast)
  module Store
    def get(scope, key)
      raise NotImplementedError, "#{self.class}#get"
    end

    def set(scope, key, value)
      raise NotImplementedError, "#{self.class}#set"
    end

    def delete(scope, key)
      raise NotImplementedError, "#{self.class}#delete"
    end

    def list(scope, prefix = nil)
      raise NotImplementedError, "#{self.class}#list"
    end

    def transaction(&blk)
      raise NotImplementedError, "#{self.class}#transaction"
    end
  end
end
```

Retornos contratuais (doc 01 §2 — os backends implementam, o comentário do módulo documenta):

- `get(scope, key)` → `Object | nil` (desserializado)
- `set(scope, key, value)` → `value` (o **mesmo** objeto passado, não o round-trip)
- `delete(scope, key)` → `true | false` (existia?)
- `list(scope, prefix = nil)` → `[String]` ordenadas lexicograficamente
- `transaction(&blk)` → resultado do bloco; atômico se o backend suportar

**Reference pattern from codebase** (estilo de módulo/comentário da Fase 0 — `docs/harness_handoff/reference-implementation/lib/agent_runtime/event.rb`):

```ruby
# frozen_string_literal: true

module AgentRuntime
  # Tudo que o runtime emite durante um turno é um Event.
  # O consumidor (seu sistema WhatsApp) reage por :type.
  ...
end
```

(Cabeçalho `frozen_string_literal`, comentário em português explicando o contrato antes da definição — siga o mesmo estilo.)

#### Step 2: Suíte de contrato compartilhada

**File:** `spec/harness/store_contract.rb`

Criar `RSpec.shared_examples "a harness store"` cobrindo **todos** os casos do doc 01 §2 (regras) + §7 (lista). A suíte assume que o grupo que a inclui define `subject(:store)` (ou `let(:store)`) com um backend pronto para uso.

Estrutura:

```ruby
# frozen_string_literal: true

# Suíte de contrato do Harness::Store (doc 01 §7).
# Todo backend passa EXATAMENTE esta suíte (L2: a suíte é honesta).
# O grupo que inclui deve definir `store` (backend vazio e pronto).
RSpec.shared_examples "a harness store" do
  describe "#get / #set (round-trip)" do
    # ... casos da tabela abaixo
  end

  describe "#delete" do
    # ...
  end

  describe "#list" do
    # ...
  end

  describe "isolamento de scopes" do
    # ...
  end

  describe "#transaction" do
    # ...
  end

  describe "erros de serialização" do
    # ...
  end
end
```

Casos obrigatórios (transcrição do doc 01 §2 regras + §7 lista — implemente um `it` por linha):

| # | Caso | Setup / Ação | Verificação |
|---|------|--------------|-------------|
| C1 | round-trip Hash | `set("s", "k", { "a" => 1, "b" => [1, 2] })` | `get` retorna Hash igual, **chaves string** |
| C2 | round-trip Array | `set("s", "k", [1, "x", true, nil])` | `get` retorna Array igual |
| C3 | round-trip String | `set("s", "k", "texto")` | `get == "texto"` |
| C4 | round-trip Integer | `set("s", "k", 42)` | `get == 42` e `be_a(Integer)` |
| C5 | round-trip Float | `set("s", "k", 3.14)` | `get == 3.14` e `be_a(Float)` |
| C6 | round-trip booleanos | `set` de `true` e de `false` | `get` retorna o mesmo |
| C7 | round-trip nil | `set("s", "k", nil)` | `get("s", "k")` retorna `nil` sem exceção |
| C8 | Symbols viram Strings | `set("s", "k", { chave: :valor })` | `get == { "chave" => "valor" }` (chaves E valores) |
| C9 | nil em chave ausente | nada gravado | `get("s", "nao-existe")` retorna `nil`, nunca exceção |
| C10 | sobrescrita silenciosa | `set` duas vezes na mesma (scope, key) | `get` retorna o segundo valor (last-write-wins, D7) |
| C11 | set retorna o valor | `set("s", "k", obj)` | valor de retorno `equal?`/`==` ao objeto passado |
| C12 | delete existente | `set` + `delete("s", "k")` | retorna `true`; `get` subsequente → `nil` |
| C13 | delete inexistente | nada gravado | `delete("s", "k")` retorna `false` |
| C14 | list sem prefixo | `set` de "b", "a", "c" no scope | `list("s") == ["a", "b", "c"]` (ordenação lexicográfica) |
| C15 | list com prefixo | chaves "task:1", "task:2", "checkpoint:1" | `list("s", "task:") == ["task:1", "task:2"]` (filtro `start_with?`) |
| C16 | list de scope vazio | nada gravado | `list("s") == []` |
| C17 | isolamento entre scopes | `set("s1", "k", 1)` e `set("s2", "k", 2)` | `get("s1", "k") == 1`; `list("s1")` não contém chaves de "s2"; `delete("s1", "k")` não afeta "s2" |
| C18 | transaction retorna o bloco | `transaction { 42 }` | `== 42` |
| C19 | transaction com commit | `transaction { set(...) }` | valor visível via `get` depois do bloco |
| C20 | transaction com rollback em exceção | `set` prévio; `transaction { set(novo); delete(outra); raise "boom" }` | exceção propaga (`raise_error`); TODOS os efeitos do bloco desfeitos — `get` retorna o valor anterior, chave deletada volta a existir |
| C21 | transaction aninhada reusa a externa | `transaction { transaction { set(...) }; raise }` | não levanta erro de aninhamento; rollback da externa desfaz o `set` da interna |
| C22 | valor não serializável | `set("s", "k", Object.new)` | levanta `Harness::StoreError` (fail-fast, doc 01 §6); nada gravado (`get` → `nil`) |

Notas de precisão:

- C20 é o teste que separa rollback **real** de rollback fake — o `Stores::Memory` da task 3 tem de restaurar snapshot (doc 01 §2/L2), não só engolir a exceção. A exceção original deve **propagar** (re-raise, doc 01 §6).
- C22 vale para ambos os backends porque o Memory também serializa JSON (L2). Use `Object.new` (sem `to_json` significativo? — `Object.new.to_json` com a stdlib pura gera string inútil mas não levanta). Para garantir o erro de forma portável, o backend deve serializar com `JSON.generate(value, strict: true)` — instrua isso nas tasks 3/4; o caso de teste usa `Object.new`, que com `strict: true` levanta `JSON::GeneratorError`.
- Não inclua na suíte casos específicos de backend (durabilidade de arquivo, WAL, concorrência) — esses são da task 4 (doc 01 §7: "sem nenhum teste específico de backend além de…").
- O arquivo é carregado pelos specs dos backends via `require_relative "store_contract"` (tasks 3 e 4) — não dependa de auto-load de `spec/support`.

#### Step 3: Spec do módulo puro

**File:** `spec/harness/store_spec.rb`

Classe anônima `Class.new { include Harness::Store }` — cada um dos cinco métodos levanta `NotImplementedError`. Garante que um backend incompleto falha alto.

#### Step 4: Registrar no entry point

**File:** `lib/harness.rb`

Adicionar `require_relative "harness/store"` após os tipos base.

### Edge Cases to Handle

1. **Chaves com o prefixo como substring interna** — `list("s", "task:")` não pode retornar `"my-task:1"` (o filtro é `start_with?`, não `include?`). Inclua uma chave-armadilha no C15.
2. **Ordenação lexicográfica vs. numérica** — `["task:10", "task:2"]` ordena `task:10` antes de `task:2` (lexicográfico). A suíte deve fixar isso explicitamente para os stores de domínio (doc 02) não dependerem de ordem numérica.
3. **Rollback de delete** — C20 cobre `set` E `delete` dentro da transação revertida; um snapshot que só desfaz `set` está errado.
4. **`transaction` sem bloco** — comportamento não especificado no doc 01; não teste nem trate (não invente contrato).
5. **Shared examples e estado entre exemplos** — cada `it` recebe um `store` limpo (o `let` do backend recria); a suíte não pode assumir ordem de execução (spec_helper roda `:random`).

## Testing

### Unit Tests

**File:** `spec/harness/store_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| get não implementado | `Class.new { include Harness::Store }.new.get("s", "k")` | `raise_error(NotImplementedError)` |
| set não implementado | idem para `set` | `NotImplementedError` |
| delete não implementado | idem para `delete` | `NotImplementedError` |
| list não implementado | idem para `list` | `NotImplementedError` |
| transaction não implementado | idem para `transaction` | `NotImplementedError` |

**File:** `spec/harness/store_contract.rb` (shared examples — executados pelas tasks 3 e 4)

Os 22 casos C1-C22 da tabela do Step 2. Nesta task eles não rodam contra backend nenhum (não existe backend ainda); a verificação local é que o arquivo carrega sem erro (`require` no `store_spec.rb` ou smoke `it` vazio). A primeira execução real é na task 3.

### Integration Tests (if applicable)

Não aplicável — a integração da suíte com backends reais acontece nas tasks 3 e 4.

## Definition of Done

- [ ] `lib/harness/store.rb` com os cinco métodos e o comentário-contrato do doc 01 §2
- [ ] `spec/harness/store_contract.rb` com os 22 casos (C1-C22) como shared examples `"a harness store"`
- [ ] Nenhum caso específico de backend dentro da suíte compartilhada
- [ ] `spec/harness/store_spec.rb` verde (NotImplementedError nos 5 métodos)
- [ ] `lib/harness.rb` atualizado
- [ ] Suíte roda **sem ruby_llm instalado** e sem chave de API
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **`JSON.generate(..., strict: true)`**: o doc 01 §6 exige `StoreError` em falha de serialização, mas o `to_json` default da stdlib serializa quase tudo (via `to_s`) sem levantar. `strict: true` é o modo da stdlib que levanta `JSON::GeneratorError` para tipos fora do modelo JSON — é o mecanismo que torna C22 testável. Registrado aqui porque o doc 01 não nomeia o flag; não é decisão arquitetural nova, é o único jeito da stdlib cumprir §6 ("nunca grava lixo").
- Um registry formal de stores só se justifica na Fase 2 (doc 01 §1) — **não** crie factory/registry; a injeção é manual no `config/wiring.rb` (que só ganha stores na Etapa B/C).
- `Checkpoint = Data.define(...)` (00-overview §2) NÃO entra aqui — é do doc 02 (task 7).

---

## Conclusão

- **Concluído em:** 2026-07-07
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 5 novos (spec do módulo puro) + 22 shared examples definidos (rodam a partir da task 3); suíte total 37 exemplos, 0 falhas
- **Arquivos criados:** `lib/harness/store.rb`, `spec/harness/store_contract.rb`, `spec/harness/store_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (require do store)
- **Observações:**
  - Os 22 casos C1-C22 foram escritos como `shared_examples "a harness store"`; nesta task não executam contra backend (não existe ainda) — apenas parseiam limpo (carregados via `require_relative` no `store_spec.rb`). Primeira execução real: task 3 (Memory).
  - `require_relative "store_contract"` é idempotente entre os specs de backend (tasks 3/4) — Ruby carrega o arquivo uma vez por caminho absoluto, sem re-registro de shared examples.
  - C22 depende de `JSON.generate(value, strict: true)` nos backends (nomeado nas Notes da task, não no doc 01) — é o único mecanismo da stdlib que cumpre o fail-fast de §6. As tasks 3/4 devem usar esse flag.
  - Lint: o repo ainda não tem `.rubocop.yml` (nem a Fase 0 tinha); `bundle exec rubocop` do CLAUDE.md não é executável até a configuração ser adicionada. Sintaxe validada com `ruby -c`.
