# Task 03 (P2): Command `PauseTask`

> **Techspec:** [P2-01-actor-mailbox.md](../P2-01-actor-mailbox.md) (Files to Touch, edge 1/6)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A · **Depende:** tasks 1, 2

## Objetivo
Command de controle que posta `:pause` na mailbox do turno vivo. Espelha o
`CancelTask` (Fase 1): valida, acha a task, posta, devolve o estado corrente.
No-op idempotente se não há fiber vivo (terminal/órfã).

## Mudanças
- `lib/harness/executor.rb`: `pause(task_id)` — posta `:pause` no actor vivo
  (`@running[id]&.post(:pause)`); retorna se havia fiber. Espelha `#cancel`.
- `lib/harness/commands/pause_task.rb`: `PauseTask.new(task_store:, executor:)`;
  `call` valida `task_id`, `find` (NotFoundError), `executor.pause`, devolve a
  Task corrente. (O evento `:task_paused` é emitido pelo Executor ao suspender,
  não aqui — task 2.)
- `lib/harness.rb`: require do `pause_task`.
- `config/wiring.rb`: registra `:pause_task` no bus.

## Edge cases
- task terminal/órfã (sem fiber) → no-op; devolve a Task.
- `task_id` ausente → ValidationError; inexistente → NotFoundError.

## Testes (`spec/harness/commands/pause_task_spec.rb`)
- posta `:pause` (executor-spy) e devolve a Task.
- no-op quando não há fiber vivo.
- ValidationError/NotFoundError.

## DoD
- [ ] `Executor#pause` + `PauseTask` + registro + require
- [ ] specs verdes; suíte inteira verde
