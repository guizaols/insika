# Task 19: Pares de hook restantes (`before/after_task`, `_agent`, `_tool`) integrados ao Executor

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [05-policy-middleware-hooks.md](../05-policy-middleware-hooks.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Integrar ao Executor os três pares de hook restantes da RFC-0002 §6 — `before/after_task` envolvendo os estágios 1→9, `before/after_agent` envolvendo cada chamada de agente (estágio 6) e `before/after_tool` envolvendo cada tool (estágio 7) — respeitando a regra L6: `after_X` com falha não reexecuta o estágio.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 10 | `Executor` esqueleto: fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream` | ⬜ TODO |
| 16 | Classe `Hooks` (mecanismo around) + par `before/after_prompt` envolvendo o Builder | ⬜ TODO |

## Context

Doc 05 §1 fixa a fronteira (doc 00 §5.9): **Hook altera entrada/saída de UM estágio que envolve; não cria fluxo próprio nem pula estágios**. A task 16 entregou o mecanismo (`Hooks` com `PAIRS = %i[task prompt agent tool]`, `register`, `around` — doc 05 §2) e ligou o par `:prompt` no estágio 2. Esta task liga os três pares restantes, conforme o mapa do doc 03 §4:

> Wrappers de hook (RFC-0002 §6 — correção 1): `before/after_task` envolvem 1→9; `before/after_prompt` o estágio 2; `before/after_agent` cada chamada de agente (estágio 6); `before/after_tool` cada tool (estágio 7).

Semântica do mecanismo (doc 05 §2): befores na **ordem de registro** (podem ALTERAR o subject retornando o novo), `yield(subject)`, afters na **ordem INVERSA** (podem alterar o resultado). Hooks são **síncronos por definição** — hook lento atrasa o estágio e é coberto pelo timeout do turno, D4 (doc 05 §5). Erros (doc 05 §6): exceção em `before_X` → falha do estágio envolvido (propaga conforme o estágio); em `after_X` → idem, **mas o estágio já executou — o turno falha SEM reexecutar o estágio** (L6: side-effects já ocorreram; reexecutar violaria a idempotência que o checkpoint assume, doc 02).

Particularidade do par `:tool`: o loop de tool-use é **interno ao RubyLLM** (doc 03 §6 — o Executor nunca dirige roundtrips; RubyLLM First). O ponto de integração são os callbacks `before_tool_call`/`after_tool_result` migrados do `runner.rb` (task 11, doc 03 §4.2) — duas metades separadas, não um bloco envolvível. Ver Step 3.

Esta task também posiciona o guard-rail `max_tool_calls` no lugar definitivo: "contador no hook `before_tool`" (doc 03 §6, L6 do doc 03).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| MODIFY | `lib/harness/hooks.rb` | expor as metades `run_before`/`run_after` (o `around` passa a ser composto delas) para o par `:tool` |
| MODIFY | `lib/harness/executor.rb` | ligar `:task` (topo do fiber), `:agent` (estágio 6), `:tool` (callbacks do estágio 7); contador `max_tool_calls` como hook `before_tool` |
| MODIFY | `spec/harness/hooks_spec.rb` | metades `run_before`/`run_after`; equivalência com `around` |
| MODIFY | `spec/harness/executor_spec.rb` (ou spec dedicado `spec/harness/executor_hooks_spec.rb`) | wrappers na ordem correta; L6; tool_limit |

### Step-by-Step Instructions

#### Step 1: Decompor o `around` em metades reutilizáveis

**File:** `lib/harness/hooks.rb`

O `around(pair, subject, &blk)` da task 16 implementa: befores em ordem → yield → afters em ordem inversa. Refatore-o sobre duas metades públicas (sem mudar o comportamento — os testes da task 16 continuam verdes):

```ruby
# Metades do around. Necessárias para o par :tool, cujo "corpo" do estágio
# é o loop interno do RubyLLM (doc 03 §6) — não há bloco a envolver; as
# metades são chamadas dos callbacks before_tool_call/after_tool_result.
def run_before(pair, subject)
  befores(pair).reduce(subject) { |subj, hook| hook.call(subj) || subj }
end

def run_after(pair, result)
  afters(pair).reverse.reduce(result) { |res, hook| hook.call(res) || res }
end

def around(pair, subject)
  run_after(pair, yield(run_before(pair, subject)))
end
```

(Adapte à estrutura interna real da task 16 — o contrato observável do doc 05 §2 é o que vale: múltiplos callables por par; before altera subject retornando o novo; after altera o resultado; ordem registro/inversa. O `|| subj` protege contra hook que retorna `nil` sem intenção de alterar — se a task 16 já definiu outra convenção de "não alterar", siga a dela.)

Sem hooks registrados num par, `run_before`/`run_after` devolvem o argumento intacto — custo próximo de zero no caminho comum.

#### Step 2: `before/after_task` — envolvendo 1→9

**File:** `lib/harness/executor.rb`

No topo do corpo do fiber (dentro de `execute`), envolva **toda** a execução do turno — da transição `:running`/`:task_started` (parte do estágio 1 que roda no fiber, doc 03 §4) até a Response (estágio 9) — em `hooks.around(:task, ...)`:

```ruby
# Captura única no topo do fiber (doc 03 L3) fica POR FORA — é ela que
# mapeia exceção de hook para estado terminal (:failed) e eventos.
begin
  @hooks.around(:task, turn_state) do |state|
    run_stages_1_to_9(state)   # estrutura real da task 10/12
  end
rescue => e
  handle_terminal_failure(e)   # captura única existente — não duplicar
end
```

- **Subject**: o `TurnState` do turno (mutável, doc 03 §3) — `before_task` pode reescrever `state.message` antes de qualquer estágio; **resultado**: o valor final do turno (o content da Response). O doc não fixa o tipo do subject; ver Notes.
- A ordem relativa aos demais wrappers fica: `before_task` → (estágios 2-5 com `:prompt` no 2) → `before_agent` → estágio 6 → `after_agent` → … → `after_task` (before na ida, after na volta — doc 03 §7).
- Exceção em `before_task` → nenhum estágio roda; captura única → `:failed`. Exceção em `after_task` → estágios 1-9 JÁ rodaram (checkpoint inclusive); o turno falha sem reexecução (L6) — o checkpoint criado no estágio 8 permanece válido (D4: "checkpoint nunca é corrompido").

#### Step 3: `before/after_agent` — estágio 6

**File:** `lib/harness/executor.rb`

Envolva **cada** chamada de agente (doc 03 §4, estágio 6):

```ruby
response = @hooks.around(:agent, message) do |msg|
  chat.ask(msg) { |chunk| emit_content(chunk) }   # única interação com o modelo
end
```

- **Subject**: a mensagem que vai ao `chat.ask` (após Middleware, que pode tê-la reescrito no estágio 4) — `before_agent` pode alterá-la retornando a nova; **resultado**: a response do RubyLLM — `after_agent` pode substituí-la (o que ele devolver segue para persistência/Response).
- "Cada chamada de agente": se o turno tiver múltiplas interações (multi-turno de workflow, `user_message` futuro), cada `chat.ask` ganha seu próprio par. Na Fase 1 do caminho `SendMessage` é 1 por turno (1 turno = 1 `chat.ask` completo — doc 03 §6).
- Exceção em `after_agent` → o `chat.ask` NÃO reexecuta (L6) — o modelo já respondeu e tools já rodaram; turno falha via captura única.

#### Step 4: `before/after_tool` — estágio 7, via callbacks RubyLLM

**File:** `lib/harness/executor.rb`

O estágio 7 acontece **dentro do loop RubyLLM** (doc 03 §4); o ponto de integração são os callbacks migrados do `runner.rb` (task 11). Insira as metades do par `:tool` neles, antes da emissão dos eventos:

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/runner.rb` — o `wire_callbacks` que a task 11 migrou intacto):
```ruby
# Callbacks aditivos (v1.15+). load_skill vira :skill_activated.
def wire_callbacks(chat, emit)
  chat.before_tool_call do |tool_call|
    if tool_call.name.to_s == "load_skill"
      args = tool_call.arguments || {}
      emit.call(Event.new(:skill_activated, { name: args["name"] || args[:name] }))
    else
      emit.call(Event.new(:tool_call, { name: tool_call.name, arguments: tool_call.arguments }))
    end
  end

  chat.after_tool_result do |result|
    emit.call(Event.new(:tool_result, { result: result.to_s }))
  end
end
```

