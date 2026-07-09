# Task 07: `CheckpointStore` (checkpoint por turno, chave avulsa de side-effects, `prune`)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [02-session-task-checkpoint.md](../02-session-task-checkpoint.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Implementar `Harness::CheckpointStore`: snapshot por turno gravado em transação all-or-nothing (D4), registro de side-effects não-idempotentes em chave avulsa durante o turno com consolidação no `save`, e `prune(keep: 1)` para conter crescimento (L6 do doc 02).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 3 | Backend `Stores::Memory` com rollback real de transação | ⬜ TODO |

(Transitivamente: task 2 — interface `Harness::Store` (o rollback real da `transaction` é pré-condição do teste de crash-consistency) — e task 1 — tipos base, incluindo o `Checkpoint` de doc 00 §2.)

## Context

O checkpoint é a peça que faz o critério de conclusão da fase funcionar: "`SendMessage` com `session_id` sobrevive a `kill -9` + reboot retomando do checkpoint" (doc 00 §6). A granularidade é **por turno** (doc 02 §3, RFC-0006 §5): o checkpoint do turno *n* contém o estado **no início** do turno *n* — retomar = reexecutar o turno *n* inteiro. O `messages` é o transcript **materializado**, não um cursor (L3): o checkpoint é autossuficiente e a retomada não depende do Session Store (sessões stateless, D2, também checkpointam).

O problema fino são as tool calls **não-idempotentes** executadas no meio do turno: o checkpoint do turno ainda não existe quando elas rodam (ele só é salvo no estágio 8). Por isso elas são registradas numa **chave própria**, escrita em transação ANTES de o resultado da tool voltar ao modelo (doc 02 §2, doc 03 §4.7); o `save` seguinte as consolida em `completed_side_effects` e apaga a chave avulsa **na mesma transação**. Na retomada, o Executor consulta `side_effects` e responde essas calls com `{"skipped":"already_executed"}` em vez de reexecutar (L5).

Invariante D4: **um checkpoint é válido inteiro ou não existe** — crash no meio do `save` deixa o checkpoint anterior intacto e a task `running`; o Recovery (task 08) reexecuta o turno, o que é seguro justamente pelo registro de side-effects (L4).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/checkpoint_store.rb` | Classe `Harness::CheckpointStore` |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/checkpoint_store"` |
| CREATE | `spec/harness/checkpoint_store_spec.rb` | Specs contra Memory + smoke SQLite; crash-consistency |

### Step-by-Step Instructions

#### Step 1: Classe e esquema de chaves

**File:** `lib/harness/checkpoint_store.rb`

Interface do doc 02 §2, literal:

```ruby
# frozen_string_literal: true

require "time"

module Harness
  class CheckpointStore
    SCOPE = "checkpoints"

    def initialize(store:)
    def save(checkpoint)                    # -> Checkpoint (tipo do 00-overview §2)
    def latest(task_id)                     # -> Checkpoint | nil (maior turn)
    def find(task_id, turn:)                # -> Checkpoint | nil
    def record_side_effect(task_id, turn:, tool_call_id:)  # -> void; idempotente
    def side_effects(task_id, turn:)        # -> [tool_call_id] (chave avulsa ∪ checkpoint)
    def prune(task_id, keep: 1)             # -> void (chamado ao completar a task)
  end
end
```

Duas famílias de chave no scope `"checkpoints"` (doc 02 §2-§3):

- `"checkpoint:<task_id>:turn:<n>"` → JSON do schema §3 (chaves string):

```json
{ "task_id": "t-3ab...", "turn": 4, "session_id": "s-9f2...",
  "agent_id": "sales",
  "messages": [ ... transcript completo até o fim do turno 3 ... ],
  "completed_side_effects": ["call_abc123"],
  "created_at": "..." }
```

- `"sideeffects:<task_id>:turn:<n>"` → `["tool_call_id", ...]` (a chave avulsa).

O tipo de entrada/saída é o `Harness::Checkpoint` da task 01 (doc 00 §2):
`Data.define(:task_id, :turn, :session_id, :agent_id, :messages, :completed_side_effects, :created_at)`.

**Reference pattern from codebase** (classe pequena, comentários em pt, convenções — `docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb`):

