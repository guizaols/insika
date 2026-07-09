# Task 16: Classe `Hooks` (mecanismo around) + par `before/after_prompt` envolvendo o Builder

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [05-policy-middleware-hooks.md](../05-policy-middleware-hooks.md) · [04-context-builder-providers.md](../04-context-builder-providers.md)
> **Status:** ✅ DONE
> **Complexity:** Low

---

## Objective

Criar a classe `Harness::Hooks` (registro por pares + mecanismo `around` com befores em ordem, afters em ordem inversa e alteração de subject/resultado) e integrar o par `before/after_prompt` ao `ContextBuilder`, ativando o parâmetro `hooks:` deixado dormente pela task 14.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 14 | `ContextFragment`/`ContextProvider`/`Builder` (fan-out Async, orçamento global, pinned, evicção) | ⬜ TODO |

Grafo (tasks.md): `16 (Hooks + par prompt) → 14`.

## Context

Implementa a classe `Hooks` do doc **05 §2** e sua primeira integração, o par `:prompt` do doc **04 §4** (estágio 2 da pipeline). Hooks são o terceiro papel da fronteira formal do princípio constitucional 9 (doc 05 §1): **Middleware modifica, Hooks alteram, Events observam** — um hook pode alterar entrada/saída de UM estágio que envolve; não pode criar fluxo próprio nem pular estágios.

Esta task cria o **mecanismo completo** (os 4 pares `%i[task prompt agent tool]` existem no enum desde já — RFC-0002 §6), mas integra **apenas** o par `:prompt`. Os pares restantes (`before/after_task`, `_agent`, `_tool`) são integrados ao Executor na **task 19** — não fazer nada no Executor aqui.

Efeito prático do par `:prompt` (doc 04 §4): `before_prompt` pode reescrever o `ContextRequest` antes dos providers rodarem; `after_prompt` pode reescrever o `ContextPackage` montado (RFC-0005 §4). Habilita: task 19 (demais pares) e task 21 (plugins registrando hooks).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/hooks.rb` | Classe `Hooks` (doc 05 §2) — layout doc 00 §3 |
| MODIFY | `lib/harness/context/builder.rb` | Ativar `hooks:` — `call` envolve a montagem com `around(:prompt, ...)` |
| MODIFY | `lib/harness.rb` | `require_relative "harness/hooks"` (antes de `context/builder`) |
| CREATE | `spec/harness/hooks_spec.rb` | Mecanismo puro (ordem, alteração, exceções) |
| MODIFY | `spec/harness/context/builder_spec.rb` | Casos de integração do par `:prompt` |

### Step-by-Step Instructions

#### Step 1: Classe `Hooks`

**File:** `lib/harness/hooks.rb`

Contrato exato do doc 05 §2:

```ruby
# frozen_string_literal: true

module Harness
  # Hooks alteram entrada/saída de UM estágio que envolvem (princípio 9;
  # doc 05 §1). Não criam fluxo próprio, não pulam estágios.
  class Hooks
    PAIRS = %i[task prompt agent tool].freeze   # RFC-0002 §6

    def initialize
      @before = Hash.new { |h, k| h[k] = [] }
      @after  = Hash.new { |h, k| h[k] = [] }
    end

    # callables; múltiplos por par. Ordem de registro é significativa.
    def register(pair, before: nil, after: nil)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair] << before if before
      @after[pair]  << after  if after
      nil
    end

    # befores na ordem de registro (podem ALTERAR subject retornando o novo),
    # yield(subject), afters na ordem INVERSA (podem alterar o resultado).
    def around(pair, subject)
      raise ArgumentError, "par de hook desconhecido: #{pair.inspect}" unless PAIRS.include?(pair)

      @before[pair].each { |hook| subject = hook.call(subject) }
      result = yield(subject)
      @after[pair].reverse_each { |hook| result = hook.call(result) }
      result
    end
  end
end
```

Regras a preservar (doc 05 §2, §5, §6):
- **Alteração por retorno:** o valor devolvido pelo before vira o novo `subject`; o devolvido pelo after vira o novo `result`. Hook que não quer alterar **devolve o que recebeu** — é a convenção do contrato ("podem ALTERAR subject retornando o novo"); não há tratamento especial para `nil` (devolver `nil` É alterar para `nil`).
- **Ordem:** befores na ordem de registro; afters na ordem **inversa** (simetria de "envolvimento": o primeiro a preparar é o último a desfazer).
- **Síncronos por definição** (doc 05 §5): nada de fan-out; hook lento é coberto pelo timeout do turno (D4) — sem timeout próprio.
- **Exceções** (doc 05 §6): `Hooks` **não faz rescue**. Exceção em `before_X` propaga antes do estágio rodar (falha do estágio envolvido); exceção em `after_X` propaga **depois** — o estágio já executou e o mecanismo, por construção, não o reexecuta (L6: side-effects já aconteceram). O mapeamento erro→estado terminal é do Executor (doc 03 L3).
- Par desconhecido em `register`/`around` → `ArgumentError` (bug de programação, não erro de runtime do turno).
- Sem registros para o par → `around` degenera em `yield(subject)` (no-op) — é o que mantém a task 14 funcionando sem nenhum hook registrado.

**Reference pattern from codebase:** a Fase 0 não tem mecanismo de hooks (os callbacks `before_tool_call`/`after_tool_result` do `runner.rb` são do RubyLLM e permanecem lá — doc 03 §4.2). O padrão a seguir é o contrato literal do doc 05 §2 acima; para estilo de classe pequena com estado interno simples, ver `docs/harness_handoff/reference-implementation/lib/agent_runtime/tool_registry.rb`:
```ruby
module AgentRuntime
  class ToolRegistry
    Entry = Data.define(:name, :tool_class, :optional)

    def initialize
      @tools = {}
    end

    def register(name, tool_class, optional: false)
      @tools[name.to_s] = Entry.new(name: name.to_s, tool_class:, optional:)
    end
    ...
