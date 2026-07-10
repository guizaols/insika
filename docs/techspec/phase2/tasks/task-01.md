# Task 01 (P2): Estender `TaskActor` — mailbox completa + primitivo de suspensão

> **Techspec:** [P2-01-actor-mailbox.md](../P2-01-actor-mailbox.md) (L1–L4)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo
Ampliar o enum da mailbox e dar ao `TaskActor` o primitivo de **suspensão
cooperativa** (`await`) que o Executor (task 2) usará para `:paused`/`:waiting`.
Não integra o Executor ainda (task 2).

## Mudanças (`lib/harness/task_actor.rb`)
- `MESSAGES = %i[cancel user_message approval pause resume timeout heartbeat]`.
- `drain!` (fronteira, não-bloqueante) roteia:
  - `:cancel` → `raise CancelledError` (inalterado)
  - `:pause` → seta `@pause_requested = true`
  - `:user_message` → acumula (inalterado)
  - `:heartbeat` → incrementa `@heartbeats`
  - `:resume`/`:approval`/`:timeout` → **não processa**; guarda em
    `@pending_resolutions` (são respostas de `await`, não podem ser perdidas se
    chegarem numa fronteira antes da suspensão — edge da corrida).
- `pause_requested?` → lê o flag; o Executor o consome e a suspensão o limpa.
- `await(reason:)` (BLOQUEIA o fiber, cede o reactor):
  1. consome `@pending_resolutions` primeiro (resolução já chegou);
  2. senão `@mailbox.dequeue` em loop (bloqueia) até uma resolução;
  3. `:cancel` → `raise CancelledError`; `:timeout` → `raise TimeoutError(stage:)`;
     `:resume` → `[:resume, nil]`; `:approval` → `[:approval, decision]`;
     `:pause`/`:heartbeat`/`:user_message` recebidos durante a espera são
     absorvidos (não resolvem).
- Limpa `@pause_requested` ao entrar em `await` (a pausa está sendo tratada).

## Edge cases (P2-01)
- `:cancel` durante `await` → `CancelledError` (o topo do fiber mapeia `:cancelled`).
- `:resume` sem pausa pendente → absorvido/ignorado (idempotente).
- Resolução chegando numa fronteira antes do `await` → buffer `@pending_resolutions`.

## Testes (`spec/harness/task_actor_spec.rb`, estende)
- enum aceita as novas; fora do enum → ArgumentError.
- `drain!` seta `pause_requested?`; `:heartbeat` conta; `:resume` guardado no buffer.
- `await` retorna no `:resume`/`:approval(payload)`; `:cancel` levanta; `:timeout`
  levanta `TimeoutError`; resolução pré-bufferizada retorna sem bloquear.
- Tudo dentro de `Sync`/`Async` (sem `ruby_llm`).

## DoD
- [ ] enum + drain! + await + pause_requested? implementados
- [ ] specs verdes; suíte inteira verde; sem regressão