Evolução (mantendo a lógica de eventos intacta — RubyLLM First):

```ruby
chat.before_tool_call do |tool_call|
  tool_call = @hooks.run_before(:tool, tool_call)
  # ...emissão de :skill_activated / :tool_call existente (com meta, D5)...
end

chat.after_tool_result do |result|
  result = @hooks.run_after(:tool, result)
  # ...emissão de :tool_result existente...
end
```

**Limitação documentada** (comentar no código): os callbacks do RubyLLM são **aditivos** — o subject alterado pelo `before_tool` alimenta os hooks seguintes e os eventos emitidos, mas **não reescreve a call que o RubyLLM executa**. Alterar argumentos de tool de verdade exigiria dirigir o loop, o que violaria RubyLLM First (doc 03 §6). Uma exceção levantada por um hook `before_tool`, por outro lado, escapa do callback e aborta o turno — é exatamente o mecanismo do guard-rail do Step 5.

#### Step 5: Guard-rail `max_tool_calls` como hook `before_tool`

**File:** `lib/harness/executor.rb`

Doc 03 §6: "contador no hook `before_tool`; ao exceder `profile.limits.max_tool_calls` (default 50), o hook levanta → o turno falha com `TimeoutError(stage: :tool_limit)`. Nenhum loop é reimplementado — o hook só conta e aborta."

