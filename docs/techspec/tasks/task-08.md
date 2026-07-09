# Task 08: `Recovery` no boot (varredura + dispatch de resume; bus como duplo até a task 13)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [02-session-task-checkpoint.md](../02-session-task-checkpoint.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Implementar `Harness::Recovery`: no boot, varrer tasks interrompidas, despachar `resume_task` para as que têm checkpoint e marcar `:failed` as irrecuperáveis — sem que a falha de uma task derrube o boot, e abortando se o próprio store estiver corrompido (doc 02 §4, §6).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 6 | `TaskStore` (máquina de estados validada, Executions, campos de claim reservados) | ⬜ TODO |
| 7 | `CheckpointStore` (checkpoint por turno, chave avulsa de side-effects, `prune`) | ⬜ TODO |

## Context

Última task da Etapa B. É a metade "descoberta" da durabilidade sem job runner externo (restrição 4, doc 00 §5): durabilidade = stores + recovery no boot. A metade "execução" é o handler `ResumeTask` (task 13, doc 03) — a recuperação **usa o mesmo caminho do `ResumeTask`** (D3): um código só para crash-recovery e resume manual; o boot apenas descobre e despacha (doc 02 §4).

Como o `CommandBus` real só existe a partir da task 09 e o handler `ResumeTask` só na task 13, **nesta task o `command_bus` é um DUPLO de teste** que grava os dispatches (doc 02 §7). O `Recovery` só depende do contrato `dispatch(command)`; a integração real (wiring no boot do doc 07 §4, antes de aceitar requests) acontece nas tasks 13 e 26. Não construa nenhum bus aqui.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/recovery.rb` | Classe `Harness::Recovery` |
| MODIFY | `lib/harness.rb` | Adicionar `require_relative "harness/recovery"` |
| CREATE | `spec/harness/recovery_spec.rb` | Specs com stores reais (Memory) e `command_bus` duplo |

### Step-by-Step Instructions

#### Step 1: Classe `Recovery`

**File:** `lib/harness/recovery.rb`

```ruby
# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Chamado uma vez no boot, ANTES de aceitar requests (doc 07 §4).
  # Descobre tasks interrompidas e despacha a retomada pelo MESMO caminho
  # do ResumeTask (D3) — este componente não executa nada.
  class Recovery
    def initialize(task_store:, checkpoint_store:, command_bus:)
    def run   # -> { resumed: [ids], failed: [ids] }
  end
end
```

Atenção: a interface do doc 02 §2 lista só `task_store:` e `command_bus:`, mas o fluxo do §4 consulta `checkpoint_store.latest(id)` — o parâmetro `checkpoint_store:` é necessário (lacuna do techspec; registrada em Notes).

**Reference pattern from codebase** (classe pequena com dependências injetadas no `initialize`, comentários em pt — `docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb`):

```ruby
# frozen_string_literal: true

module AgentRuntime
  # Convenção OpenClaw / AgentSkills: ...
  class SkillCatalog
    # roots ordenados por PRECEDÊNCIA (maior primeiro): workspace, managed,
    # bundled. Mesmo nome em mais de um root: o primeiro vence.
    def initialize(roots)
      @roots = Array(roots)
      @skills = load_all
    end
    # ...
  end
end
```

#### Step 2: `run` — o fluxo do doc 02 §4, literal

```
run
 ├─ task_store.running_or_interrupted           # status running/waiting/paused
 ├─ para cada task:
 │    checkpoint_store.latest(task.id)
 │      ├─ existe  → command_bus.dispatch(comando resume_task)  → resumed << id
 │      └─ nenhum  → task_store.transition(task.id, to: :failed,
 │                     error: { class: "Harness::Error",
 │                              message: "irrecuperável: sem checkpoint" })
 │                                                              → failed << id
 └─ retorna { resumed: [...], failed: [...] }
