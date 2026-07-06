# Task 23: Handler `TriggerWorkflow` (workflow = 1 turno lógico, tools filtradas pela Resolution)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md) · [06-registries-plugin-autodiscovery.md](../06-registries-plugin-autodiscovery.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Implementar o quinto Command da Fase 1 (D3): handler `TriggerWorkflow` que valida o payload, cria a Task e reusa a pipeline canônica, com a variação do estágio 6 (doc 03 §4.1) — o Executor resolve o workflow no `WorkflowRegistry` e o invoca com `#call(input, context:, tools:)`, onde a execução inteira é **um turno lógico** com **um checkpoint ao final**.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 12 | Handler `SendMessage` end-to-end + checkpoint no estágio 8 + timeouts D4 | ⬜ TODO |
| 17 | `Policy::Engine` + builtins `Tool/Skill/WorkflowAllowlist` | ⬜ TODO |
| 20 | `Registry` genérico + Workflow/Policy Registries + `PromptCatalog` | ⬜ TODO |

(Grafo do tasks.md: `23 → 12, 17, 20`. Da 12 vêm a pipeline, o TaskActor, o estágio 8 e o mecanismo de side-effects; da 17 vem a `WorkflowAllowlist`; da 20 vem o `WorkflowRegistry`.)

## Context

Doc 03 §4.1 + doc 06 §2/§4. `TriggerWorkflow` é a prova de que a pipeline é única (doc 00 §5.2 — regra RFC-0002 §8: "estende estágio, não cria fluxo"): estágios 1-5 **idênticos** ao `SendMessage`; só o estágio 6 muda — em vez de `chat.ask`, invoca-se um workflow do Registry. O workflow é um callable Ruby (RFC-0001 §5) que orquestra RubyLLM Agents/Workflows **por dentro** — o Harness não dirige passos de LLM (RubyLLM First).

Dois contratos centrais:

1. **Tools filtradas pela Resolution** (doc 03 §4.1): `tools:` recebe as **instâncias** já permitidas pelo Policy Engine — o workflow nunca enxerga tool negada, exatamente como o modelo no `SendMessage`.
2. **Workflow = 1 turno lógico**: um checkpoint ao final (estágio 8); side-effects registrados ao longo (doc 02 §3); na retomada, o workflow **reexecuta do início** com os side-effects pulados (`{"skipped":"already_executed"}`, doc 02 L5). Checkpoint intermediário por passo é Fase 2.

Fecha a Etapa F e o conjunto D3 de cinco Commands.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/commands/trigger_workflow.rb` | Handler: validação síncrona + criação da Task + spawn do fiber |
| MODIFY | `lib/harness/executor.rb` | Variação do estágio 6 por `command.type`; kwarg `workflow_registry:` |
| MODIFY | `config/wiring.rb` | Registra o handler no bus; injeta `workflow_registry` no Executor |
| CREATE | `spec/harness/commands/trigger_workflow_spec.rb` | Validações do handler (síncronas, sem fiber) |
| CREATE | `spec/harness/trigger_workflow_flow_spec.rb` | Fluxo estágio 6 + checkpoint único + resume com side-effect (workflow fake PORO) |

### Step-by-Step Instructions

#### Step 1: Handler `Commands::TriggerWorkflow`

**File:** `lib/harness/commands/trigger_workflow.rb`

Um handler por arquivo (doc 03 §2), respondendo a `#call(command)`. Payload (doc 03 §3):

```ruby
# trigger_workflow
{ workflow: String,               # deve existir no Workflow Registry (doc 06)
                                  # E constar em profile.workflows_allow
                                  # (WorkflowAllowlist, doc 05 §2)
  agent: String, input: Hash, session_id: String | nil }
```

Validações **síncronas, antes do fiber** (doc 03 §6: `ValidationError`/`NotFoundError` acontecem antes do fiber → resposta HTTP direta, nenhuma Task criada):