Registre, por turno (contador zerado a cada turno), um hook `before_tool` de sistema:

```ruby
count = 0
@hooks.register(:tool, before: lambda { |tool_call|
  count += 1
  raise TimeoutError.new(stage: :tool_limit) if count > max_tool_calls
  tool_call
})
```

- `max_tool_calls` vem de `profile.limits` (D6, default 50).
- Se a task 11 tiver implementado o contador direto no callback `before_tool_call` (os hooks ainda não existiam na Etapa C), **mova-o** para este hook — um mecanismo só (drift: confira o código real).
- Atenção ao ciclo de vida: o registro é por turno/execução — garanta que hooks de sistema não se acumulem entre turnos da mesma task (registre numa instância de `Hooks` do turno ou remova ao final, conforme a estrutura que a task 16 deu ao objeto; o wiring injeta os hooks "globais" e o Executor adiciona os de sistema).

### Edge Cases to Handle

1. **`after_X` com falha não reexecuta o estágio (L6)**: vale para os três pares; verificar com spy de contagem (doc 05 §7) — `chat.ask` chamado exatamente 1 vez mesmo com `after_agent` levantando.
2. **Exceção em `before_task`**: nenhum estágio roda (nem Context); task `:failed` via captura única; nenhum checkpoint novo.
3. **Exceção em `after_task` após o estágio 8**: checkpoint do turno JÁ existe e permanece válido; task `:failed`; `ResumeTask` retoma do checkpoint (D4).
4. **Múltiplos hooks no mesmo par**: befores na ordem de registro, afters na inversa (doc 05 §2) — a alteração de subject de um before alimenta o próximo.
5. **Hook que retorna `nil`**: seguir a convenção de "não alterar" definida na task 16 (aqui sugerido `|| subject`); não deixar `nil` vazar para `chat.ask`.
6. **Erro DENTRO da tool** não passa pelos hooks como exceção: RubyLLM devolve o erro ao modelo (D4, linha Tool Execution; doc 03 §6) — `after_tool` recebe o resultado de erro como valor. Só exceção de **hook** aborta o turno.
7. **`:cancel` na mailbox**: o drain nas fronteiras de estágio (doc 03 §4.1) continua funcionando por fora dos wrappers de estágio — `CancelledError` atravessa os afters sem ser engolida (hooks não fazem rescue).
8. **Hook lento**: sem timeout próprio — coberto pelo timeout do turno (doc 05 §5/§6); não adicionar `with_timeout` por hook.
9. **`load_skill`**: continua sendo tool de sistema adicionada após a decisão de policy (doc 03 §4.2); passa pelos hooks `:tool` como qualquer tool (o evento diferenciado `:skill_activated` é lógica de emissão, não de hook).