```

#### Step 2: Integrar o par `:prompt` no `ContextBuilder`

**File:** `lib/harness/context/builder.rb`

A task 14 deixou `hooks:` armazenado e inerte. Ativar:

1. Default do construtor passa de `nil` para uma instância vazia: `def initialize(providers:, hooks: Hooks.new, event_stream:, estimator: TokenEstimator)` — elimina o branch de nil (hooks vazio = no-op por construção).
2. Extrair a montagem atual de `call` para um método privado (ex.: `build_package(request)`) e envolver:

```ruby
def call(request)                 # -> ContextPackage
  @hooks.around(:prompt, request) do |req|
    build_package(req)            # passos 1–6 do doc 04 §4 (task 14)
  end
end
```

Semântica resultante (doc 04 §4):
- `before_prompt` recebe o `ContextRequest` e pode devolver outro (ex.: request com `vars` enriquecidas) — os providers rodam com o request **alterado** (`req`, não o original).
- `after_prompt` recebe o `ContextPackage` e "pode reescrever o pacote" (RFC-0005 §4) — o Executor recebe o pacote pós-after.
- Com hooks vazio, comportamento **idêntico** ao da task 14 (todos os specs existentes do Builder continuam verdes sem alteração de expectativa).

> Onde mora o wrap: o doc 03 §4 desenha `hooks.around(:prompt, request) { context_builder.call(request) }` no Executor, e o doc 04 §2 dá `hooks:` ao construtor do Builder. Esta task segue o doc 04 (que é o doc do componente e do plano: "par `before/after_prompt` **envolvendo o Builder**"): o wrap vive DENTRO de `Builder#call`, e o Executor (tasks 12/19) chama só `builder.call(request)` — **sem** envolver de novo (double-wrap executaria os hooks duas vezes). Ver Notes.

#### Step 3: Require

**File:** `lib/harness.rb`

`require_relative "harness/hooks"` antes de `harness/context/builder` (o default do construtor referencia `Hooks`). Zero side-effects (doc 00 §3).

### Edge Cases to Handle

1. **Nenhum hook registrado** → `around` = passthrough puro; Builder se comporta exatamente como na task 14.
2. **Múltiplos befores** → encadeiam: o output do primeiro é o input do segundo (ordem de registro).
3. **Múltiplos afters** → ordem inversa de registro; o resultado final é o do primeiro registrado (último a rodar).
4. **Before devolve subject alterado** → o bloco (providers/montagem) enxerga o alterado; o original não é usado.
5. **Exceção em `before_prompt`** → nenhum provider roda; a exceção propaga (no wiring real, o Executor a mapeia para falha do turno — D4).
6. **Exceção em `after_prompt`** → a montagem JÁ rodou (e não reexecuta — L6); exceção propaga.
7. **`register(pair)` sem `before:` nem `after:`** → no-op silencioso válido (nada a registrar).
8. **Par fora de `PAIRS`** → `ArgumentError` imediato, tanto em `register` quanto em `around`.
9. **Somente o par `:prompt` é integrado** — registrar hooks de `:task`/`:agent`/`:tool` funciona (mecanismo pronto), mas ninguém os invoca até a task 19.

## Testing

Tudo puro — zero RubyLLM, zero IO (doc 05 §7).

### Unit Tests

