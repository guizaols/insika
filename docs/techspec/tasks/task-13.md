# Task 13: Handler `ResumeTask` (critério running-órfã, skip de side-effects) + integração real do Recovery

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Implementar o handler `ResumeTask` (retomada do último checkpoint com critério de elegibilidade running-órfã via `executor.running?` e skip de tool calls não-idempotentes já concluídas — doc 03 §3/§4.1, doc 02 L5), trocar o bus-duplo do `Recovery` (task 8) pelo `CommandBus` real e provar a durabilidade com o teste kill-restart-resume — o critério de conclusão da Etapa C.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 8 | `Recovery` no boot (varredura + dispatch de resume; bus como duplo até a task 13) | ⬜ TODO |
| 12 | Handler `SendMessage` end-to-end (providers stub) + checkpoint no estágio 8 + timeouts D4 | ⬜ TODO |

## Context

Fecha a Etapa C e realiza a promessa central da fase: "fluxo `SendMessage` com `session_id` sobrevive a `kill -9` + reboot retomando do checkpoint" (doc 00 §6). O desenho do D3 é deliberado: **crash-recovery e resume manual usam o mesmo caminho** — o `Recovery` (task 8) apenas descobre tasks interrompidas e despacha `Command[:resume_task, ...]`; toda a lógica de retomada vive neste handler + na variação de resume do Executor (doc 02 §4).

Semântica de retomada (D4/RFC-0006 §5): `ResumeTask` **sempre reexecuta do início do último turno checkpointado**. O checkpoint é autossuficiente (transcript materializado, doc 02 L3); tools não-idempotentes já concluídas constam no side-effect registry e são respondidas com o marcador `{"skipped":"already_executed"}` em vez de reexecutar (doc 02 L5 — reexecutar violaria RFC-0006 §5; omitir a resposta quebraria o protocolo de tool-use do provider).

Critério de elegibilidade (doc 03 §3): `paused`/`waiting` → sempre retomável; `running` → **só** se não houver fiber vivo neste processo (`executor.running?(task_id) == false` ⇒ órfã de crash); fiber vivo → `ValidationError`. Single-node na Fase 1 (D7): o registro in-process é critério suficiente.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/commands/resume_task.rb` | validações síncronas + elegibilidade + spawn com `resume_from` |
| MODIFY | `lib/harness/executor.rb` | caminho de resume em `execute`/`run_pipeline`; skip de side-effects no `ToolEnvelope` |
| MODIFY | `lib/harness/recovery.rb` | ajustes finos (se necessários) para o contrato do bus real; `transport: :recovery` no Command |
| MODIFY | `lib/harness.rb` | require do handler novo |
| CREATE | `spec/harness/commands/resume_task_spec.rb` | matriz de elegibilidade + validações |
| MODIFY | `spec/harness/recovery_spec.rb` | trocar o duplo de bus pelo `CommandBus` real com o handler registrado |
| CREATE | `spec/harness/integration/kill_restart_resume_spec.rb` | crash simulado → "reboot" → Recovery → conclusão com skip |

### Step-by-Step Instructions

#### Step 1: handler `ResumeTask`

**File:** `lib/harness/commands/resume_task.rb`

Payload (doc 03 §3): `{ task_id: String }` → `{ task_id: }` (Command de **turno**: spawna fiber e responde imediato).

```ruby
module Harness
  module Commands
    class ResumeTask
      def initialize(profiles:, task_store:, checkpoint_store:, executor:)

      def call(command)
        task_id = extract(command.payload, :task_id).to_s
        raise ValidationError, "task_id é obrigatório" if task_id.empty?

        task = @task_store.find(task_id) or
          raise NotFoundError, "task '#{task_id}' não encontrada"

        # resume exige checkpoint (doc 03 §3); sem ele a task é irrecuperável
        # (o Recovery já a teria marcado :failed — doc 02 §4)
        checkpoint = @checkpoint_store.latest(task_id) or
          raise ValidationError, "task '#{task_id}' não tem checkpoint — irrecuperável"

        # elegibilidade (doc 03 §3):
        case task.status
        when :paused, :waiting
          # sempre retomável
        when :running
          # só órfã de crash: sem fiber vivo NESTE processo (D7, single-node)
          raise ValidationError, "task '#{task_id}' em execução" if @executor.running?(task_id)
        else # :queued e terminais (:completed, :failed, :cancelled)
          raise ValidationError,
            "task '#{task_id}' com status '#{task.status}' não é retomável"
        end

        # perfil vem do checkpoint (agent_id) — o agente pode ter saído da
        # config entre o crash e o boot: falha alta e clara
        profile = @profiles[checkpoint.agent_id] or
          raise NotFoundError, "agente '#{checkpoint.agent_id}' não configurado"

        @executor.spawn(task, profile: profile, resume_from: checkpoint)
        { task_id: task_id }
      end
    end
  end
