# Task 05: `SessionStore` (schema `session:<id>`, transcript como fonte da verdade)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [02-session-task-checkpoint.md](../02-session-task-checkpoint.md)
> **Status:** ✅ DONE
> **Complexity:** Low

---

## Objective

Implementar `Harness::SessionStore`, o store de domínio que persiste sessões (transcript + vars) sobre a interface `Harness::Store`, com schema fixo `session:<id>` e normalização symbol→string na borda (doc 02 §2-§3).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 3 | Backend `Stores::Memory` com rollback real de transação | ⬜ TODO |

(Transitivamente: task 2 — interface `Harness::Store` — e task 1 — `errors.rb`.)

## Context

Primeira task da Etapa B (domínio persistente, doc 00 §6). Os backends KV (tasks 3-4) são genéricos; esta task introduz a **API de domínio** por cima deles: o `SessionStore` é quem materializa a decisão D2 (sessão persistida opt-in) — quando `SendMessage` vier com `session_id` (task 12), o transcript virá daqui via `SessionProvider` (task 15, doc 04) e o turno será persistido de volta no estágio 8.

O transcript persistido é a **fonte da verdade** para reconstrução; eventos ao vivo são só estado de entrega (doc 02 §3, RFC-0006 §2.1). O shape das mensagens (`{role:, content:}`, `role ∈ user|assistant|system|tool`) é o mesmo que `Runner#seed_history` da Fase 0 já consome — o Executor não converte nada (doc 02 §8).

O `SessionStore` **não** conhece backend concreto: recebe um `Harness::Store` injetado pelo composition root (`config/wiring.rb`, doc 01 §4).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/session_store.rb` | Classe `Harness::SessionStore` + `Session` (Data interno) |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/session_store"` (zero side-effects, doc 00 §3) |
| CREATE | `spec/harness/session_store_spec.rb` | Specs contra `Stores::Memory` + smoke SQLite |

### Step-by-Step Instructions

#### Step 1: Classe `SessionStore` com `Session` interno

**File:** `lib/harness/session_store.rb`

Criar a classe conforme a interface do doc 02 §2 — copie a assinatura exatamente:

```ruby
# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  class SessionStore
    SCOPE = "sessions"

    Session = Data.define(:id, :messages, :vars, :memory_refs,
                          :created_at, :updated_at)

    def initialize(store:)   # store: qualquer Harness::Store (doc 01)
    def create(id: SecureRandom.uuid, vars: {})  # -> Session; ArgumentError se id já existe
    def find(id)                                 # -> Session | nil
    def append_messages(id, messages)            # -> Session (transcript += messages)
    def update_vars(id, vars)                    # -> Session (merge raso)
    def delete(id)                               # -> bool
    def each_id(&blk)                            # -> enumera ids (Control UI, doc 07)
  end
end
```

- Chave: `"session:#{id}"` no scope `"sessions"` (doc 02 §3; prefixo lógico conforme L2 do doc 02 — mantém `list` por tipo).
- Valor persistido: Hash com chaves **string**, exatamente o schema do doc 02 §3:

```json
{ "id": "s-9f2...", "messages": [{"role":"user","content":"...","at":"..."}],
  "vars": {}, "memory_refs": [], "created_at": "...", "updated_at": "..." }
```

- Timestamps ISO8601 UTC (`Time.now.utc.iso8601` — daí o `require "time"`), mesmo formato do `updated_at` do backend (doc 01 §3).
- Comentários em português; classe pequena de responsabilidade única (convenção Fase 0).

**Reference pattern from codebase** (Data interno + convenções — `docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb`):

```ruby
# frozen_string_literal: true

require "yaml"

module AgentRuntime
  # Convenção OpenClaw / AgentSkills: cada skill é um diretório com um
  # SKILL.md (YAML frontmatter + corpo markdown). ...
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    def initialize(roots)
      @roots = Array(roots)
      @skills = load_all
    end

    def find(name)
      @skills[name.to_s]
    end
    # ...
  end
end
```

#### Step 2: Normalização symbol→string na borda (escrita)

