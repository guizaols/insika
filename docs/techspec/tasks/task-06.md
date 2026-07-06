# Task 06: `TaskStore` (máquina de estados validada, Executions, campos de claim reservados)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [02-session-task-checkpoint.md](../02-session-task-checkpoint.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Implementar `Harness::TaskStore`, o store de domínio que persiste Tasks com máquina de estados **validada no próprio store** (L1 do doc 02), histórico de Executions preservado em retry/resume e campos de claim reservados para a Fase 2 (D7).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 3 | Backend `Stores::Memory` com rollback real de transação | ⬜ TODO |

(Transitivamente: task 2 — interface `Harness::Store` — e task 1 — `errors.rb`.)

## Context

O `TaskStore` é o coração da durabilidade da Fase 1: toda intenção de mutação vira Command, Commands de turno viram Task (doc 00 D3), e é o status persistido aqui que o `Recovery` (task 08) varre no boot e que o `Executor` (task 10) transiciona ao longo da pipeline. A decisão L1 do doc 02 §9 é o eixo desta task: **a máquina de estados é validada no `TaskStore`, não no Executor** — "o store é o único ponto de escrita de status; invariantes moram onde a escrita mora". Transição inválida é bug e levanta `ArgumentError` alto e cedo (doc 02 §5-§6): é assim que corridas lógicas são detectadas sem lock.

Cada `Execution` é **uma tentativa**; retry/resume abre nova entrada, nunca sobrescreve (doc 02 §3, RFC-0006 §2.2). `claimed_by`/`claim_expires_at` ficam `null` na Fase 1 — o schema já os reserva para o lease/lock da Fase 2 não exigir migração (D7).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/task_store.rb` | Classe `Harness::TaskStore` + `Task` e `Execution` (Data internos) |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/task_store"` |
| CREATE | `spec/harness/task_store_spec.rb` | Specs contra `Stores::Memory` + smoke SQLite; matriz completa de transições |

### Step-by-Step Instructions

#### Step 1: Classe, constantes e Data internos

**File:** `lib/harness/task_store.rb`

Copiar a interface do doc 02 §2 literalmente:

```ruby
# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  class TaskStore
    SCOPE = "tasks"

    STATUSES = %i[queued running waiting paused completed failed cancelled].freeze

    # Transições válidas (doc 02 §2) — tudo fora disso é bug → ArgumentError.
    TRANSITIONS = {
      queued:  %i[running cancelled],
      running: %i[waiting paused completed failed cancelled],
      waiting: %i[running cancelled failed],
      paused:  %i[running cancelled],
      completed: [], failed: [], cancelled: []   # terminais
    }.freeze

    Task      = Data.define(:id, :status, :command, :session_id, :executions,
                            :mailbox_state, :claimed_by, :claim_expires_at,
                            :created_at, :updated_at)
    Execution = Data.define(:attempt, :started_at, :finished_at, :outcome, :error)

    def initialize(store:)
    def create(command:, session_id: nil, id: SecureRandom.uuid) # -> Task (status :queued)
    def find(id)                                                 # -> Task | nil
    def transition(id, to:, error: nil)     # -> Task; valida a máquina de estados
    def begin_execution(id)                 # -> Task; abre Execution (attempt N+1)
    def finish_execution(id, outcome:)      # -> Task; fecha a Execution corrente
    def running_or_interrupted              # -> [Task] com status running/waiting/paused (boot)
    def each_id(&blk)
  end
end
```

**Reference pattern from codebase** (Data interno + constante de política + convenções — `docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb`):

```ruby
# frozen_string_literal: true

module AgentRuntime
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    # roots ordenados por PRECEDÊNCIA (maior primeiro): workspace, managed,
    # bundled. Mesmo nome em mais de um root: o primeiro vence.
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

#### Step 2: Persistência e normalização na borda

- Chave: `"task:#{id}"` no scope `"tasks"` (L2 do doc 02: uuid + prefixo lógico mantém `list` por tipo).
- Valor: o schema JSON do doc 02 §3, chaves **string** (normalização symbol→string na escrita, doc 01 §2 — reusar o mesmo padrão de `deep_stringify` da task 05):

```json
{ "id": "t-3ab...", "status": "running",
  "command": { "type": "send_message", "payload": {}, "meta": {} },
  "session_id": "s-9f2...",
  "executions": [ { "attempt": 1, "started_at": "...", "finished_at": null,
                    "outcome": null, "error": null } ],
  "mailbox_state": { "pending": [] },
  "claimed_by": null, "claim_expires_at": null,
  "created_at": "...", "updated_at": "..." }