end
```

- `:queued` não é retomável: nunca teve turno, logo nunca teve checkpoint — na prática o guard do checkpoint já barra antes; manter a mensagem de status para o caso de dados inconsistentes.
- Todas as validações são **síncronas, antes do fiber** (doc 03 §6).

#### Step 2: caminho de resume no Executor

**File:** `lib/harness/executor.rb`

O fluxo do doc 03 §4.1: "carrega `checkpoint_store.latest`; reconstrói o TurnState com `messages` do checkpoint; abre nova Execution; entra no estágio 2 do turno checkpointado".

Em `execute` (transições — a máquina do doc 02 §2 dita o que é válido):

```ruby
@task_store.begin_execution(task.id)          # nova Execution: attempt N+1 (doc 02 §3)
current = @task_store.find(task.id).status
case current
when :queued          then @task_store.transition(task.id, to: :running)
when :paused, :waiting then @task_store.transition(task.id, to: :running)
when :running         then nil   # órfã: já está :running; running→running é inválido
end
```

Em `run_pipeline` (já preparado na task 12 — confirmar/completar):

- `turn = resume_from.turn` (reexecuta o turno checkpointado inteiro).
- `state.message` continua vindo de `task.command` (o comando persistido) — o checkpoint do turno *n* contém o transcript **até o fim do turno n-1**; a pergunta do turno é a do Command original.
- O `ContextRequest` do estágio 2 leva `checkpoint: resume_from` — o `FakeContextBuilder` (task 12) e o provider `Session` real (doc 04, task 15) usam a precedência `checkpoint → history → session store` para montar o histórico. Nada muda no Executor quando o Builder real chegar.
- **Skip set:** antes do estágio 5, carregar
  `skip = @checkpoint_store.side_effects(task.id, turn: resume_from.turn)`
  (união chave avulsa ∪ checkpoint, doc 02 §2) e passá-lo ao `wrap_tools`.

#### Step 3: skip de side-effects no `ToolEnvelope`

**File:** `lib/harness/executor.rb`

Estender o decorator da task 12 (que já tem a correlação `state.current_tool_call`):

```ruby
class ToolEnvelope < SimpleDelegator
  def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:,
                 skip_side_effects: [])                     # NOVO (task 13)

  def call(args)
    # doc 02 L5 / doc 03 §4.1: tool call não-idempotente JÁ CONCLUÍDA no
    # turno interrompido → responder com marcador, nunca reexecutar
    call_id = @state.current_tool_call&.id
    if call_id && @skip_side_effects.include?(call_id)
      return { "skipped" => "already_executed" }
    end

    result = Async::Task.current.with_timeout(@timeout) { __getobj__.call(args) }
    record_side_effect! if side_effect?
    result
  rescue Async::TimeoutError
    { error: "TimeoutError: tool excedeu #{@timeout}s" }
  end
