# Techspec 02 — Session / Task / Checkpoint Stores + Recuperação no Boot

> Implementa RFC-0006 §2, §4 e §5 sobre a interface do doc 01. Artifact e
> Plugin Stores são Fase 2 (RFC-0006 §8) e não constam aqui.

## 1. Objetivo e fronteira

**Faz:** os três stores de domínio da Fase 1 — `SessionStore`, `TaskStore`,
`CheckpointStore` — com schemas fixos, normalização de tipos na borda e
API de domínio (não KV cru); e o `Recovery`, que no boot retoma tasks
interrompidas (RFC-0006 §4).

**Não faz:** executar a retomada em si (delega ao caminho do `ResumeTask`,
doc 03); Artifact/Plugin Stores; retenção/GC; lease/lock efetivo (D7 — só
reserva de campos).

## 2. Interfaces públicas

```ruby
module Harness
  class SessionStore
    def initialize(store:)                       # store: Harness::Store (doc 01)

    def create(id: SecureRandom.uuid, vars: {})  # -> Session; erro se id já existe
    def find(id)                                 # -> Session | nil
    def append_messages(id, messages)            # -> Session (transcript += messages)
    def update_vars(id, vars)                    # -> Session (merge raso)
    def delete(id)                               # -> bool
    def each_id(&blk)                            # -> enumera ids (Control UI, doc 07)

    Session = Data.define(:id, :messages, :vars, :memory_refs,
                          :created_at, :updated_at)
  end

  class TaskStore
    STATUSES = %i[queued running waiting paused completed failed cancelled].freeze
    # transições válidas (tudo fora disso é bug → ArgumentError):
    #   queued   -> running | cancelled
    #   running  -> waiting | paused | completed | failed | cancelled
    #   waiting  -> running | cancelled | failed
    #   paused   -> running | cancelled
    #   (terminais: completed, failed, cancelled)

    def initialize(store:)

    def create(command:, session_id: nil, id: SecureRandom.uuid) # -> Task (status :queued)
    def find(id)                                                 # -> Task | nil
    def transition(id, to:, error: nil)     # -> Task; valida a máquina de estados
    def begin_execution(id)                 # -> Task; abre Execution (attempt N+1)
    def finish_execution(id, outcome:)      # -> Task; fecha a Execution corrente
    def running_or_interrupted              # -> [Task] com status running/waiting/paused (boot)
    def each_id(&blk)

    Task      = Data.define(:id, :status, :command, :session_id, :executions,
                            :mailbox_state, :claimed_by, :claim_expires_at,
                            :created_at, :updated_at)
    Execution = Data.define(:attempt, :started_at, :finished_at, :outcome, :error)
  end

  class CheckpointStore
    def initialize(store:)

    # Grava o snapshot do turno n. SEMPRE dentro de store.transaction —
    # um checkpoint é válido inteiro ou não existe (D4).
    def save(checkpoint)                    # -> Checkpoint (tipo do 00-overview §2)
    def latest(task_id)                     # -> Checkpoint | nil (maior turn)
    def find(task_id, turn:)                # -> Checkpoint | nil
    # Gravado DURANTE o turno (o checkpoint do turno ainda não existe — ele
    # só é salvo no estágio 8). Por isso vive em chave própria, escrita em
    # transação ANTES de o resultado da tool voltar ao modelo (doc 03 §4.7):
    #   scope "checkpoints", chave "sideeffects:<task_id>:turn:<n>" → [ids]
    # `save` do turno seguinte absorve a lista em `completed_side_effects`
    # e apaga a chave avulsa (na mesma transação).
    def record_side_effect(task_id, turn:, tool_call_id:)  # -> void; idempotente
    def side_effects(task_id, turn:)        # -> [tool_call_id] (chave avulsa ∪ checkpoint)
    def prune(task_id, keep: 1)             # -> void (chamado ao completar a task)
  end

  class Recovery
    def initialize(task_store:, checkpoint_store:, command_bus:)
    # Chamado uma vez no boot, ANTES de aceitar requests (doc 07 §4).
    def run                                 # -> { resumed: [ids], failed: [ids] }
  end
end
```

## 3. Modelos de dados / schemas

Scopes e chaves (RFC-0006 §2), valores como JSON no backend:

### `sessions` / `session:<id>`

```json
{ "id": "s-9f2...", "messages": [{"role":"user","content":"...","at":"..."}],
  "vars": {}, "memory_refs": [], "created_at": "...", "updated_at": "..." }
```

O transcript persistido é a **fonte da verdade** para reconstrução; eventos ao
vivo são estado de entrega (RFC-0006 §2.1). `role` ∈ `user|assistant|system|tool`
— o mesmo shape que `Runner#seed_history` já consome na Fase 0.

### `tasks` / `task:<id>`

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

Cada Execution é **uma tentativa**; retry/resume abre nova entrada, nunca
sobrescreve (RFC-0006 §2.2). `claimed_by`/`claim_expires_at` ficam `null` na
Fase 1 (D7). `error` da Execution guarda `{ class:, message:, stage: }`.

### `checkpoints` / `checkpoint:<task_id>:turn:<n>`

```json
{ "task_id": "t-3ab...", "turn": 4, "session_id": "s-9f2...",
  "agent_id": "sales",
  "messages": [ ... transcript completo até o fim do turno 3 ... ],
  "completed_side_effects": ["call_abc123"],
  "created_at": "..." }
```

- **Granularidade por turno** (RFC-0006 §5, já resolvida). O checkpoint do
  turno *n* contém o estado **no início** do turno *n*: retomar = reexecutar o
  turno *n* inteiro.
- `messages` é o transcript materializado (não um cursor): torna o checkpoint
  autossuficiente — retomar não depende do Session Store estar consistente
  (sessões stateless, D2, também checkpointam). Custo avaliado em L3.