```

O comando despachado é o tipo compartilhado `Harness::Command` (doc 00 §2, task 01):

```ruby
Command.new(
  type: :resume_task,
  payload: { task_id: task.id },
  meta: { command_id: SecureRandom.uuid, transport: :recovery,
          issued_at: Time.now.utc.iso8601 }
)
```

(`meta` segue o shape de doc 00 §2 — `{command_id:, tenant:, transport:, issued_at:}`; `tenant` omitido na Fase 1. `transport: :recovery` distingue o boot de um resume manual vindo do HTTP — útil para log/auditoria, sem semântica adicional.)

`Recovery` **não** executa a retomada, não abre Execution, não mexe no status das tasks retomáveis — tudo isso é do handler `ResumeTask` (doc 03, task 13). Aqui só descoberta + dispatch + marcação de irrecuperáveis.

#### Step 3: Tolerância a falha por task vs. falha do store (doc 02 §6)

Duas classes de erro, tratamentos opostos:

- **Falha ao retomar UMA task não derruba o boot**: envolver o processamento de cada task em `begin/rescue`. Se `dispatch` (ou `latest`) levantar algo que não seja `StoreError`, tentar `task_store.transition(id, to: :failed, error: {class: e.class.name, message: e.message, stage: "recovery"})`, adicionar o id a `failed:` e **continuar o loop**. Se a própria transição de fallback levantar (ex.: `paused → failed` é inválida na máquina — ver Notes), capturar, registrar o id em `failed:` mesmo assim e seguir: o boot nunca para por causa de uma task.
- **Falha do próprio store aborta o boot**: `Harness::StoreError` (backend corrompido, disco, etc.) **re-raise** — tanto na varredura inicial quanto dentro do loop. "Subir sem durabilidade seria pior que não subir" (doc 02 §6). Quem converte isso em exit com mensagem clara é o `Server::Boot` (task 26); aqui basta propagar.

Não usar `rescue Exception`; `rescue => e` (StandardError) com re-raise de `StoreError` antes (`rescue Harness::StoreError; raise`).

#### Step 4: Sumário e observabilidade

- Retornar `{ resumed: [ids], failed: [ids] }` — o §4 pede o sumário "logado + evento por task". Log: `warn`/`info` simples via `$stderr` ou um `logger:` opcional no `initialize` (default `nil` → silencioso em teste). **Eventos** (`:task_failed`) exigem o Event Stream do Executor (task 10) — fora do alcance desta task; ver Notes.
- Sem concorrência própria: o doc 02 §5 diz que o `run` roda dentro do reactor Async do boot e as retomadas viram fibers **do lado do handler**; para o `Recovery`, `dispatch` é uma chamada síncrona que retorna rápido (Commands de turno retornam `task_id` imediatamente, D3). Nenhum `Async` aqui.

### Edge Cases to Handle

1. **Store vazio** → `run` retorna `{resumed: [], failed: []}` sem tocar no bus (no-op, doc 02 §7).
2. **Task `running` com checkpoint** → dispatch de `resume_task`; status **não** muda aqui.
3. **Task `running`/`waiting` sem checkpoint** → `:failed` com `{class: "Harness::Error", message: "irrecuperável: sem checkpoint"}` (fecha a Execution aberta, se houver — semântica do `transition` com `error:`, task 06).
4. **Task `paused` sem checkpoint** → `transition(:failed)` levanta `ArgumentError` (`paused → failed` não está na máquina, doc 02 §2). Tratar via rescue por-task: id vai para `failed:` no sumário, task permanece `paused`, boot continua. Lacuna do techspec — registrada em Notes, não "consertar" a máquina aqui.
5. **`dispatch` levanta** (handler futuro com bug, bus indisponível) → task marcada `:failed` com o erro, boot continua.
6. **`StoreError` em qualquer ponto** → propaga (aborta o boot).
7. **Mistura** (retomáveis + irrecuperáveis + completadas) → completadas/terminais nem aparecem (`running_or_interrupted` já filtra); as demais caem no braço certo.
8. **Ordem de dispatch** — não prometa ordem; o retorno usa a ordem da varredura (lexicográfica do `list`, doc 01 §2), suficiente e determinística para teste.

## Testing

### Unit Tests

**File:** `spec/harness/recovery_spec.rb`

Stores reais (`TaskStore`/`CheckpointStore` sobre `Stores::Memory`) + **`command_bus` duplo que grava os dispatches** (doc 02 §7):

```ruby
# Duplo mínimo — a integração real do bus é a task 13.
class RecordingBus
  attr_reader :dispatched
  def initialize(raise_on: nil) = (@dispatched = []; @raise_on = raise_on)
  def dispatch(command)
    raise @raise_on if @raise_on
    @dispatched << command
  end