## Testing

### Unit Tests

**File:** `spec/harness/hooks_spec.rb` (estende os da task 16 — tudo puro, zero RubyLLM/IO, doc 05 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| run_before ordem de registro | dois befores que anexam marcador ao subject | marcadores na ordem de registro |
| run_after ordem inversa | dois afters que anexam marcador | ordem inversa à de registro |
| around ≡ metades | mesmo par via `around` e via `run_before`+bloco+`run_after` | resultados idênticos |
| par sem hooks | `run_before`/`run_after` sem registro | devolve o argumento intacto |
| exceção em after não reexecuta | bloco com spy de contagem; after levanta | bloco executado exatamente 1 vez; exceção propaga (L6) |

### Integration Tests

**File:** `spec/harness/executor_spec.rb` (ou `spec/harness/executor_hooks_spec.rb`) — colaboradores como duplos (builder/engine/middleware/stores/chat — doc 03 §7); RubyLLM **não** é requerido: o duplo de chat só precisa aceitar `ask`/`before_tool_call`/`after_tool_result`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| ordem dos wrappers | spies em before/after de :task/:prompt/:agent | before na ida (`task`→`prompt`→`agent`), after na volta (`agent`→`prompt`→`task`) — doc 03 §7 |
| before_task altera entrada | before_task reescreve `state.message` | builder/chat duplos recebem a mensagem alterada |
| after_agent altera resultado | after_agent substitui a response | valor substituído chega à persistência/`:done` |
| before_agent altera mensagem | before_agent devolve msg nova | `chat.ask` (duplo) recebe a nova |
| before_tool/after_tool nos callbacks | duplo de chat dispara os callbacks registrados | hooks `:tool` executam; eventos `:tool_call`/`:tool_result` preservados (paridade Fase 0 + meta D5) |
| L6 no estágio 6 | after_agent levanta; spy conta `chat.ask` | `ask` chamado 1 vez; task `:failed`; eventos `:task_failed` + `:error` |
| before_task levanta | before_task com raise | task `:failed`; builder nunca chamado; nenhum checkpoint |
| after_task levanta pós-checkpoint | duplos completam estágio 8; after_task levanta | checkpoint existe; task `:failed` |
| tool_limit | duplo dispara `before_tool_call` 51× com `max_tool_calls: 50` | `TimeoutError` com `stage: :tool_limit`; task `:failed` (doc 03 §6) |
| contador zera por turno | dois turnos de 30 calls com limite 50 | nenhum estouro |

## Definition of Done

- [ ] Os quatro pares da RFC-0002 §6 ligados: `:prompt` (task 16) + `:task` (1→9), `:agent` (estágio 6), `:tool` (estágio 7) desta task
- [ ] Befores na ordem de registro alterando subject; afters na ordem inversa alterando resultado (doc 05 §2)
- [ ] L6 verificado por spy: falha em `after_X` não reexecuta o estágio (doc 05 §7)
- [ ] Par `:tool` integrado aos callbacks RubyLLM sem reimplementar o loop (RubyLLM First); limitação de alteração de subject documentada no código
- [ ] `max_tool_calls` como hook `before_tool` levantando `TimeoutError(stage: :tool_limit)` (doc 03 §6)
- [ ] Exceções de hook mapeadas pela captura única do fiber (doc 03 L3); hooks sem timeout próprio (doc 05 §5)
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (chat é duplo; o require de `ruby_llm` segue confinado e lazy — doc 03 §7)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui. Em especial: a estrutura interna de `Hooks` (task 16), onde a task 11 colocou o contador de tool calls, e os nomes reais dos métodos privados do Executor (tasks 10-12).
- **Decomposição `run_before`/`run_after`**: o doc 05 §2 só especifica `around`, mas o estágio 7 não oferece um bloco envolvível (o loop é do RubyLLM e os callbacks são dois pontos separados — doc 03 §4/§6). As metades são a implementação fiel possível sem dirigir o loop; `around` fica como composição delas. Registrado aqui por ser a única extensão de interface desta task.
- **Limitação do `before_tool`**: por os callbacks do RubyLLM serem aditivos, o subject alterado não muda a call executada pelo modelo — só o que os hooks seguintes e os eventos veem. Alterar argumentos de verdade é Fase 2 (exigiria suporte do RubyLLM ou wrapper de tool). Lacuna do doc 05 §2 ("podem ALTERAR subject") aplicada ao par `:tool`; não re-decidir aqui.
- **Subject do par `:task`**: o doc não fixa o tipo; a escolha (o `TurnState`, que já é o objeto mutável do turno — doc 03 L5) dá aos hooks `:task` o mesmo poder de alteração dos middlewares, sem criar um segundo objeto de estado. Se a task 16 tiver fixado outra convenção de subject, siga-a.
- O comportamento de exceção em `before_tool` (escapar do callback e abortar o turno) é o que o doc 03 §6 assume para o guard-rail; se a versão pinada do RubyLLM (D9, `>= 1.15`) engolir exceções de callback, isso invalida o mecanismo do tool_limit — verificar no teste de integração da task 12 e escalar se necessário.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 12 novos (5 metades run_before/run_after + 7 integração no Executor), 464 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `spec/harness/executor_hooks_spec.rb`
- **Arquivos modificados:** `lib/harness/hooks.rb` (metades públicas; around composto delas), `lib/harness/executor.rb` (pares :task e :tool), `spec/harness/hooks_spec.rb`, `spec/support/fakes.rb` (NullHooks ganha as metades), `spec/harness/executor_chat_spec.rb` (Hooks real), `spec/harness/executor_pipeline_spec.rb` (pairs [:task, :agent])
- **Observações / decisões tomadas:**
  - `around` agora é `run_after(pair, yield(run_before(pair, subject)))` — comportamento idêntico ao da task 16 (specs pré-existentes verdes). As metades são públicas porque o par `:tool` não tem bloco a envolver (o loop é do RubyLLM): elas são chamadas dos callbacks `before_tool_call`/`after_tool_result` separadamente.
  - **`:task`** envolve os estágios do turno (2→9); o subject é o `TurnState` (via **block-param shadowing** — evita renomear todo o corpo e a mudança de assinatura de `run_pipeline`, que quebraria os stubs da task 10). Estágio 1 (begin_execution/transition/task_started) fica fora do wrap — before_task não os alteraria; documentado. Subject == resultado == `TurnState` (o content da Response vive no `:done`).
  - **`:agent`** já vinha da task 12 (`around(:agent, st)`); a decomposição do `around` habilita os afters automaticamente. `before_agent`/`after_agent` mutam/alteram via o `TurnState` subject.
  - **`:tool`** nos callbacks (aditivos): `run_before`/`run_after` rodam, mas **não reescrevem** a call que o modelo executa (limitação do RubyLLM aditivo, documentada no código — Fase 2). Exceção de hook `before_tool` aborta o turno (mecanismo do guard-rail).
  - **`max_tool_calls` fica INLINE** (não como hook registrado): registrar por turno na instância de `Hooks` **compartilhada** acumularia contadores entre turnos (Hooks não tem `unregister`). Desvio consciente do Step 5, alinhado ao próprio aviso de ciclo de vida da task; o contador segue na fronteira `before_tool` (só conta e aborta com `TimeoutError(stage: :tool_limit)`).
  - L6 verificado: `after_agent` que levanta não reexecuta o `chat.ask` (spy conta 1).