- `completed_side_effects`: ids de tool calls **não-idempotentes já
  concluídas** dentro do turno corrente (RFC-0006 §5). Durante o turno elas
  vivem na chave avulsa `sideeffects:<task_id>:turn:<n>` (ver §2 —
  crash no meio do turno preserva o registro); o `save` do estágio 8 as
  consolida no checkpoint. Na retomada, o Executor consulta `side_effects`
  (que une chave avulsa e checkpoint) e responde essas calls com o marcador
  `{"skipped":"already_executed"}` em vez de reexecutar (doc 03 §4).
  Tools declaram não-idempotência no registro: `register(name, klass,
  side_effect: true)` (doc 06).

## 4. Fluxo de controle

```
boot ──► Recovery.run
           ├─ task_store.running_or_interrupted
           ├─ para cada task: checkpoint_store.latest(id)
           │    ├─ existe  → command_bus.dispatch(Command[:resume_task, {task_id:}])
           │    └─ nenhum  → task_store.transition(id, to: :failed,
           │                   error: {class: "Harness::Error",
           │                           message: "irrecuperável: sem checkpoint"})
           └─ retorna sumário {resumed:, failed:} (logado + evento por task)

turno (estágio 8 da pipeline, doc 03):
  executor ──► checkpoint_store.save(cp turno n+1)   # transação atômica
           ──► session_store.append_messages(...)     # se session_id (D2)
           ──► task_store.finish_execution / transition
           ──► emite :checkpoint_created
```

A recuperação **usa o mesmo caminho do `ResumeTask`** (D3): um código só para
crash-recovery e resume manual — o boot apenas descobre e despacha.

## 5. Concorrência

- `Recovery.run` roda **antes** do servidor aceitar conexões, dentro do
  reactor Async do boot; as retomadas são despachadas como fibers normais de
  task (não bloqueiam o boot além do dispatch).
- Escritas do estágio Persistence acontecem no fiber da própria task — sem
  fan-out. A ordem dentro do estágio é fixa: checkpoint → session → task
  (ver L4).
- `transition` usa read-modify-write sem lock: um nó, um dono por task
  (D7). A validação da máquina de estados detecta corridas lógicas (transição
  inválida → erro alto e cedo).

## 6. Erros e timeouts

- Stores de domínio propagam `Harness::StoreError` do backend sem embrulhar de
  novo; adicionam `ArgumentError` para violações de domínio (transição
  inválida, sessão duplicada, checkpoint com turn não-monotônico).
- `Recovery`: falha ao retomar **uma** task não derruba o boot — a task vai a
  `:failed` com o erro registrado e o boot continua (evento `:task_failed`).
  Falha do próprio store no boot (ex.: arquivo corrompido) → aborta o
  processo com mensagem clara: subir sem durabilidade seria pior que não subir.
- Sem timeouts próprios: os do backend (doc 01 §6) bastam.
- **Invariante D4:** `CheckpointStore.save` é all-or-nothing; um crash no meio
  do estágio Persistence deixa o checkpoint do turno anterior válido e a task
  em `running` — o Recovery a retoma reexecutando o turno.

## 7. Estratégia de testes

- Stores de domínio rodam contra `Stores::Memory` (a paridade com SQLite é
  garantida pela suíte de contrato do doc 01) + um smoke com SQLite real.
- `TaskStore`: tabela de transições — todas as válidas passam, todas as
  inválidas levantam; Executions preservam histórico em retry.
- `CheckpointStore`: monotonicidade de turn; `latest` correto com turnos
  esparsos; side-effects idempotentes (registrar duas vezes = uma entrada);
  `prune` preserva o último.
- `Recovery`: cenários — task `running` com checkpoint → dispatch de resume;
  sem checkpoint → `:failed`; store vazio → no-op; mistura. `command_bus`
  é um duplo que grava os dispatches.
- Crash-consistency: simular exceção **dentro** da transação de `save` e
  verificar que `latest` ainda retorna o checkpoint anterior.
- Zero RubyLLM / zero API key.

## 8. Evolução a partir da Fase 0

Componente **novo** (o gap central — RFC-0006 §8). Pontos de contato com a
Fase 0:

- O shape de `messages` reusa o formato que `Runner#seed_history` já aceita
  (`{role:, content:}`) — o Executor não precisa converter nada.
- `config/wiring.rb` ganha a construção: backend → 3 stores de domínio →
  `Recovery` (injetado no boot do doc 07).

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Máquina de estados validada no `TaskStore` (não no Executor) | o store é o único ponto de escrita de status; invariantes moram onde a escrita mora |
| L2 | ids `SecureRandom.uuid` com prefixo lógico nas chaves (`task:<uuid>`) | sem coordenação, seguro multi-processo futuro; prefixo mantém `list` por tipo |
| L3 | Checkpoint materializa o transcript (não cursor) | autossuficiência na retomada > custo de espaço; RFC-0006 §9.1 (tamanho) mitigado por `prune(keep: 1)` ao completar e pelo GC da Fase 2. Revisitar se sessões longas doerem |
| L4 | Ordem de escrita: checkpoint → session → task | se cair entre escritas, o pior caso é checkpoint novo com task ainda `running` → Recovery reexecuta turno já salvo, que é seguro (idempotência por side-effect registry). A ordem inversa poderia marcar `completed` sem checkpoint |
| L5 | `resume` responde tool calls não-idempotentes já feitas com marcador `skipped` | reexecutar violaria RFC-0006 §5; omitir a resposta quebraria o protocolo de tool-use do provider |
| L6 | `prune(keep: 1)` embutido na conclusão da task | evita crescimento ilimitado já na Fase 1 sem esperar o GC da Fase 2 |