end
```

- O marcador **volta ao modelo** como resultado da call — o protocolo de tool-use fica íntegro (doc 02 L5).
- `record_side_effect` é idempotente (doc 02 §2) — se a call for re-registrada no re-run, não duplica.
- Emissão de eventos não muda: `:tool_call` é emitido normalmente e `:tool_result` carrega o marcador (auditável no stream).

#### Step 4: Recovery com o bus real

**Files:** `lib/harness/recovery.rb` (+ `spec/harness/recovery_spec.rb`)

A task 8 escreveu o `Recovery` contra um bus-duplo com o contrato `dispatch(command)`. Trocar é wiring, não reescrita:

1. Conferir que o `Recovery` monta o Command com o tipo/payload do doc 02 §4: `Command.build(:resume_task, { task_id: id }, transport: :recovery)` (o `transport` identifica a origem no meta — auditoria; não é enum fechado).
2. Nos specs do Recovery, substituir o duplo por um `CommandBus` real com o handler `ResumeTask` registrado (executor pode continuar duplo aqui — o que se testa é o roteamento e o critério).
3. Comportamento de erro do doc 02 §6 permanece: falha ao retomar **uma** task (ex.: handler levanta `ValidationError`/`NotFoundError`) não derruba o boot — a task vai a `:failed` com o erro registrado e o `run` continua, somando-a ao sumário `failed:`.

**Reference pattern from codebase** (fluxo do boot conforme doc 02 §4 — o Recovery da task 8 já implementa; aqui só troca o destino do dispatch):
```
boot ──► Recovery.run
           ├─ task_store.running_or_interrupted
           ├─ para cada task: checkpoint_store.latest(id)
           │    ├─ existe  → command_bus.dispatch(Command[:resume_task, {task_id:}])
           │    └─ nenhum  → task_store.transition(id, to: :failed, ...)
           └─ retorna sumário {resumed:, failed:}