```ruby
# frozen_string_literal: true

module AgentRuntime
  # Convenção OpenClaw / AgentSkills: cada skill é um diretório com um
  # SKILL.md (YAML frontmatter + corpo markdown). Progressive disclosure: ...
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    def initialize(roots)
      @roots = Array(roots)
      @skills = load_all
    end
    # ...
  end
end
```

#### Step 2: `save(checkpoint)` — transação all-or-nothing com consolidação

**SEMPRE** dentro de `store.transaction` (doc 02 §2: "um checkpoint é válido inteiro ou não existe", D4). Dentro do bloco, nesta ordem:

1. **Validar monotonicidade**: `checkpoint.turn` deve ser maior que o turn do `latest` existente → senão `ArgumentError` ("checkpoint com turn não-monotônico", doc 02 §6).
2. **Consolidar side-effects**: ler a chave avulsa `"sideeffects:<task_id>:turn:<checkpoint.turn - 1>"` (o turno que acabou de executar — o `save` do estágio 8 grava o checkpoint do turno *n+1* ao fim do turno *n*, doc 02 §4). `completed_side_effects` final = `checkpoint.completed_side_effects | lista_avulsa` (união sem duplicatas).
3. **Gravar** o checkpoint (JSON normalizado, chaves string; `created_at` carimbado se `nil`).
4. **Apagar a chave avulsa** absorvida — "na mesma transação" (doc 02 §2).

Retornar o `Checkpoint` (com a lista consolidada). Se qualquer passo levantar, o rollback do backend desfaz tudo — nem checkpoint parcial, nem chave avulsa perdida.

#### Step 3: `record_side_effect` / `side_effects`

- **`record_side_effect(task_id, turn:, tool_call_id:)`** — dentro de `store.transaction` (doc 02 §2: "escrita em transação ANTES de o resultado da tool voltar ao modelo"): lê a chave avulsa, adiciona `tool_call_id.to_s` **se ausente** (idempotente: registrar duas vezes = uma entrada, doc 02 §7), grava. Retorna `nil`.
- **`side_effects(task_id, turn:)`** — união da chave avulsa do turno com `find(task_id, turn: turn)&.completed_side_effects` (doc 02 §2: "chave avulsa ∪ checkpoint"). Sem nada registrado → `[]`. É esta consulta que o Executor usa na retomada para responder `{"skipped":"already_executed"}` (doc 02 §3, L5 — consumo na task 13).

#### Step 4: `latest` / `find` — cuidado com ordenação de turn

- `find(task_id, turn:)` — `get` direto da chave; materializar `Checkpoint` ou `nil`.
- `latest(task_id)` — `store.list(SCOPE, "checkpoint:#{task_id}:turn:")`, extrair `n` de cada chave e escolher o **maior como Integer**. `list` ordena lexicograficamente (doc 01 §2) e `"turn:9" > "turn:10"` lexicograficamente — ordenar por string devolve o checkpoint errado a partir do turno 10. Parsear `key.split(":").last.to_i`.
- Materialização na borda: `turn` como Integer, demais campos como vêm (chaves string em `messages`).

#### Step 5: `prune(task_id, keep: 1)`

Listar os checkpoints da task, ordenar por turn **numérico**, apagar todos menos os `keep` maiores (default 1 — o último sempre sobrevive). Chamado pelo Executor ao completar a task (L6: "evita crescimento ilimitado já na Fase 1 sem esperar o GC da Fase 2"). Apagar também as chaves avulsas `sideeffects:` de turnos estritamente menores que o menor turn mantido (são lixo inatingível após a consolidação; ver Notes). Envolver em `transaction` para não deixar poda parcial.

### Edge Cases to Handle

