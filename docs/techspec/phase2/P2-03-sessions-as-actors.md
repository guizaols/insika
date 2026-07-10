# P2-03 — Sessions como Actors (serialização de turnos por sessão)

> **RFC base:** 0002 §9 (Sessions como Actors). **Evolui:**
> `lib/harness/commands/send_message.rb`, `lib/harness/executor.rb`. **Overview:** D4.

## Objetivo

Na Fase 1, cada `send_message` vira uma Task com fiber próprio; dois no mesmo
`session_id` corriam no mesmo transcript (read-modify-write concorrente →
entrelaçamento). A Fase 2 introduz o **`SessionActor`**: um fiber por sessão com
**fila FIFO de turnos**, executando um turno por vez. Turnos de sessões distintas
seguem concorrentes; one-shot/history (sem `session_id`) seguem Tasks avulsas.

## Estado atual (Fase 1)

- `SendMessage#call` valida, cria a Task e chama `@executor.spawn(task, profile:)`
  imediatamente. Sem coordenação entre turnos da mesma sessão.
- `SessionStore#append_messages` é read-modify-write no fiber da task, "sem lock;
  um dono por task" (doc 02 §5, D7) — premissa que **quebra** com dois turnos
  concorrentes na mesma sessão. O `SessionActor` restaura o invariante "um dono
  por vez".
- O Executor já roda turnos no escopo supervisionado (L4, follow-up da Fase 1) —
  o `SessionActor` vive no mesmo escopo.

## Decisões

### L1 — 1 `SessionActor` por sessão, criado lazy, no escopo supervisionado
Registro in-process `session_id → SessionActor` no Executor (como `@running` para
tasks). Criado no primeiro `send_message` daquela sessão; parenteado no supervisor
(L4) para sobreviver à conexão. Sessão ociosa não tem actor.

### L2 — Fila FIFO; um turno por vez; ordem de chegada
O `SessionActor` tem uma `Async::Queue` de turnos pendentes. `enqueue(task)`
coloca; o loop do actor faz `execute` de um turno, **aguarda a conclusão**
(`actor.wait` do turno), e só então pega o próximo. Serialização = correção do
transcript. A ordem é a de dispatch (FIFO) — determinística.

### L3 — Enfileirar NÃO bloqueia o handler (resposta 202 imediata mantida)
`SendMessage#call` continua retornando `{task_id:}` na hora. `enqueue` é O(1) e
não-bloqueante; o turno pode ficar na fila (estado `:queued`, que o `TaskStore`
já tem) até o anterior terminar. O cliente observa a progressão pelo Event Stream
/ `GET /v1/tasks/:id` (task fica `:queued` → `:running` quando o actor a puxa).

### L4 — Só sessão coordena; turno sem sessão é avulso
`send_message` com `session_id` → `session_actor(session_id).enqueue(task)`.
`send_message` sem `session_id` (one-shot/history, D2 da Fase 1) → `executor.spawn`
direto, como hoje. `trigger_workflow`/`resume_task` idem: se têm `session_id`,
passam pela fila da sessão (garante que uma retomada não corre com um turno novo
da mesma sessão).

### L5 — Recovery reidrata a fila, preservando ordem por `created_at`
No boot, o Recovery acha tasks `:queued`/`:running`/`:waiting`/`:paused` da mesma
sessão. Reenfileira na ordem de `created_at` no `SessionActor` (uma órfã `:running`
vira retomada; as `:queued` seguem atrás). Assim a serialização sobrevive a
`kill -9`. (O Executor expõe um `enqueue_resume` usado pelo `ResumeTask`.)

### L6 — Cancelar/pausar um turno na fila
`CancelTask`/`PauseTask` de um turno ainda `:queued` (não iniciado): o Executor
marca a task e o `SessionActor` **descarta** da fila ao chegar nele (não spawna).
De um turno `:running`: comportamento da Fase 1 / P2-01 (posta na mailbox do
turno). O `SessionActor` nunca é cancelado por um Command de task — ele é
infraestrutura da sessão (só morre no shutdown/idle-GC — Fase 2+; na fatia A
vive enquanto o processo).

## Interfaces

### `SessionActor`
```ruby
def initialize(session_id:, executor:, parent:)  # parent = supervisor (L4)
def enqueue(task, profile:, resume_from: nil)     # -> task.id; FIFO, não-bloqueante
def running?  # há turno em execução?
def depth     # tamanho da fila (observabilidade/UI)
# loop interno: dequeue -> (se não cancelada) executor.execute no fiber do actor -> wait -> repeat
```

### `Executor` (integração)
```ruby
def spawn_in_session(task, profile:, resume_from: nil)
  return spawn(task, profile:, resume_from:) if task.session_id.nil?  # avulso (L4)
  session_actor(task.session_id).enqueue(task, profile:, resume_from:)
end

private
def session_actor(id)  # lazy, registro in-process, parent: @supervisor
```
`SendMessage`/`ResumeTask`/`TriggerWorkflow` passam a chamar `spawn_in_session`
em vez de `spawn`.

## Files to Touch

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `lib/harness/session_actor.rb` | fila FIFO por sessão (L1/L2) |
| MODIFY | `lib/harness/executor.rb` | `spawn_in_session` + registro `@session_actors` lazy no supervisor; `enqueue_resume` p/ recovery |
| MODIFY | `lib/harness/commands/send_message.rb` | `spawn` → `spawn_in_session` |
| MODIFY | `lib/harness/commands/resume_task.rb` | idem (respeitando a sessão) |
| MODIFY | `lib/harness/commands/trigger_workflow.rb` | idem |
| MODIFY | `lib/harness/recovery.rb` | reidratar fila por `created_at` (L5) |
| MODIFY | `lib/harness.rb` | require |
| CREATE | `spec/harness/session_actor_spec.rb` | FIFO, um-por-vez, depth, descarte de cancelada |
| CREATE | `spec/harness/integration/session_serialization_spec.rb` | 2 turnos concorrentes na mesma sessão → transcript consistente, ordem FIFO |

## Edge Cases

1. **Dois `send_message` quase-simultâneos, mesma sessão** → ambos 202; segundo
   fica `:queued` até o primeiro concluir; transcript recebe as mensagens na
   ordem FIFO, sem entrelaçamento.
2. **Sessões diferentes** → actors distintos, concorrência preservada.
3. **Turno na fila cancelado antes de iniciar** → descartado no dequeue; task
   `:cancelled` (transição `queued → cancelled` é válida); nunca spawna.
4. **Turno da fila que trava em `:waiting` (aprovação)** → o `SessionActor`
   **bloqueia a fila** enquanto espera (é o comportamento correto: o próximo
   turno da MESMA sessão não deve correr na frente de uma aprovação pendente).
   Turnos de outras sessões seguem. (Nota: aprovação longa segura a sessão — é
   semanticamente desejado; se virar problema, timeout de aprovação de P2-01 corta.)
5. **`kill -9` com fila** → recovery reidrata por `created_at` (L5).
6. **`session_actor` idle** → fica vivo até o shutdown (idle-GC é fatia/fase
   seguinte; documentar como leak controlado — 1 fiber ocioso por sessão vista).

## Testing (resumo)
- `SessionActor`: enqueue FIFO; só um `running?` por vez; `depth`; descarte de
  cancelada.
- Integração: dois turnos concorrentes na mesma sessão (FakeChat determinístico)
  → transcript = ordem FIFO, 2 pares user/assistant sem entrelaçar; duas sessões
  → concorrem. Sem `ruby_llm`/chave.
- Recovery: fila reidratada por `created_at`.