1. `workflow` — String obrigatória, não-vazia → senão `ValidationError` com mensagem específica;
2. `agent` — String obrigatória; deve existir em `profiles` → senão `NotFoundError`;
3. `input` — Hash (default `{}`) → senão `ValidationError`;
4. `session_id` — opcional; se presente, a sessão deve existir no SessionStore → senão `NotFoundError` (mesma regra síncrona do `SendMessage`, doc 03 §3);
5. `workflow` deve existir no `WorkflowRegistry` → senão `NotFoundError` (a existência é validável sem executar; use `names.include?` — **não** chame `resolve` aqui para não instanciar fora do fiber). A **allowlist** (`profile.workflows_allow`) NÃO é checada no handler: é enforcement do estágio 3 via `WorkflowAllowlist` (doc 05 §2) → `PolicyDenied` → evento `:policy_denied` → task `:failed`.

Passando as validações: `task_store.create(command:, session_id:)` (status `:queued`), spawn do `TaskActor` (fiber Async) que chama `executor.execute(task, profile:)`, e retorno **imediato** de `{ task_id: }` (Command de turno — D3, RFC-0002 §7). Siga o esqueleto do handler `SendMessage` da task 12 — leia o código real ao implementar; a estrutura de spawn/retorno deve ser idêntica (idealmente extraída num helper comum aos dois handlers de turno).

**Reference pattern from codebase:** não há handler na Fase 0 (Command Bus é novo — o `runner.rb` era chamado direto pelo server). O padrão a seguir é o handler `SendMessage` da task 12 deste mesmo plano. Da Fase 0 vale o estilo de validação cedo-e-alto e as convenções (`# frozen_string_literal: true`, comentários em português, classes pequenas).

#### Step 2: Variação do estágio 6 no Executor

**File:** `lib/harness/executor.rb`

Estágios 1-5 e 8-9 **inalterados** (mesmo código do `SendMessage` — não duplique a pipeline; a variação é um branch no estágio 6 por `command.type`). Conforme doc 03 §4.1:

- **Injeção:** `Executor#initialize` ganha `workflow_registry:` (ver Notes — a assinatura do doc 03 §2 não o lista, mas o §4.1 exige).
- **Estágio 3 (Policy):** nada muda — o `PolicyRequest` já carrega `command:`, que é o que a `WorkflowAllowlist` (doc 05 §2) inspeciona para negar `trigger_workflow` fora de `profile.workflows_allow`. Garanta apenas que `profile.policies` do perfil em teste inclui a builtin.
- **Estágio 6:** quando `command.type == :trigger_workflow`:

```ruby
# Em vez de chat.ask: resolve o workflow e o invoca com o contexto do
# estágio 2 e as tools do estágio 3 (doc 03 §4.1). O workflow usa RubyLLM
# Agents/Workflows por dentro — o Harness não orquestra passos de LLM.
workflow = @workflow_registry.resolve(command.payload[:workflow])
result = @hooks.around(:agent, turn_state) do |state|
  workflow.call(command.payload[:input], context: state.context, tools: allowed_tool_instances)
end
```

  - `allowed_tool_instances`: as **mesmas** instâncias que o estágio 5-6 do `SendMessage` entregaria ao `chat.with_tools` — instanciadas via factory **só** para as permitidas em `resolution.allowed_tools` (doc 05 §4) e já envolvidas pelo mecanismo do estágio 7 da task 12 (hooks `around(:tool)`, timeout por tool, registro de side-effect via `checkpoint_store.record_side_effect` e skip na retomada). O workflow herda registro/skip de side-effects sem código próprio.
  - O wrapper `hooks.around(:agent, ...)` envolve a invocação, como envolve o `chat.ask` (doc 03 §4: before/after_agent = "cada chamada de agente (estágio 6)").
  - O retorno de `workflow.call` é o conteúdo final do turno: alimenta `:done { content }` e `:task_completed { task_id, content }` no estágio 9, espelhando o `chat.ask` (mesma pipeline, mesmos eventos).
- **Estágio 8 (checkpoint único):** código idêntico ao `SendMessage` — `checkpoint_store.save` (turno n+1, transação atômica), `session_store.append_messages` se houver `session_id`, `task_store.finish_execution` + `transition(:completed)`, evento `:checkpoint_created`. A execução inteira do workflow gera **exatamente um** checkpoint (semântica de turno do doc 03 §4.1); os side-effects registrados ao longo (chave avulsa, doc 02 §2-§3) são absorvidos em `completed_side_effects` pelo `save`.
- **Cancelamento/timeout:** nada específico — a mailbox é drenada nas fronteiras de estágio (doc 03 §4.1 CancelTask) e o `turn_timeout` (D4, 300s default) envolve os estágios 2-8 incluindo o `workflow.call`.