1. **`save` com turn ≤ turn existente** (repetido ou retrocedendo) → `ArgumentError`; nada é escrito (transação).
2. **Crash (exceção) no meio do `save`** → rollback total: `latest` continua retornando o checkpoint anterior E a chave avulsa continua existindo (nada foi absorvido/apagado). Este é o invariante D4 — teste obrigatório (§7).
3. **`save` sem chave avulsa correspondente** (turno sem side-effects) → consolida com `[]`; `completed_side_effects` = o que veio no Checkpoint.
4. **`record_side_effect` duplicado** (mesmo `tool_call_id`, mesmo turno) → uma entrada só.
5. **`latest` com turnos esparsos** (ex.: 3, 7, 12 após prunes/saves irregulares) → retorna o de turn 12 (doc 02 §7: "`latest` correto com turnos esparsos").
6. **Turn ≥ 10** → ordenação numérica, não lexicográfica (turn 10 > turn 9; `list` diria o contrário).
7. **`latest`/`find`/`side_effects` de task sem checkpoint** → `nil` / `nil` / `[]` (nunca exceção — contrato `get` nil, doc 01 §2).
8. **`prune` com menos checkpoints que `keep`** → no-op.
9. **`prune(keep: 1)` com um único checkpoint** → preserva-o (doc 02 §7: "prune preserva o último").
10. **Isolamento entre tasks**: chaves avulsas e checkpoints de `task_a` invisíveis para `task_b` (prefixo por task_id nas chaves).
11. **`created_at` ausente no Checkpoint recebido** → carimbar ISO8601 UTC no `save`.

## Testing

### Unit Tests

**File:** `spec/harness/checkpoint_store_spec.rb`

Contra `Stores::Memory` (rollback real, task 03) + smoke SQLite `:memory:` (doc 02 §7).

| Test Case | Description | Expected |
|-----------|-------------|----------|
| round-trip save→find | save de Checkpoint completo | `find` devolve campos iguais; `turn` Integer; chaves string em `messages` |
| monotonicidade | save turn 2 após turn 2; save turn 1 após turn 2 | `ArgumentError` nos dois casos |
| `latest` maior turn | saves nos turns 1, 2, 3 | `latest` → turn 3 |
| `latest` turnos esparsos | checkpoints nos turns 3, 7, 12 | `latest` → turn 12 |
| `latest` turn ≥ 10 (ordenação numérica) | turns 9 e 10 | `latest` → 10 (não 9) |
| `latest`/`find` sem dados | task sem checkpoint | `nil` |
| side-effect idempotente | `record_side_effect` 2x mesmo id | `side_effects` com 1 entrada |
| `side_effects` = avulsa ∪ checkpoint | id na chave avulsa + id em `completed_side_effects` do checkpoint do turno | união, sem duplicatas |
| `side_effects` vazio | nada registrado | `[]` |
| consolidação no `save` | record no turn *n* → save do checkpoint turn *n+1* | `completed_side_effects` inclui os ids; chave avulsa `sideeffects:...:turn:n` apagada do backend |
| consolidação preserva os do Checkpoint | Checkpoint já vem com ids + avulsa tem outros | união dos dois conjuntos |
| **crash-consistency (D4, doc 02 §7)** | stub do serializador/`set` para levantar no meio da transação de `save` do turn *n+1*, após já ter escrito algo | `latest` → checkpoint do turn *n* intacto; chave avulsa do turn *n* ainda existe |
| `prune(keep: 1)` | turns 1..4 + prune | só turn 4 sobrevive; `latest` → 4 |
| `prune(keep: 2)` | turns 1..4 | sobrevivem 3 e 4 |
| `prune` com 1 checkpoint | | no-op; checkpoint preservado |
| isolamento entre tasks | dados em `task_a` e `task_b` | `latest`/`side_effects`/`prune` de uma não tocam a outra |
| smoke SQLite | save→latest→record→save→prune com `":memory:"` | idêntico ao Memory |

Dica para o teste de crash-consistency: injete um backend que delega ao Memory mas cujo `set` levanta na **segunda** chamada dentro da transação (ou faça o `checkpoint.messages` conter um objeto não serializável para o segundo `set`) — o ponto é a exceção ocorrer **dentro** do bloco de `transaction` depois de uma escrita parcial, exercitando o rollback real da task 03.

### Integration Tests (if applicable)

Não aplicável — o consumo pelo estágio 8 e pelo resume é das tasks 12 e 13; o E2E `kill -9` é da task 26.

## Definition of Done

