# Task 18: `MiddlewareStack` rack-like (`TurnState` mutável, `halt_reason`)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [05-policy-middleware-hooks.md](../05-policy-middleware-hooks.md)
> **Status:** ✅ DONE
> **Complexity:** Low

---

## Objective

Implementar o estágio 4 da pipeline: a classe base `Harness::Middleware` (elo pass-through) e a `MiddlewareStack` com composição rack-like — ordem de registro = ordem de execução, curto-circuito via `state.halt_reason` (task `:failed`, sem tocar RubyLLM) e `TurnState` mutável atravessando a cadeia.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 10 | `Executor` esqueleto: fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream` | ⬜ TODO |

## Context

Doc 05 §1 fixa a fronteira do princípio 9 (doc 00 §5.9): **Middleware modifica o TurnState, curto-circuita e tem efeito operacional (rate limit, tracing, custo); NÃO decide permissão de tool/skill — isso é Policy** (L5: "sem isso Policy e Middleware colapsam num estágio só e a auditoria perde sentido").

O estágio 4 roda depois de Context (2) e Policy (3) — "autorização antes de efeitos operacionais" (RFC-0002 §5, doc 05 §4) — e **envolve os estágios 5-9**:

```
estágio 4:
  middleware_stack.call(turn_state) { |state| ...estágios 5-9... }
    └─ halt → task :failed(halt_reason), sem tocar RubyLLM
```

O `TurnState` é a **única exceção aos `Data`** deste techspec: classe mutável de propósito (doc 03 §3, L5 do doc 03), porque os elos escrevem nos campos (`message`, `context`, `halt_reason`…). Ele é criado pelo Executor (task 10); esta task só o atravessa.

Esta task entrega o mecanismo + a integração no Executor. Middlewares concretos (rate limit, tracing) não fazem parte da Fase 1 — chegam por plugin (task 21 registra; doc 06).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/middleware.rb` | `Harness::Middleware` (elo base) + `Harness::MiddlewareStack` (layout doc 00 §3: `lib/harness/{middleware,hooks}.rb`) |
| MODIFY | `lib/harness/executor.rb` | estágio 4: envolver os estágios 5-9 com `middleware.call(turn_state)`; tratar halt |
| CREATE | `spec/harness/middleware_spec.rb` | ordem, curto-circuito, mutação de state, exceção |
| MODIFY | `spec/harness/executor_spec.rb` (ou o spec criado pela task 10/12) | halt → task `:failed` com `halt_reason`, estágios 5-9 não executam |

### Step-by-Step Instructions

#### Step 1: `Harness::Middleware` — o elo base

**File:** `lib/harness/middleware.rb`

Interface exata do doc 05 §2:

```ruby
# frozen_string_literal: true

module Harness
  # Elo da cadeia (estágio 4). Middleware MODIFICA o TurnState, curto-circuita
  # e tem efeito operacional — NÃO decide permissão de tool/skill (isso é
  # Policy — doc 05 L5). Curto-circuito = não chamar nxt; quem curto-circuita
  # DEVE setar state.halt_reason.
  class Middleware
    def call(state, &nxt)
      nxt.call(state)                 # elo default: pass-through
    end
  end
end
```

Documente no comentário o contrato de concorrência (doc 05 §5): o middleware roda **no fiber da task**; um elo que faça IO (ex.: tracing exporter) deve fazê-lo async fora do caminho (`Async { ... }` fire-and-forget) ou aceitar a latência no turno.

#### Step 2: `MiddlewareStack` — composição rack-like

**File:** `lib/harness/middleware.rb` (mesma unidade)

```ruby
class MiddlewareStack
  def initialize(middlewares = [])  # ordem de registro = ordem de execução
  def call(state, &terminal)        # composição rack-like
end
```

Implementação da composição (o padrão rack clássico — o primeiro registrado é o elo mais externo):

```ruby
def call(state, &terminal)
  chain = @middlewares.reverse.reduce(terminal) do |nxt, mw|
    proc { |s| mw.call(s, &nxt) }
  end
  chain.call(state)
end
```

Regras (doc 05 §2-§3):