end
```

| Test Case | Description | Expected |
|-----------|-------------|----------|
| running com checkpoint → resume | task `running` + checkpoint turn 1 | 1 dispatch `type: :resume_task`, `payload {task_id:}`; id em `resumed:`; status continua `running` |
| waiting/paused com checkpoint → resume | uma task em cada status, ambas com checkpoint | 2 dispatches; ambas em `resumed:` |
| running sem checkpoint → failed | task `running`, zero checkpoints | nenhum dispatch; status `:failed`; Execution aberta fechada com `error` `{class: "Harness::Error", message: "irrecuperável: sem checkpoint"}`; id em `failed:` |
| store vazio → no-op | nenhuma task | `{resumed: [], failed: []}`; bus não chamado |
| mistura | 1 running c/ cp, 1 waiting s/ cp, 1 completed, 1 cancelled | 1 resumed, 1 failed; terminais intocadas |
| falha de UMA task não derruba o boot | bus que levanta `RuntimeError` no dispatch | `run` **não** levanta; task vai a `:failed` com o erro (`stage: "recovery"`); id em `failed:` |
| falha de uma não contamina as outras | 2 retomáveis, bus levanta só na 1ª (duplo com contador) | 2ª é despachada normalmente; sumário `resumed: [id2], failed: [id1]` |
| paused sem checkpoint | task `paused`, zero checkpoints | `run` não levanta; id em `failed:`; status permanece `paused` (transição inválida absorvida) |
| store corrompido aborta | `task_store` cujo backend levanta `Harness::StoreError` em `running_or_interrupted` (ou em `latest`) | `run` **propaga** `StoreError` |
| shape do Command | inspecionar `bus.dispatched.first` | `Harness::Command` com `type: :resume_task`, `payload {task_id:}`, `meta` com `command_id`/`issued_at`/`transport: :recovery` |
| sumário | cenário misto | Hash exatamente `{resumed: [...], failed: [...]}` |

### Integration Tests (if applicable)

Não aplicável nesta task. A integração real — `Recovery` despachando num `CommandBus` de verdade com handler `ResumeTask` — é a task 13; o E2E de boot (`kill -9` + reboot) é a task 26 (doc 00 §6).

## Definition of Done

- [ ] `Harness::Recovery#run` implementa o fluxo do doc 02 §4 (varredura → latest → dispatch OU `:failed`) e retorna `{resumed:, failed:}`
- [ ] `command_bus` consumido apenas pelo contrato `dispatch(command)`; testes usam duplo que grava dispatches (doc 02 §7)
- [ ] Falha ao retomar uma task não derruba o boot (task vai a `:failed`, loop continua) — doc 02 §6
- [ ] `Harness::StoreError` propaga (boot aborta) — doc 02 §6
- [ ] Comando despachado é `Harness::Command` (`:resume_task`, `payload {task_id:}`, doc 00 §2)
- [ ] Nenhuma execução/mudança de status das tasks retomáveis dentro do `Recovery` (D3: quem retoma é o caminho do `ResumeTask`)
- [ ] Specs verdes contra Memory (stores reais das tasks 06/07)
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (doc 02 §7)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Lacuna 1 (assinatura):** o doc 02 §2 declara `initialize(task_store:, command_bus:)`, mas o fluxo do §4 usa `checkpoint_store.latest` — adicionamos `checkpoint_store:` como terceiro parâmetro nomeado. Divergência consciente da interface escrita, exigida pelo próprio doc; sinalizar no PR para eventual errata do techspec.
- **Lacuna 2 (`paused → failed`):** a máquina de estados (doc 02 §2) não permite `paused → failed`, mas o fluxo do §4 marca `:failed` qualquer interrompida sem checkpoint — incluindo `paused`. Tratado aqui via rescue por-task (task permanece `paused`, id reportado em `failed:`). Alternativa seria ampliar a máquina, mas isso é mudar o plano — decisão para os autores do techspec.
- **Lacuna 3 (eventos):** o §4 pede "evento por task" (`:task_failed`, §6), mas o Event Stream nasce no Executor (task 10) e o `Recovery` não recebe emissor na interface. Nesta task fica log + sumário; quando a task 13 fizer a integração real, avaliar injetar o emissor ou deixar o handler `ResumeTask`/Executor emitir.
- `meta.transport: :recovery` no Command é escolha local (o shape de `meta` em doc 00 §2 tem o campo `transport`, sem enum fechado); se a task 09 definir valores canônicos de `transport`, alinhar.
- O wiring real (backend → 3 stores → `Recovery` no boot, antes do listen) está descrito no doc 02 §8 e doc 07 §4 — é montado nas tasks 13/26, não aqui.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 11 novos (todos passando; stores reais + bus duplo), 236 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/command.rb`, `lib/harness/recovery.rb`, `spec/harness/recovery_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (requires sem side-effects)
- **Observações / decisões tomadas:**
  - **Desvio do plano registrado:** o tipo `Harness::Command` (overview §2) era atribuído à task 01 mas nunca foi criado lá. Introduzi-o em `lib/harness/command.rb` (definição idêntica ao overview §2) porque o Recovery despacha `:resume_task`. A task 09 constrói o `CommandBus` + handlers **sobre este tipo** (deve reusar, não recriar).
  - **Lacuna 1 (assinatura):** `initialize` recebe `checkpoint_store:` além de `task_store:`/`command_bus:` — o fluxo do §4 usa `checkpoint_store.latest`, embora o §2 só liste dois parâmetros. Divergência consciente exigida pelo próprio doc.
  - **Lacuna 2 (`paused → failed`):** transição inválida na máquina (doc 02 §2); absorvida via rescue por-task — a task permanece `paused`, mas o id é reportado em `failed:`. Não "consertei" a máquina (Don't change the plan).
  - **Lacuna 3 (eventos):** o §4 pede evento por task, mas o Event Stream nasce no Executor (task 10) e o Recovery não recebe emissor. Fica log opcional (`logger:` default `nil`) + sumário; reavaliar na task 13.
  - Tolerância a falha: `StoreError` (varredura ou loop) **propaga** e aborta o boot; qualquer outro erro por-task marca `:failed` (stage `recovery`) e o loop continua. `fail_task` absorve `ArgumentError` de transição inválida mas re-propaga `StoreError`.
  - `Recovery` não executa retomada, não abre Execution, não muda status de tasks retomáveis (D3).
  - `meta.transport: :recovery` distingue boot de resume manual; alinhar se a task 09 fixar enum de `transport`.