O contrato do backend garante round-trip só de tipos JSON — **symbols viram strings** e "os stores de domínio (doc 02) normalizam na borda" (doc 01 §2). Implementar um helper privado `deep_stringify(obj)` (Ruby puro, sem ActiveSupport — restrição 3 do doc 00 §5):

- Hash → novo Hash com `key.to_s` e valores recursivamente normalizados; Symbol como **valor** → `to_s`; Array → map recursivo; demais tipos passam intactos.
- Aplicar em **toda escrita**: `vars` no `create`/`update_vars`, `messages` no `append_messages`.
- Na **leitura** (`find`), devolver os dados como vêm do backend (chaves string) — nunca simetrizar de volta para symbols. Assim `Session#messages` tem o mesmo shape rodando contra Memory ou SQLite, e é o shape que o `seed_history` aceita.

#### Step 3: Operações

- **`create(id:, vars:)`** — se `get(SCOPE, key)` não for `nil`, levantar `ArgumentError` ("sessão duplicada" é violação de domínio, doc 02 §6). Senão gravar o schema completo com `messages: []`, `memory_refs: []`, `vars` normalizado, `created_at == updated_at`. Retorna o `Session`.
- **`find(id)`** — `get` + materializar `Session` a partir do Hash (retorna `nil` se ausente).
- **`append_messages(id, messages)`** — read-modify-write no fiber da própria task, sem lock (um nó, um dono por task — doc 02 §5, D7): carrega, concatena `Array(messages)` normalizados ao array `"messages"`, atualiza `updated_at`, grava. Cada mensagem ganha `"at"` (ISO8601 UTC) se não vier — o schema do doc 02 §3 mostra o campo por mensagem. `NotFoundError` (de `harness/errors.rb`, D4) se a sessão não existe.
- **`update_vars(id, vars)`** — **merge raso** (`stored["vars"].merge(deep_stringify(vars))`, doc 02 §2), atualiza `updated_at`, grava. `NotFoundError` se ausente.
- **`delete(id)`** — delega `store.delete` e retorna o bool do backend.
- **`each_id`** — `store.list(SCOPE, "session:")`, remove o prefixo `"session:"` e yield cada id; sem bloco, retornar `Enumerator` (`return enum_for(:each_id) unless block_given?`).

Erros do backend (`Harness::StoreError`) **propagam sem re-embrulhar** (doc 02 §6). Nenhuma operação precisa de `transaction` aqui — a escrita transacional do estágio 8 é do CheckpointStore (task 07); a ordem checkpoint → session → task é responsabilidade do Executor (doc 02 §5, L4).

### Edge Cases to Handle

1. **`create` com id existente** → `ArgumentError` (doc 02 §6). Não sobrescrever silenciosamente.
2. **`append_messages`/`update_vars` em sessão inexistente** → `Harness::NotFoundError` (D4: sessão inexistente → 404 na borda HTTP).
3. **`append_messages` com uma mensagem só (Hash, não Array)** → aceitar via `Array(messages)`... cuidado: `Array({a: 1})` vira `[[:a, 1]]`. Use `messages.is_a?(Hash) ? [messages] : Array(messages)`.
4. **Mensagens com chaves symbol** (`{role: :user, content: "oi"}`) → persistidas como `{"role"=>"user", ...}`; `find` devolve chaves string.
5. **`vars` aninhado com symbols** → `deep_stringify` recursivo (chaves e valores Symbol).
6. **`update_vars` é merge raso** — chave aninhada existente é substituída inteira, não fundida (doc 02 §2: "merge raso").
7. **`each_id` sem bloco** → `Enumerator`.
8. **`delete` de id inexistente** → `false` (contrato do backend, doc 01 §2), sem exceção.

## Testing

### Unit Tests

**File:** `spec/harness/session_store_spec.rb`

Rodar contra `Harness::Stores::Memory` (a paridade com SQLite é garantida pela suíte de contrato da task 2 — doc 02 §7) + **um** smoke com `Stores::SQLite.new(path: ":memory:")`.