```

- Na **leitura**, materializar `Task`/`Execution` com: `status` convertido para **Symbol** (é enum de domínio, comparado contra `STATUSES`); `command`, `mailbox_state`, `error` mantidos como Hash de chaves string (dados, não enum). Documentar essa regra num comentário — é a "normalização de tipos na borda" do doc 02 §1.
- `create` aceita `command:` como Hash (`{type:, payload:, meta:}`) ou `Harness::Command` (Data da task 01, doc 00 §2) — se responder a `to_h`, converter; persistir normalizado. Status inicial `:queued`, `executions: []`, `mailbox_state: {"pending" => []}`, `claimed_by`/`claim_expires_at` `nil` (D7 — **nunca** escritos por nenhum método da Fase 1). `ArgumentError` se o id já existir (mesma regra de duplicidade da sessão, doc 02 §6).

#### Step 3: `transition(id, to:, error: nil)` — a máquina de estados

1. Carregar a task; `Harness::NotFoundError` se ausente.
2. Normalizar `to` para Symbol e validar `STATUSES.include?(to)` → senão `ArgumentError`.
3. Validar `TRANSITIONS.fetch(status_atual).include?(to)` → senão `ArgumentError` com mensagem explícita (ex.: `"transição inválida: completed -> running"`). Isso cobre também terminais (lista vazia) e auto-transições (nenhum status se inclui).
4. Se `error:` for dado **e** existir Execution aberta (última com `finished_at == nil`): fechá-la na mesma escrita — `finished_at: agora`, `outcome: to.to_s`, `error:` normalizado (shape `{class:, message:, stage:}`, doc 02 §3). É este caminho que o `Recovery` usa (`transition(id, to: :failed, error: {...})`, doc 02 §4). Sem Execution aberta, `error:` é ignorado (ver Notes).
5. Gravar com `status: to.to_s` e `updated_at` novo; retornar o `Task` atualizado.

Read-modify-write **sem lock**: um nó, um dono por task (doc 02 §5, D7). A validação é exatamente o mecanismo que detecta corrida lógica.

#### Step 4: `begin_execution` / `finish_execution`

- **`begin_execution(id)`** — apende `{attempt: executions.size + 1, started_at: agora, finished_at: nil, outcome: nil, error: nil}`. `ArgumentError` se já houver Execution aberta (duas tentativas simultâneas na mesma task é bug — um dono por task, D7). **Nunca** sobrescreve entradas anteriores (doc 02 §3).
- **`finish_execution(id, outcome:)`** — fecha a Execution aberta (`finished_at: agora`, `outcome: outcome.to_s`); `ArgumentError` se não houver nenhuma aberta. Não mexe em `status` — status é papel do `transition` (o Executor chama os dois no estágio 8, doc 02 §4).
- Ambos levantam `NotFoundError` para task inexistente e retornam o `Task` atualizado.

#### Step 5: Consultas

- **`running_or_interrupted`** — `store.list(SCOPE, "task:")`, `get` de cada, filtra `%i[running waiting paused]`, retorna `[Task]`. É a varredura do boot (doc 02 §4); O(n) é aceitável na Fase 1 (um nó, SQLite local — doc 01 §5).
- **`each_id`** — mesmo padrão da task 05: strip do prefixo `"task:"`, yield; sem bloco → `Enumerator`.
- `find` → `Task | nil`.

`Harness::StoreError` do backend propaga sem re-embrulhar (doc 02 §6).

### Edge Cases to Handle

1. **Transição de estado terminal** (`completed|failed|cancelled` → qualquer) → `ArgumentError` (lista vazia em `TRANSITIONS`).
2. **Auto-transição** (`running → running`) → `ArgumentError` (não consta na tabela).
3. **`to` fora do enum** (`:banana`) → `ArgumentError` antes de consultar a tabela.
4. **`transition` com `error:` sem Execution aberta** (ex.: `queued → cancelled` antes de qualquer tentativa) → transição ocorre; `error:` ignorado (não há onde gravá-lo — o schema só tem `error` dentro de Execution).
5. **`begin_execution` com Execution ainda aberta** → `ArgumentError` (proteção contra dupla tentativa).
6. **`finish_execution` sem Execution aberta** → `ArgumentError`.
7. **Retry após falha**: `begin_execution` → `attempt: 2`, e a Execution 1 (fechada com erro) permanece intacta no array.
8. **`create` com `Harness::Command`** (Data) e com Hash de chaves symbol → ambos persistem o mesmo JSON normalizado.
9. **`status` lido do backend é string** (`"running"`) → `Task#status` deve voltar como Symbol; comparar sempre via Symbol no código.
10. **Task inexistente** em `transition`/`begin_execution`/`finish_execution` → `NotFoundError`; em `find` → `nil`.

## Testing

### Unit Tests

**File:** `spec/harness/task_store_spec.rb`

Contra `Stores::Memory` + um smoke SQLite `:memory:` (doc 02 §7).