#### Step 3: Retomada (verificação, não código novo)

O `ResumeTask` (task 13) já é genérico: carrega `checkpoint_store.latest`, reconstrói o TurnState, abre nova Execution e reentra no estágio 2. Para uma task de `trigger_workflow`, isso significa: o estágio 6 re-resolve o workflow (o `command` está persistido na Task, doc 02 §3) e o **reexecuta do início**; tool calls em `side_effects` (chave avulsa ∪ checkpoint) são respondidas com `{"skipped":"already_executed"}` pelo wrapper de tool (doc 02 L5). Verifique que o branch do estágio 6 usa `task.command` (persistido) e não estado em memória — é isso que faz crash-recovery e resume manual serem o mesmo caminho (D3).

#### Step 4: Wiring

**File:** `config/wiring.rb`

- `bus.register(:trigger_workflow, Commands::TriggerWorkflow.new(...))` ao lado dos demais handlers (task 9/12);
- injetar o `workflow_registry` (criado no wiring pela task 21) no handler (para a validação de existência) e no Executor (para o estágio 6);
- garantir que o perfil default inclui `WorkflowAllowlist` em `policies` quando `workflows_allow` for usado (doc 05 §8: default de `policies` é `[ToolAllowlist, SkillAllowlist]` — a `WorkflowAllowlist` entra pelos perfis que declaram workflows).

### Edge Cases to Handle

1. **Workflow inexistente no Registry** → `NotFoundError` síncrono no handler (nenhuma Task criada). Se sumir entre a validação e o estágio 6 (impossível na Fase 1 — registries imutáveis pós-boot, doc 06 L6), o `resolve` levanta `NotFoundError` dentro do fiber → captura única do topo (doc 03 L3) → task `:failed`.
2. **Workflow fora de `profile.workflows_allow`** → `PolicyDenied` no estágio 3 → evento `:policy_denied { policy, reason }` → task `:failed` (D4: não é retry-ável). Semântica de allowlist nil/[]/[names] idêntica à de tools (D6).
3. **Exceção dentro de `workflow.call`** → escapa do estágio 6 e cai na captura única do topo do fiber (doc 03 §6/L3) → task `:failed`, `:task_failed` + `:error` (compat), checkpoint anterior preservado. Diferente de tool: erro de tool dentro do workflow segue a semântica RubyLLM (volta ao modelo) se o workflow usa o loop RubyLLM; erro do próprio workflow é falha do turno.
4. **`session_id` XOR nada** — `trigger_workflow` não tem `history` (só `SendMessage`, D2); payload com chave extra desconhecida → `ValidationError` (validação estrita, doc 03 §7).
5. **Cancelamento durante o workflow** → `:cancel` postado na mailbox só é visto nas fronteiras de estágio (doc 03 L2): um workflow longo não é interrompido no meio do estágio 6 na Fase 1 — comportamento esperado, não bug (cancelamento cooperativo, princípio 7).
6. **Timeout de turno** → `workflow.call` mais longo que `profile.limits.turn_timeout` → `TimeoutError(stage: :turn)`, task `:failed`, checkpoint anterior intacto (D4).
7. **Resume sem checkpoint** → já tratado pelo `ResumeTask`/`Recovery` (task 13, doc 02 §4) — nada específico aqui.
8. **Side-effect registrado e crash antes do estágio 8** → a chave avulsa `sideeffects:<task>:turn:<n>` sobrevive (doc 02 §3); na retomada `side_effects` a une ao checkpoint e o wrapper pula a tool.

## Testing

Workflow fake = **PORO callable** (lambda ou classe com `#call(input, context:, tools:)`) — zero RubyLLM (doc 06 §7); colaboradores do Executor são os duplos/fakes já usados na suíte da task 12.

### Unit Tests