**File:** `spec/harness/hooks_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| ordem dos befores | 2 befores que anexam marcador ao subject | executados na ordem de registro; subject acumula na ordem |
| ordem inversa dos afters | 2 afters que anexam marcador ao resultado | executados na ordem INVERSA de registro |
| alteração de subject | before devolve subject novo | o bloco recebe o novo (spy no yield) |
| alteração de resultado | after devolve resultado novo | `around` retorna o transformado |
| passthrough | nenhum registro | `around` retorna exatamente o resultado do bloco; bloco recebe o subject original |
| after não reexecuta o estágio | bloco com contador + after que levanta | contador == 1 e exceção propaga (doc 05 §7 / L6) |
| before que levanta | before com raise + bloco com contador | contador == 0 (estágio nunca rodou); exceção propaga |
| par desconhecido | `register(:foo, ...)` / `around(:foo, x)` | `ArgumentError` |
| pares válidos | `PAIRS` | `%i[task prompt agent tool]` congelado |
| múltiplos por par | 3 befores no mesmo par | todos rodam, encadeados |

### Integration Tests (if applicable)

**File:** `spec/harness/context/builder_spec.rb` (casos adicionados)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| before_prompt reescreve o request | hook devolve request com outro `message`/`vars`; provider fake ecoa o request | providers recebem o request ALTERADO |
| after_prompt reescreve o pacote | hook devolve `ContextPackage` com `system` modificado | `builder.call` retorna o pacote pós-after |
| sem hooks | Builder com `Hooks.new` vazio | saída idêntica à da task 14 (specs pré-existentes inalterados) |
| ordem com montagem no meio | before + after com spies | before → montagem → after (sequência verificada) |
| after que levanta | provider fake com contador + after com raise | providers rodaram 1×; exceção propaga; nenhum provider reexecutado |

## Definition of Done

- [ ] `Harness::Hooks` com `PAIRS`, `register(pair, before:, after:)` e `around(pair, subject)` conforme doc 05 §2, incluindo alteração de subject/resultado por retorno
- [ ] Befores em ordem de registro; afters em ordem inversa; exceção nunca reexecuta o estágio (L6)
- [ ] `ContextBuilder#call` envolto por `around(:prompt, ...)`; `before_prompt` altera o `ContextRequest`, `after_prompt` o `ContextPackage` (doc 04 §4)
- [ ] Hooks vazio = comportamento idêntico ao da task 14 (specs do Builder pré-existentes passam sem mudança)
- [ ] Nenhuma integração no Executor (pares `:task`/`:agent`/`:tool` ficam para a task 19)
- [ ] `# frozen_string_literal: true`; comentários em português; classe pequena de responsabilidade única
- [ ] Suíte roda sem ruby_llm instalado e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Divergência aparente doc 03 × doc 04 sobre quem chama `around(:prompt)`:** o doc 03 §4 (estágio 2) desenha o wrap no Executor; o doc 04 §2/§4 entrega `hooks:` ao Builder e o plano (tasks.md) diz "envolvendo o Builder". Esta task implementa o wrap dentro de `Builder#call`. Consequência para as tasks 12/19: o Executor NÃO deve envolver `builder.call` com `around(:prompt, ...)` de novo — deixar este aviso visível no código (comentário no Builder). Se, ao chegar na task 19, o time preferir mover o wrap para o Executor, é uma mudança de 3 linhas — mas um lugar só, nunca os dois.
- **Instância compartilhada:** o mesmo objeto `Hooks` será injetado no Builder e no Executor (construtor do Executor já prevê `hooks:` — doc 03 §2); o wiring (composition root) cria UMA instância. Nesta task nenhum wiring é tocado — só a semente do contrato.
- **Plugins registrarão hooks na task 21** (`registries: { ..., hooks: }` — doc 06 §2); `register` já é a interface que o Loader vai consumir.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 16 novos (12 hooks + 4 integração :prompt no Builder), 408 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/hooks.rb`, `spec/harness/hooks_spec.rb`
- **Arquivos modificados:** `lib/harness/context/builder.rb` (ativa `hooks:`, wrap :prompt), `lib/harness/executor.rb` (remove wrap :prompt — evita double-wrap), `lib/harness.rb` (require), `spec/harness/context/builder_spec.rb` (casos :prompt), `spec/harness/executor_pipeline_spec.rb` (test de hooks atualizado)
- **Observações / decisões tomadas:**
  - `Hooks#around`: befores em ordem de registro (encadeiam o subject), afters em ordem inversa; alteração por retorno (nil É alterar para nil); sem rescue (doc 05 §6). Par fora de `PAIRS` → `ArgumentError`. Vazio = passthrough.
  - **Reconciliação doc 03 × doc 04 (decisão registrada):** o wrap do par `:prompt` vive DENTRO de `ContextBuilder#call` (como manda o doc 04 e o plano). A task 12 tinha colocado `@hooks.around(:prompt) { builder.call }` no Executor — **removido** para não haver double-wrap. O Executor agora chama `builder.call(request)` direto e mantém só o wrap `:agent`. Comentários em ambos os arquivos alertam sobre o double-wrap. A instância de `Hooks` é única (compartilhada Builder+Executor no wiring da task 26).
  - Test da task 12 ("hooks around") atualizado: o Executor envolve só `:agent` (com FakeContextBuilder, que não usa hooks); o `:prompt` real é exercitado nos specs do Builder.
  - Pares `:task`/`:agent`/`:tool` têm o mecanismo pronto mas só são integrados ao Executor na task 19 (nada tocado no Executor além da remoção do double-wrap).