**Matriz de transições (doc 02 §7: "todas as válidas passam, todas as inválidas levantam").** Gerar programaticamente `STATUSES × STATUSES` (49 pares) contra o conjunto válido — transcrição da tabela do doc 02 §2:

| De \ Para | queued | running | waiting | paused | completed | failed | cancelled |
|-----------|--------|---------|---------|--------|-----------|--------|-----------|
| queued    | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| running   | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| waiting   | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ |
| paused    | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| completed | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| failed    | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| cancelled | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

(12 pares ✓; os 37 ✗ levantam `ArgumentError`. No spec, iterar a matriz preparando cada task no estado de origem por um caminho válido — ex.: chegar a `waiting` via `queued→running→waiting` — ou gravando o registro direto no backend, que é aceitável em teste de store.)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| matriz completa de transições | 49 pares gerados de `STATUSES × STATUSES` | 12 transitam; 37 levantam `ArgumentError` |
| `create` defaults | `create(command: {...})` | status `:queued`, `executions == []`, `mailbox_state == {"pending"=>[]}`, claim nulos |
| `create` id duplicado | mesmo id duas vezes | `ArgumentError` |
| claim reservado (D7) | após create + transições + executions | `claimed_by` e `claim_expires_at` permanecem `nil` no JSON persistido |
| `begin_execution` numera attempts | 1ª e 2ª chamadas (com finish entre elas) | `attempt: 1` e `attempt: 2` |
| Executions preservam histórico | falha (finish/transition c/ erro) + novo begin | array com 2 entradas; a 1ª intacta, fechada, com `error` |
| `begin_execution` com aberta | duas chamadas seguidas | `ArgumentError` |
| `finish_execution` fecha a corrente | `finish_execution(id, outcome: "completed")` | `finished_at` preenchido, `outcome == "completed"`, status inalterado |
| `finish_execution` sem aberta | | `ArgumentError` |
| `transition` com `error:` fecha a Execution | running com Execution aberta → `:failed` c/ `{class:, message:, stage:}` | Execution fechada com `outcome "failed"` e o erro (chaves string) |
| `transition` com `error:` sem Execution aberta | `queued → cancelled` com `error:` | transiciona; nenhum erro gravado; não levanta |
| `running_or_interrupted` | tasks em todos os 7 estados | retorna só as em `running/waiting/paused` |
| `running_or_interrupted` vazio | store sem tasks | `[]` |
| status volta como Symbol | create → find | `Task#status == :queued` (não `"queued"`) |
| normalização do command | `Harness::Command` e Hash com symbols | JSON persistido idêntico, chaves string |
| `each_id` | 3 tasks | ids sem prefixo `task:`; Enumerator sem bloco |
| `NotFoundError` | transition/begin/finish em id inexistente | `Harness::NotFoundError` |
| smoke SQLite | create→transition→begin→finish com `":memory:"` | idêntico ao Memory |

### Integration Tests (if applicable)

Não aplicável — a integração com Executor/Recovery é das tasks 08, 10 e 13.

## Definition of Done

- [ ] Interface idêntica ao doc 02 §2 (nomes, aridades, `STATUSES`, tabela de transições)
- [ ] Máquina de estados validada no store (L1): matriz 49-pares no spec, 12 válidas / 37 `ArgumentError`
- [ ] Executions são append-only: retry/resume nunca sobrescreve tentativa anterior (doc 02 §3)
- [ ] `claimed_by`/`claim_expires_at` presentes no schema e sempre `nil` (D7)
- [ ] Schema JSON do doc 02 §3 com chaves string; `status` exposto como Symbol na borda
- [ ] `StoreError` propaga sem re-embrulhar; `ArgumentError` para violações de domínio (doc 02 §6)
- [ ] Specs verdes contra Memory + smoke SQLite
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (doc 02 §7)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Interpretação registrada:** o doc 02 §2 define `transition(id, to:, error: nil)` mas não diz onde `error` é gravado; o §3 diz que "`error` da Execution guarda `{class:, message:, stage:}`" e o §4 mostra o Recovery chamando `transition(..., to: :failed, error: {...})` numa task que estava `running` (logo, com Execution aberta). A leitura adotada — `error:` fecha a Execution aberta — é a única que faz esses três pontos se encaixarem sem campo novo no schema. Se a task 10/13 (Executor/Resume) precisar de outra semântica, ajuste lá e atualize aqui.
- Lacuna do techspec anotada para a task 08: a máquina não permite `paused → failed`, mas o fluxo do Recovery (doc 02 §4) marca `:failed` qualquer task interrompida **sem checkpoint** — inclusive `paused`. Ver Notes da task 08; não "conserte" a tabela aqui (Don't change the plan).
- `mailbox_state` é só persistido nesta task; quem o consome é a mailbox mínima do `TaskActor` (task 10, doc 03 §5).