- **Ordem de registro = ordem de execução**: `[a, b]` executa `a` por fora, `b` por dentro, `terminal` no centro. Código pós-`nxt.call` de cada elo roda na volta, em ordem inversa (é o que permite tracing/custo medirem o turno inteiro).
- **Curto-circuito** = o elo simplesmente **não chama `nxt`** e **seta `state.halt_reason`** (campo do `TurnState` mutável — doc 03 §3). A stack não tem mecanismo especial de halt: a semântica é estrutural.
- **Stack não faz rescue**: exceção em middleware propaga (D4, linha Middleware: "propaga como falha do turno; task `:failed`"; sem retry — doc 05 §6).
- Stack vazia → `terminal.call(state)` direto.

**Reference pattern from codebase** (o `TurnState` que atravessa a cadeia — doc 03 §3, criado pela task 10):
```ruby
# MUTÁVEL de propósito (única exceção aos Data deste techspec): Middleware
# MODIFICA a execução (princípio 9) — os elos escrevem nestes campos.
class TurnState
  attr_reader   :task, :profile, :turn         # identidade do turno (1-based)
  attr_accessor :message,                      # entrada (Middleware pode reescrever)
                :context,                      # ContextPackage do Builder (doc 04)
                :allowed_tools, :allowed_skills, # Resolution do Policy Engine (doc 05)
                :chat,                         # instância RubyLLM::Chat do turno
                :halt_reason                   # setado por Middleware ao curto-circuitar
end
```

#### Step 3: Integração no Executor — estágio 4 envolvendo 5-9

**File:** `lib/harness/executor.rb`

No ponto do fluxo onde a task 10/12 deixou o estágio 4 (entre a Resolution do estágio 3 e a montagem do chat no estágio 5), envolva os estágios 5-9 na stack:

```ruby
# Estágio 4 (doc 05 §4): a cadeia envolve os estágios 5-9.
@middleware.call(turn_state) do |state|
  run_stages_5_to_9(state)   # nome ilustrativo — use a estrutura real do Executor
end
raise Harness::Error, turn_state.halt_reason if turn_state.halt_reason
```

Tratamento do halt (doc 05 §3: "task `:failed` com o motivo (ex.: rate limit), evento `:error`"):

- Ao retornar da stack com `halt_reason` preenchido, sinalize a falha pelo **mesmo caminho da captura única no topo do fiber** (doc 03 §6, L3) — levante `Harness::Error` com a mensagem do `halt_reason`. A captura única transiciona a task para `:failed`, fecha a Execution e emite `:task_failed` + `:error` (compat) — não duplique essa lógica no estágio 4.
- **Sem tocar RubyLLM**: o halt acontece antes do estágio 5-6; nenhum chat é montado, nenhum `chat.ask` ocorre.
- O construtor da stack chega pelo `initialize` do Executor (`middleware:` — doc 03 §2); o wiring monta `MiddlewareStack.new([])` na Fase 1 (vazia até plugins registrarem, task 21).

### Edge Cases to Handle

1. **Stack vazia** (caso normal da Fase 1): `terminal` executa direto; nenhuma alocação extra por turno além do proc.
2. **Curto-circuito no primeiro elo**: nenhum elo seguinte roda, terminal não roda, estágios 5-9 intocados (verificar com spy).
3. **Mutação atravessa**: elo A reescreve `state.message`; elo B e o terminal veem o valor novo (é o contrato — TurnState mutável, doc 03 L5).
4. **Elo que não chama `nxt` e não seta `halt_reason`** (violação de contrato): o Executor não consegue distinguir de um turno ok — trate como falha com motivo genérico: se o terminal não executou (flag local no bloco) e `halt_reason` é nil, levante `Harness::Error, "middleware curto-circuitou sem halt_reason"`. Comportamento fail-closed coerente com D4; ver Notes.
5. **Exceção em middleware**: propaga intacta pela stack (sem rescue) até a captura única do fiber → task `:failed` (D4). Não confundir com halt.
6. **Middleware que seta `halt_reason` E chama `nxt`**: contrato violado; o Executor prioriza o `halt_reason` ao retornar (turno falha) — documentar no comentário da classe.
7. **Sem timeout próprio**: middleware é coberto pelo timeout do turno (doc 05 §6); não adicione `with_timeout` aqui.

## Testing

### Unit Tests