```

#### Step 5: teste kill-restart-resume

**File:** `spec/harness/integration/kill_restart_resume_spec.rb`

Simula o critério de conclusão da fase (doc 00 §6) em nível de Etapa C, com `Stores::SQLite` sobre arquivo temporário (persistência real entre "processos"):

**Ato 1 — o crash.** Wiring completo A (bus + handlers + executor + stores sobre o arquivo). Dispatch de `send_message` (com `session_id`) com `FakeChat` roteirizado que:
1. dispara uma tool side-effect (`tool_registry` fake com `side_effect?("enviar_pedido") == true`) — o envelope registra `record_side_effect` na chave avulsa;
2. em seguida **levanta uma exceção de "kill"** não-rescuable pelo mapa (usar um raise dentro do fake **após** a tool, e — para simular kill de verdade — escrever o estado manualmente: alternativa mais fiel é montar o estado direto nos stores: task `:running` com Execution aberta, checkpoint do turno corrente salvo, side-effect na chave avulsa, **sem** fiber vivo).

> Preferir a montagem direta de estado: `kill -9` não executa rescue nenhum — qualquer exceção simulada passaria pela captura única e marcaria `:failed`, que NÃO é o cenário. O estado pós-kill é exatamente: task `:running`, checkpoint válido do turno, side-effect registrado na chave avulsa, processo sem o fiber.

**Ato 2 — o reboot.** Wiring completo B (objetos novos, **mesmo arquivo** SQLite). `Recovery.run`:
- sumário `resumed:` inclui a task;
- o handler real valida running-órfã (`executor_B.running? == false`) e spawna;
- o `FakeChat` do wiring B roteiriza o modelo re-pedindo a mesma tool call (mesmo `tool_call_id` do registro) e depois respondendo final.

| Test Case | Description | Expected |
|-----------|-------------|----------|
| retomada completa | Atos 1+2 | task termina `:completed`; `:done` emitido no processo B |
| side-effect não reexecuta | espião na tool real | tool **não** executada; `:tool_result` carrega `{"skipped"=>"already_executed"}` |
| nova Execution | doc 02 §3 | `executions.size == 2`; attempt 1 preservado (nunca sobrescrito) |
| checkpoint avança | após conclusão | `latest.turn == turn_interrompido + 1`; `prune` manteve o último |
| sessão íntegra | transcript | mensagens do turno aparecem **uma vez** (o crash foi antes do estágio 8) |

### Edge Cases to Handle

1. Resume de task com fiber vivo → `ValidationError` "em execução" (nunca dois fibers para a mesma task — o guard do `spawn`, task 10, é a segunda linha de defesa).
2. Resume de task terminal (`completed`/`failed`/`cancelled`) → `ValidationError` com o status na mensagem.
3. Resume sem checkpoint → `ValidationError` "irrecuperável" (manual); via Recovery esse caso nem chega ao handler (vira `:failed` na varredura, doc 02 §4).
4. `task_id` inexistente → `NotFoundError`.
5. Agente do checkpoint removido da config → `NotFoundError` (falha alta; via Recovery, conta no `failed:` sem derrubar o boot).
6. Task `running` órfã: `begin_execution` abre attempt N+1 **sem** transição de status (running→running é inválido — doc 02 §2).
7. Side-effect registrado na chave avulsa mas turno nunca checkpointado de novo → `side_effects` (união) ainda o retorna; o skip funciona (doc 02 §2).
8. Re-run gera `tool_call_id` **diferente** do registrado → a call executa de novo (ver Notes — limitação conhecida da correlação por id).
9. Dois resumes concorrentes da mesma órfã no mesmo processo → o segundo vê `running?` true (o primeiro registrou no spawn) → `ValidationError`.

## Testing

### Unit Tests

**File:** `spec/harness/commands/resume_task_spec.rb` (stores reais sobre `Memory`; executor duplo com `running?`/`spawn`)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| paused retomável | task `:paused` + checkpoint | `spawn` chamado com `resume_from` = checkpoint mais recente; retorna `{task_id:}` |
| waiting retomável | task `:waiting` + checkpoint | idem |
| running órfã | `:running`, `running?` false | `spawn` chamado |
| running viva | `:running`, `running?` true | `ValidationError` "em execução"; `spawn` NÃO chamado |
| terminais | `:completed`/`:failed`/`:cancelled` | `ValidationError` |
| sem checkpoint | task `:paused` sem checkpoint | `ValidationError` "irrecuperável" |
| inexistente | task_id fantasma | `NotFoundError` |
| agente sumiu | checkpoint com `agent_id` fora de profiles | `NotFoundError` |
| latest correto | checkpoints turn 2 e 4 | `resume_from.turn == 4` |

**File:** `spec/harness/recovery_spec.rb` (MODIFY — bus real)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| dispatch real | task `:running` órfã + checkpoint; bus com handler registrado | handler executado (spawn no duplo); sumário `resumed:` |
| falha isolada | duas tasks, uma com agente removido | uma em `resumed:`, outra `:failed` com erro registrado; boot não derruba (doc 02 §6) |
| transport de origem | inspecionar o Command despachado | `meta.transport == :recovery` |

**File:** `spec/harness/executor_pipeline_spec.rb` (acrescentar casos de resume)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| turno reexecutado | `resume_from` turn 3 | pipeline roda com `state.turn == 3`; novo checkpoint `turn == 4` |
| histórico do checkpoint | FakeContextBuilder | `history` do contexto == `checkpoint.messages` (precedência doc 04) |
| skip por id | skip set com `call_abc`; fake dispara before com `id: "call_abc"` | tool não executa; resultado é o marcador |
| id fora do skip set | before com id novo | tool executa normalmente e re-registra (idempotente) |

### Integration Tests

**File:** `spec/harness/integration/kill_restart_resume_spec.rb` — ver Step 5 (tabela lá). Roda **sem `ruby_llm`** (FakeChat via seam `create_chat`); SQLite em `Dir.mktmpdir`.

## Definition of Done

- [ ] `ResumeTask` implementa a matriz de elegibilidade do doc 03 §3 (paused/waiting sempre; running só órfã via `running?`; terminais/sem-checkpoint → `ValidationError`; inexistente → `NotFoundError`)
- [ ] Retomada reexecuta o turno checkpointado inteiro, com nova Execution (attempt N+1, histórico preservado — doc 02 §3)
- [ ] Tool calls em `side_effects` (chave avulsa ∪ checkpoint) respondidas com `{"skipped":"already_executed"}`, nunca reexecutadas (doc 02 L5)
- [ ] `Recovery` despacha no `CommandBus` real; falha de uma task não derruba o boot (doc 02 §6)
- [ ] Teste kill-restart-resume verde: estado pós-crash → reboot → `:completed` com skip comprovado
- [ ] Um código só para crash-recovery e resume manual (D3) — nenhuma lógica de retomada dentro do `Recovery`
- [ ] Suíte roda **sem `ruby_llm` instalado** e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Correlação do skip por `tool_call_id`:** o registro grava o id que o provider gerou na tentativa interrompida; na reexecução o provider pode gerar ids **novos** — nesse caso a call não casa com o skip set e reexecuta. É o contrato como especificado (doc 02 §3/L5 correlaciona por id); mitigação por assinatura (nome+args) seria decisão nova — se o problema aparecer na prática, levar ao techspec antes de implementar. O teste de integração roteiriza o mesmo id de propósito.
- **`message` do turno retomado** vem de `task.command.payload.message` (o Command persistido na Task, doc 02 §3). Turnos > 1 só existirão quando `user_message` tiver produtor (Fase 2) ou em workflow multi-turno — não construa nada para isso agora.
- **Simulação de kill:** não use exceção para "matar" o processo no teste — ela passaria pela captura única (task 12) e marcaria `:failed`. O estado pós-`kill -9` se monta escrevendo direto nos stores (Step 5). O smoke E2E com processo real e `kill -9` de verdade é a task 26.
- `transport: :recovery` no meta do Command é sugestão de auditoria (o campo é `Symbol` livre no doc 03 §2, não enum) — se a task 8 usou `:internal`, qualquer um dos dois é aceitável; alinhe com o código real.
- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 27 novos (10 resume_task + 2 recovery real-bus + 2 pipeline resume + 1 kill-restart-resume + os ajustes), 343 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/commands/resume_task.rb`, `spec/harness/commands/resume_task_spec.rb`, `spec/harness/integration/kill_restart_resume_spec.rb`
- **Arquivos modificados:** `lib/harness/executor.rb` (resume path + skip), `lib/harness/tool_envelope.rb` (skip_side_effects), `lib/harness/recovery.rb` (Command.build), `lib/harness.rb`, `spec/harness/recovery_spec.rb` (real-bus), `spec/harness/executor_pipeline_spec.rb` (resume cases)
- **Observações / decisões tomadas:**
  - **Fecho da Execution órfã (decisão necessária, não prevista no sample):** um crash real deixa a Execution do attempt interrompido ABERTA; o `TaskStore` real proíbe abrir uma segunda com uma aberta. Então o resume fecha a órfã como `:interrupted` (`close_orphan_execution`) antes de `begin_execution` (attempt N+1). Preserva o histórico (doc 02 §3: nova entrada, nunca sobrescreve) — o attempt 1 fica registrado como interrompido. Edge case 6 do plano assumia `begin_execution` direto; conciliado com o TaskStore real.
  - **Transição no resume:** `queued`/`paused`/`waiting` → `:running`; órfã já `:running` → sem transição (running→running inválido, doc 02 §2).
  - **Skip de side-effects:** no resume, `skip = side_effects(task, turn: state.turn)` (avulsa ∪ checkpoint) passado ao `wrap_tools`; o `ToolEnvelope` responde `{"skipped"=>"already_executed"}` para ids já concluídos, sem reexecutar (doc 02 L5). Marcador volta ao modelo (protocolo íntegro).
  - **Recovery no bus real:** trocado `Command.new` por `Command.build(:resume_task, {task_id:}, transport: :recovery)` (factory da task 09). Um código só para crash-recovery e resume manual (D3) — o Recovery só descobre e despacha.
  - **Teste kill-restart-resume:** estado pós-crash montado direto em `Stores::SQLite` (arquivo temp), reboot com objetos novos no MESMO arquivo, verificação num TERCEIRO store reaberto (durabilidade real entre "processos"). Prova: `:completed`, tool NÃO reexecutada (calls==0 + marcador no `:tool_result`), 2 Executions (attempt 1 preservado), checkpoint turn 2, sessão com as mensagens uma vez.
  - **Limitação conhecida (doc):** correlação do skip por `tool_call_id` — se o provider gerar id novo no re-run, a call reexecuta. Contrato como especificado; mitigação por assinatura seria decisão nova.