- [ ] Interface idêntica ao doc 02 §2 (incluindo `prune(keep: 1)` e a chave avulsa `sideeffects:<task>:turn:<n>`)
- [ ] `save` sempre em `store.transaction`, all-or-nothing (D4), com consolidação + apagamento da chave avulsa na mesma transação
- [ ] Teste de crash-consistency passa: exceção dentro do `save` → `latest` retorna o checkpoint anterior (doc 02 §7)
- [ ] `record_side_effect` idempotente; `side_effects` = chave avulsa ∪ checkpoint
- [ ] `latest` correto com turnos esparsos e turn ≥ 10 (ordenação numérica)
- [ ] `prune` preserva os `keep` últimos por turn numérico
- [ ] `ArgumentError` para turn não-monotônico; `StoreError` propaga sem re-embrulhar (doc 02 §6)
- [ ] Specs verdes contra Memory + smoke SQLite
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (doc 02 §7)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Interpretação registrada (qual chave avulsa o `save` absorve):** o doc 02 §2 diz "`save` do turno seguinte absorve a lista", e o §4 mostra que o estágio 8 do turno *n* salva o checkpoint do turno *n+1*. A leitura adotada: `save(cp)` absorve a chave avulsa do turno `cp.turn - 1`. A consulta `side_effects(task, turn:)` une avulsa e checkpoint **do mesmo turno**, cobrindo os dois lugares onde um id pode estar em qualquer momento do ciclo. Como `tool_call_id` é globalmente único, uma união conservadora nunca causa skip indevido. Se a task 12/13 fixar outra convenção de numeração, ajuste o offset aqui.
- **Limpeza de chaves avulsas no `prune`:** o doc 02 só manda o `save` apagar a chave absorvida; apagar avulsas de turnos anteriores ao menor checkpoint mantido no `prune` é extensão mínima para não vazar lixo (mesmo espírito de L6). Se preferir literalidade estrita, remova — e registre que o GC da Fase 2 as recolherá.
- O marcador `{"skipped":"already_executed"}` e a decisão de **quem** consulta `side_effects` na retomada são do Executor/ResumeTask (doc 03 §4, task 13) — este store só fornece a consulta.
- Tools declaram não-idempotência com `register(name, klass, side_effect: true)` (doc 06); quem decide **chamar** `record_side_effect` é o hook de tool do Executor (task 12), não este store.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 22 novos (todos passando; inclui crash-consistency D4 com fault injection no `delete`), 225 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/checkpoint.rb`, `lib/harness/checkpoint_store.rb`, `spec/harness/checkpoint_store_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (requires sem side-effects)
- **Observações / decisões tomadas:**
  - **Desvio do plano registrado:** o tipo `Harness::Checkpoint` (overview §2) era atribuído à task 01 mas nunca foi criado lá (task 01 só entregou `errors/event/agent_profile/token_estimator`). Introduzi-o aqui em `lib/harness/checkpoint.rb`, com a definição idêntica ao overview §2, por ser a entrada/saída deste store. Um-tipo-por-arquivo, seguindo a convenção de `event.rb`/`agent_profile.rb`.
  - `save` sempre em `store.transaction`, all-or-nothing (D4): valida monotonicidade → consolida a chave avulsa do turno `cp.turn - 1` → grava o checkpoint → apaga a avulsa absorvida, tudo na mesma transação.
  - **Interpretação registrada** (offset da chave avulsa): `save(cp)` absorve `sideeffects:<task>:turn:<cp.turn - 1>`; `side_effects(task, turn:)` une avulsa ∪ checkpoint do MESMO turno. Conforme as Notes; ajustável se a task 12/13 fixar outra convenção.
  - Ordenação de turn **numérica** (`turn_of` parseia Integer) — cobre turnos esparsos e turn ≥ 10.
  - `prune` limpa também chaves avulsas de turnos < menor turn mantido (extensão mínima de L6, anotada nas Notes); em transação para não deixar poda parcial.
  - Crash-consistency testada injetando um backend cujo `delete` levanta: a exceção ocorre após o `set` do novo checkpoint, exercitando o rollback real da task 03 — `latest` volta ao checkpoint anterior e a avulsa permanece.
  - `StoreError` propaga sem re-embrulhar; `ArgumentError` para turn não-monotônico. `deep_stringify` replica o padrão das tasks 05/06.