**File:** `spec/harness/middleware_spec.rb` (doc 05 §7 — tudo puro, zero RubyLLM, zero IO; `TurnState` pode ser um duplo mínimo com `attr_accessor :message, :halt_reason` se a task 10 ainda não existir)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| ordem de execução | elos A e B logam entrada/saída num array | `[A:in, B:in, terminal, B:out, A:out]` |
| pass-through default | `Middleware.new` na cadeia | terminal executa; state inalterado |
| curto-circuito não chama estágios seguintes | elo B não chama `nxt`, seta `halt_reason` | terminal spy NUNCA chamado; elos após B não rodam; `state.halt_reason` preenchido |
| modificação visível ao próximo elo | A escreve `state.message = "x"` | B e terminal leem `"x"` |
| stack vazia | `MiddlewareStack.new([])` | terminal executa com o mesmo state |
| exceção propaga | elo levanta `RuntimeError` | exceção escapa de `#call` (stack não faz rescue) |
| valor de retorno | terminal devolve um valor | `stack.call` devolve esse valor |

### Integration Tests

**File:** `spec/harness/executor_spec.rb` (estender o spec da task 10/12 — colaboradores como duplos, doc 03 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| halt → task :failed | elo que curto-circuita com `halt_reason: "rate limit"` | task `:failed`; Execution fechada com a mensagem; eventos `:task_failed` + `:error`; estágio 5-6 (duplo de chat) nunca tocado |
| halt sem motivo | elo que não chama `nxt` nem seta reason | task `:failed` com motivo genérico (edge case 4) |
| exceção em elo | elo levanta | task `:failed` via captura única (D4) |
| ordem constitucional | spies de builder/engine/stack | Context (2) → Policy (3) → Middleware (4) — RFC-0002 §5 |

## Definition of Done

- [ ] `Harness::Middleware#call(state, &nxt)` pass-through e `MiddlewareStack#call(state, &terminal)` rack-like conforme doc 05 §2
- [ ] Ordem de registro = ordem de execução; curto-circuito = não chamar `nxt` + `state.halt_reason`
- [ ] Executor: estágio 4 envolve 5-9; halt → task `:failed` com o motivo via captura única (doc 03 L3), evento `:error`, sem tocar RubyLLM
- [ ] Stack não decide permissão nem faz rescue (L5, D4)
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- O doc 05 não fixa **como** o Executor sinaliza o halt internamente; a escolha aqui (levantar `Harness::Error` base com a mensagem do `halt_reason` para reusar a captura única do doc 03 L3) evita uma subclasse nova fora da taxonomia D4. Se o revisor preferir uma subclasse dedicada (ex.: `MiddlewareHalt`), é mudança em `errors.rb` (task 1) — registrar a decisão lá.
- O edge case 4 (curto-circuito sem `halt_reason`) é violação de contrato não coberta pelo doc; o comportamento fail-closed com motivo genérico é interpretação local coerente com D4 — documentado no comentário da classe.
- Nenhum middleware concreto nesta task: rate limit/tracing/custo são exemplos do doc 05 §1, não escopo da Fase 1; plugins registram elos via task 21 (doc 06). A stack da Fase 1 sobe vazia no wiring.
- Fase 0 não tem análogo de middleware — não há teste de caracterização; o padrão de referência é o contrato do doc 05 §2 e o `TurnState` do doc 03 §3.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 10 novos (8 middleware unit + 3 integração no Executor — halt real, edge case 4, stack vazia), 452 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/middleware.rb`, `spec/harness/middleware_spec.rb`
- **Arquivos modificados:** `lib/harness/executor.rb` (estágio 4 endurecido), `lib/harness.rb` (require), `spec/harness/executor_pipeline_spec.rb` (integração com MiddlewareStack real)
- **Observações / decisões tomadas:**
  - `MiddlewareStack#call` é rack clássico (reduce reverso sobre o terminal); ordem de registro = ordem de execução; curto-circuito **estrutural** (o elo não chama `nxt`). Sem rescue (exceção propaga como falha do turno, D4). Compatível com a chamada que a task 12 já fazia (`@middleware.call(state) { ... }`) — a stack vazia do wiring (task 26) é drop-in.
  - **Endurecimento do estágio 4 (edge case 4):** flag `terminal_ran` — se um elo curto-circuita SEM setar `halt_reason` (violação de contrato), o Executor levanta `Harness::Error` genérico ("middleware curto-circuitou sem halt_reason") em vez de deixar o turno pendurado. Fail-closed coerente com D4.
  - **Sinalização do halt:** reusa a captura única do topo do fiber (doc 03 L3) levantando `Harness::Error` base — sem subclasse nova na taxonomia D4 (decisão registrada; se preferir `MiddlewareHalt`, é mudança na task 1).
  - Nenhum middleware concreto (rate limit/tracing chegam por plugin, task 21); a stack sobe vazia no wiring.