| Test Case | Description | Expected |
|-----------|-------------|----------|
| `create` retorna Session com defaults | `create` sem args | `Session` com uuid, `messages == []`, `vars == {}`, `memory_refs == []`, timestamps ISO8601 |
| `create` com id duplicado | `create(id: "x")` duas vezes | segunda levanta `ArgumentError` |
| `find` inexistente | `find("nope")` | `nil` |
| round-trip create→find | `create` e `find` do mesmo id | mesmos dados, chaves string |
| `append_messages` concatena | 2 appends de 1 mensagem | `messages.size == 2`, ordem preservada, `updated_at` avança |
| normalização symbol→string | append de `{role: :user, content: "oi"}` | `find` devolve `{"role"=>"user", "content"=>"oi", "at"=>...}` |
| mensagem ganha `"at"` | append sem `"at"` | `"at"` ISO8601 presente; se vier `"at"`, é preservado |
| `append_messages` em id inexistente | | `Harness::NotFoundError` |
| `update_vars` merge raso | vars `{"a"=>1}` + update `{b: 2}` | `{"a"=>1, "b"=>2}`; update de chave existente substitui o valor inteiro |
| `update_vars` em id inexistente | | `Harness::NotFoundError` |
| `delete` | delete de id existente e inexistente | `true` / `false`; `find` → `nil` após delete |
| `each_id` | 3 sessões criadas | 3 ids sem o prefixo `session:`; sem bloco retorna Enumerator |
| isolamento de scope | escrever direto em outro scope do backend | `each_id` não enxerga |
| smoke SQLite | fluxo create→append→find com `":memory:"` | comportamento idêntico ao Memory |

### Integration Tests (if applicable)

Não aplicável nesta task — a integração com `SendMessage`/`SessionProvider` é das tasks 12 e 15.

## Definition of Done

- [ ] `lib/harness/session_store.rb` implementa exatamente a interface do doc 02 §2 (nomes e aridades)
- [ ] Valor persistido segue o schema JSON do doc 02 §3 (chaves string, timestamps ISO8601 UTC)
- [ ] Normalização symbol→string na escrita (doc 01 §2); leitura devolve chaves string
- [ ] `ArgumentError` para sessão duplicada; `NotFoundError` para append/update em sessão inexistente; `StoreError` propaga sem re-embrulhar (doc 02 §6)
- [ ] Specs verdes contra Memory + smoke SQLite
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (doc 02 §7)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- O doc 02 não diz explicitamente quem carimba o `"at"` das mensagens; o schema §3 mostra o campo, e carimbar na borda do store (quando ausente) é a leitura mais simples que o preenche sem exigir nada do Executor. Se a task 12 decidir carimbar no Executor, remova aqui.
- O tipo de erro para "sessão inexistente" em `append_messages`/`update_vars` não está nominalmente no doc 02 (§6 só lista `ArgumentError` para violações de domínio); `NotFoundError` de D4 ("session/task/agente inexistente → HTTP 404") é o encaixe correto para a borda HTTP do doc 07. Se preferir literalidade com o doc 02, `ArgumentError` também é defensável — registre a escolha no PR.
- `memory_refs` fica sempre `[]` na Fase 1 (memória semântica é Fase 2, doc 00 §"Fora do escopo") — o campo existe no schema para não migrar depois.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 19 novos (todos passando), 130 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/session_store.rb`, `spec/harness/session_store_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (require sem side-effects)
- **Observações / decisões tomadas:**
  - `NotFoundError` (D4) escolhido para `append_messages`/`update_vars` em sessão inexistente, conforme sugerido nas Notes (encaixe correto para o 404 da borda HTTP do doc 07); registrado aqui a alternativa `ArgumentError` do doc 02 §6.
  - `"at"` das mensagens é carimbado na borda do store quando ausente (leitura mais simples que preenche o schema §3 sem exigir nada do Executor); se a task 12 decidir carimbar no Executor, remover daqui.
  - `deep_stringify` em Ruby puro (sem ActiveSupport, restrição 3 do doc 00 §5); leitura devolve chaves string sem simetrizar de volta — mesmo shape rodando contra Memory ou SQLite, aceito por `seed_history`.
  - Nenhuma operação usa `transaction` (a escrita transacional do estágio 8 é do CheckpointStore, task 07) — RMW sem lock (um dono por task, doc 02 §5, D7).
