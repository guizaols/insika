# Task 02 (P2): Suspensão `:paused` no Executor (fronteiras de estágio)

> **Techspec:** [P2-01-actor-mailbox.md](../P2-01-actor-mailbox.md) (L1, "Executor — ponto de suspensão")
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** A · **Depende:** task 1

## Objetivo
Fazer o Executor **suspender de verdade** um turno quando o operador pede pausa,
usando o primitivo `await` (task 1). Ativa o estado `:paused` (hoje reservado).

## Mudanças (`lib/harness/executor.rb`)
- Helper `drain_and_maybe_suspend(task, actor)`: `actor.drain!`; se
  `actor.pause_requested?` → `transition(:paused)` + `emit(:task_paused)` →
  `actor.await(reason: :paused)` (bloqueia) → `transition(:running)` +
  `emit(:task_resumed)`.
- Substitui os `actor.drain!` das **fronteiras seguras** (após estágio 2, após
  estágio 3, estágio 5) por `drain_and_maybe_suspend`. O `drain!` do **estágio
  8** permanece puro (janela proibida — D4; não suspende durante persistência).

## Semântica
- `:cancel` durante a espera → `await` levanta `CancelledError` → captura única
  do topo do fiber → `:cancelled` (transição `paused → cancelled` válida).
- `:timeout` durante a espera → `TimeoutError` → `fail_task` (stage da espera).
- checkpoint inicial do turno já gravado antes das fronteiras → `kill -9` em
  `:paused` é retomável (task 4 trata `:paused` como interrompida).

## Testes (`spec/harness/executor_pause_spec.rb`)
- turno com `:pause` na fronteira → `:task_paused` → bloqueia → `:resume` →
  `:task_resumed` → conclui; ordem dos eventos; checkpoint intacto.
- `:cancel` durante `:paused` → `:cancelled` (transição válida; nenhum evento
  após `:task_cancelled`).
- sem pausa → fluxo idêntico à Fase 1 (nenhum `:task_paused`).
- FakeChat com `gate` (sem `ruby_llm`/chave).

## DoD
- [ ] suspensão nas 3 fronteiras seguras; estágio 8 intacto
- [ ] eventos `:task_paused`/`:task_resumed`; transições válidas
- [ ] specs verdes; suíte inteira verde; sem regressão