**File:** `spec/harness/commands/trigger_workflow_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| workflow ausente/vazio | payload sem `workflow` | `ValidationError`, nenhuma Task criada |
| agent inexistente | `agent: "nope"` | `NotFoundError`, nenhuma Task |
| input não-Hash | `input: "x"` | `ValidationError` |
| session inexistente | `session_id` sem sessão | `NotFoundError` síncrono |
| workflow fora do Registry | nome não registrado | `NotFoundError`, nenhuma Task |
| payload válido | tudo ok | retorna `{ task_id: }` imediato; Task criada `:queued` com `command` persistido |
| chave desconhecida | payload com campo extra | `ValidationError` |

### Integration Tests (if applicable)

**File:** `spec/harness/trigger_workflow_flow_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| estágio 6 — contrato do callable | workflow fake espião registrado no WorkflowRegistry | recebe `input` do payload, `context:` = ContextPackage do Builder, `tools:` = instâncias |
| tools filtradas pela Resolution | registry com 2 tools; policy permite 1 | `tools:` contém SÓ a permitida — a negada nunca chega ao workflow |
| WorkflowAllowlist | `workflows_allow: []` no perfil | `:policy_denied` emitido; task `:failed`; workflow nunca invocado |
| checkpoint único ao final | workflow fake com 3 "passos" internos | exatamente 1 `:checkpoint_created`; 1 checkpoint no store; `:done`/`:task_completed` com o retorno do workflow |
| eventos da pipeline | fluxo feliz | `:task_started` → … → `:checkpoint_created` → `:done`/`:task_completed`, `seq` monotônico |
| side-effect + resume | workflow fake chama tool fake `side_effect: true` (grava num spy + `record_side_effect`), depois levanta na 1ª execução; task fica interrompida; despacha `ResumeTask` | 2ª execução: workflow reexecuta do início; a tool devolve `{"skipped":"already_executed"}` e o spy NÃO recebe 2ª escrita; execução completa; checkpoint salvo; Executions com 2 attempts |
| exceção do workflow | fake que levanta | task `:failed`, `:task_failed` + `:error`, checkpoint anterior intacto |

## Definition of Done

- [ ] Handler `TriggerWorkflow` com o payload/validações do doc 03 §3 (síncronas, antes do fiber)
- [ ] Estágio 6 variante conforme doc 03 §4.1: `resolve` no WorkflowRegistry + `#call(input, context:, tools:)` com instâncias filtradas pela Resolution, envolto em `hooks.around(:agent)`
- [ ] Estágios 1-5 e 8-9 reusados sem duplicação (uma única pipeline — doc 00 §5.2)
- [ ] Workflow = 1 turno lógico: exatamente um checkpoint ao final; side-effects registrados ao longo e pulados na retomada — verificado por teste
- [ ] `WorkflowAllowlist` efetiva no estágio 3 (deny → `:policy_denied`, task `:failed`)
- [ ] Handler registrado no bus via `config/wiring.rb`
- [ ] Todos os testes passando; **suíte roda sem `ruby_llm` instalado e sem API key** (workflow e tools fake são POROs)
- [ ] Sem erros de lint
- [ ] Código revisado

## Notes

- **Aviso de drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui. Em especial: o formato exato do wrapper de tool/side-effect e do spawn de fiber vem da task 12/13 — siga o código real, não o resumo daqui.
- **`workflow_registry:` no Executor:** a assinatura do doc 03 §2 não lista o kwarg, mas o §4.1 exige que o Executor resolva o workflow no Registry. Extensão de assinatura inevitável — registrada aqui como lacuna do techspec.
- **Shape das mensagens do turno de workflow:** o doc não define que `messages` um turno de workflow persiste no checkpoint/sessão (no `SendMessage` é o transcript do chat). Siga o que o estágio 8 da task 12 faz com o TurnState; se precisar decidir um shape (ex.: `user` = input serializado, `assistant` = retorno), registre a decisão no PR — não é arquitetural, mas é contrato de dados.
- **Eventos de tool dentro do workflow:** se o workflow chama as instâncias decoradas de `tools:`, os eventos `:tool_call`/`:tool_result` e o registro de side-effects saem de graça (wrapper do estágio 7). Se o workflow criar chats RubyLLM próprios com tools próprias, o Harness não enxerga essas calls na Fase 1 — limitação conhecida, coerente com "checkpoint intermediário por passo é Fase 2" (doc 03 §4.1).
- `user_message` na mailbox (multi-turno de workflow) é reservado na Fase 1 (doc 03 §2) — nenhum produtor; não implemente consumo especial aqui.
