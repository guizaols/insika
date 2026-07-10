# Task 09 (P2): `SessionActor` — fila FIFO por sessão

> **Techspec:** [P2-03-sessions-as-actors.md](../P2-03-sessions-as-actors.md) (L1-L2).
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** C · **Depende:** task 1

## Objetivo
Um fiber por sessão que **serializa** os turnos daquela sessão (um por vez, FIFO),
eliminando a corrida de dois `send_message` concorrentes no mesmo `session_id`
(read-modify-write no transcript). Vive no escopo supervisionado (L4).

## Interface (`lib/harness/session_actor.rb`)
```ruby
def initialize(session_id:, executor:, parent:)  # parent = supervisor (turn_parent)
def enqueue(task, profile:, resume_from: nil)      # -> task.id; FIFO, não-bloqueante
def running?  # há turno em execução?
def depth     # tamanho da fila (observabilidade/UI)
def stop      # encerra o loop (shutdown/testes)
```
Loop: `dequeue` (bloqueia quando vazio) → `executor.run_serial(task, ...)` (spawn +
wait do turno — serialização) → repete. Erros do turno são mapeados dentro do
próprio turno (o SessionActor não morre).

## Executor (integração mínima nesta task)
- `run_serial(task, profile:, resume_from:)`: `spawn(...)` (turno nasce filho do
  supervisor, não-bloqueante) + `@running[task.id]&.wait` (aguarda ESTE turno
  antes de retornar → serialização). Erro interno do turno não derruba o loop.
- `session_actor(session_id)`: registro lazy `@session_actors[id]`, parent = `turn_parent`.
- `stop_session_actors`: para todos (shutdown/testes — o loop bloqueia p/ sempre).

(A ligação de `SendMessage`/recovery é a task 10.)

## Edge / limitações (fatia A)
- Cancelar/pausar um turno AINDA na fila: `cancel`/`pause` da Fase 1 só afetam
  fibers vivos; um turno `:queued` sem fiber é no-op (cancel de enfileirado é
  limitação documentada — descarte-na-fila é fatia seguinte).
- SessionActor ocioso vive até o shutdown (idle-GC adiado — decisão do plano).

## Testes (`spec/harness/session_actor_spec.rb`)
- enqueue FIFO; só um `running?` por vez (2 turnos → o 2º só roda após o 1º);
  `depth`; ordem de conclusão = ordem de enqueue. FakeChat/duplo determinístico,
  sem `ruby_llm`. `stop` ao final p/ o Sync sair.

## DoD
- [ ] SessionActor + run_serial/session_actor/stop; specs verdes; suíte verde
