# P2-01 — Mailbox completa do Actor + estados `:waiting`/`:paused`

> **RFC base:** 0002 §9 (faseamento do Actor). **Evolui:** `lib/harness/task_actor.rb`,
> `lib/harness/executor.rb`, `lib/harness/task_store.rb` (Fase 1). **Overview:**
> [00-overview.md](./00-overview.md) (D1).

## Objetivo

Completar o modelo de Actor da Fase 1. Hoje o `TaskActor` só entende `:cancel`
(`:user_message` é reservado, sem produtor). A Fase 2 acrescenta as mensagens
`approval`, `pause`, `resume`, `timeout`, `heartbeat` e faz o Executor **suspender
de verdade** um turno em `:paused` (operador) e `:waiting` (auto-induzido) —
estados que o `TaskStore` já reserva mas nenhum caminho emitia.

## Estado atual (Fase 1)

- `TaskActor::MESSAGES = %i[cancel user_message]`; `drain!` roteia só esses, e é
  chamado **nas fronteiras de estágio** (cancelamento cooperativo, doc 03 L2).
- `TaskStore::STATUSES` inclui `:waiting`/`:paused`; `TRANSITIONS` já permite
  `running → waiting|paused`, `waiting → running|cancelled|failed`,
  `paused → running|cancelled`. **Nenhum código emite `:waiting`/`:paused`.**
- `Executor#cancel(id)` posta `:cancel`; o topo do fiber mapeia `CancelledError`
  → `:cancelled`.

## Decisões

### L1 — Suspensão é COOPERATIVA, no mesmo ponto do cancelamento
Pausar não interrompe uma operação em voo (mesma regra do cancel, doc 03 L2). O
`:pause` é drenado **nas fronteiras de estágio**; ao vê-lo, o Executor transita
`running → paused` e **bloqueia o fiber** aguardando `:resume` (ou `:cancel`).
Nunca no meio do estágio 8 (persistência) — janela proibida (D4 da Fase 1).

### L2 — Bloqueio via `Async::Condition` por actor, não busy-wait
O `TaskActor` ganha uma condição interna. `await_resume` bloqueia o fiber do
turno (cede o reactor, custo zero); `post(:resume)`/`post(:cancel)` sinalizam.
Nada de `sleep`/poll (proibido pelo espírito do doc 01 L4).

### L3 — `:waiting` (auto) vs `:paused` (operador) — mesmos mecanismos, origens distintas
`:paused` é induzido por `PauseTask` (P2-01, task 3). `:waiting` é induzido pelo
próprio turno ao pedir aprovação (P2-02) — vocabulário `INPUT_REQUIRED` do A2A
(RFC-0002 §9). Ambos suspendem pelo mesmo primitivo (L2) e retomam pelo caminho
do `ResumeTask` (D3 da Fase 1). A diferença é semântica/observável (evento e
status), não de mecanismo.

### L4 — `timeout`/`heartbeat` são OBSERVAÇÃO, não controle de fluxo
`:timeout` (watchdog de espera — ex.: `:waiting` além de um teto) e `:heartbeat`
(liveness) são drenados e **emitem evento**; não reescrevem o turno. O teto de
turno já existe (Fase 1, `with_timeout`). O `:timeout` daqui é para espera de
input/approval: um turno `:waiting` além de `profile.limits[:approval_timeout]`
recebe `:timeout` → `:failed` (stage `:approval_timeout`). `:heartbeat` só emite
`:heartbeat` (consumido pela UI/observabilidade; sem efeito no estado).

## Interfaces

### `TaskActor` (evoluído)

```ruby
MESSAGES = %i[cancel user_message approval pause resume timeout heartbeat].freeze

# post(message, data=nil) — inalterado no contrato; enum ampliado.
# drain!(executor_boundary) — roteia:
#   :cancel   -> raise CancelledError            (inalterado)
#   :pause    -> sinaliza suspensão (o Executor transita :paused e chama await_resume)
#   :resume   -> resolve a condição (retoma)
#   :approval -> resolve a condição de :waiting com o payload (approved/rejected)
#   :timeout  -> raise TimeoutError(stage:)      (só quando armado)
#   :heartbeat/:user_message -> acumula/observa  (sem mudar fluxo)
def await(reason:)  # bloqueia o fiber na condição; retorna o payload do resume/approval
```

O `drain!` continua não-bloqueante para as mensagens de controle de fluxo
(`:cancel`); a **suspensão** (`await`) é chamada explicitamente pelo Executor
quando um `:pause`/pedido-de-aprovação é observado — não dentro do `drain!`
(que deve permanecer O(fila) e não-bloqueante).

### `Executor` — ponto de suspensão

Nas fronteiras onde hoje há `actor.drain!`, passa a existir:

```ruby
actor.drain!                 # pode levantar CancelledError (inalterado)
if actor.pause_requested?    # :pause foi drenado
  @task_store.transition(task.id, to: :paused)
  emit(:task_paused, { task_id: }, task:)
  actor.await(reason: :paused)          # bloqueia até :resume/:cancel
  @task_store.transition(task.id, to: :running)
  emit(:task_resumed, { task_id: }, task:)
end
```

Checkpoint: a suspensão acontece **entre estágios**, com o checkpoint inicial do
turno (Fase 1) já gravado — logo um `kill -9` durante `:paused` é retomável (a
task fica `:paused` durável; o recovery a trata como interrompida — task 4).

## Files to Touch

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| MODIFY | `lib/harness/task_actor.rb` | enum ampliado; `Async::Condition` interna; `await`/`pause_requested?`; `drain!` roteando os novos |
| MODIFY | `lib/harness/executor.rb` | ponto de suspensão nas fronteiras; transições `:paused`/`:running`; emissão dos eventos |
| MODIFY | `lib/harness/commands/cancel_task.rb` | (referência) padrão do `PauseTask` |
| CREATE | `lib/harness/commands/pause_task.rb` | Command de controle: posta `:pause` |
| MODIFY | `lib/harness/commands/resume_task.rb` | elegibilidade estendida (task 4): órfã-de-crash ∪ `:paused` ∪ `:waiting` |
| MODIFY | `lib/harness.rb` | require do `pause_task` |
| MODIFY | `lib/harness/event.rb` (catálogo, D5) | novos tipos `:task_paused`/`:task_resumed` |
| CREATE | `spec/harness/task_actor_spec.rb` (estende) | novas mensagens, `await`/resume, cancel durante pausa |
| CREATE | `spec/harness/executor_pause_spec.rb` | suspensão/retomada, checkpoint intacto, cancel de `:paused` |
| CREATE | `spec/harness/commands/pause_task_spec.rb` | posta `:pause`; no-op idempotente terminal/órfã |

## Edge Cases

1. **`PauseTask` de task terminal/órfã** → no-op idempotente (mesma regra do
   `CancelTask`); o handler devolve a Task corrente.
2. **`:cancel` durante `:paused`** → a condição resolve com cancel; o topo do
   fiber mapeia para `:cancelled` (transição `paused → cancelled` é válida).
3. **`:resume` sem pausa pendente** → ignorado (idempotente); logar.
4. **`kill -9` em `:paused`/`:waiting`** → task durável nesse estado; recovery a
   redispacha por `ResumeTask` (task 4). O checkpoint inicial do turno garante
   retomabilidade.
5. **Pausa pedida DURANTE o estágio 8** → não suspende ali (janela proibida);
   a suspensão só ocorre na próxima fronteira — como o estágio 8 é o último, o
   turno conclui e o `:pause` vira no-op (task já terminal). Aceitável.
6. **Dupla pausa** → segunda é no-op (já `:paused`; `paused → paused` inválido no
   `TaskStore`, então o Executor checa o estado antes de transicionar).

## Testing (resumo)

- Actor: cada mensagem nova roteada; `await` bloqueia e resolve no `:resume`;
  `:cancel` durante espera levanta `CancelledError`.
- Executor: turno com `:pause` na fronteira → `:task_paused` → bloqueia →
  `:resume` → `:task_resumed` → conclui; checkpoint anterior intacto; ordem dos
  eventos.
- `PauseTask`: posta `:pause` (spy no executor); no-op sem fiber vivo.
- Sem `ruby_llm`/chave (FakeChat com `gate`, como no `executor_pipeline_spec`).
