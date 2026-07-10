# Task 14: `ContextFragment`/`ContextProvider`/`Builder` (fan-out Async, orçamento global, pinned, evicção)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [04-context-builder-providers.md](../04-context-builder-providers.md)
> **Status:** ✅ DONE
> **Complexity:** High

---

## Objective

Criar o contrato de contexto (`ContextFragment`, `ContextProvider`, `ContextRequest`, `ContextPackage`) e o `ContextBuilder` que seleciona providers por perfil, produz fragmentos em fan-out Async com timeout por provider, aplica o orçamento global de tokens com evicção por prioridade (respeitando `pinned`) e monta o pacote final em ordem canônica determinística.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | ⬜ TODO |

Grafo (tasks.md): `14 (Builder) → 1`. Esta task pode andar em paralelo à Etapa C (doc 00 §6).

## Context

É o estágio 2 da pipeline (doc 03 §4): o Executor chama o Builder e recebe um `ContextPackage` pronto — regra constitucional "o Runtime nunca monta prompt" (doc 04, preâmbulo; doc 00 §5.8). Esta task implementa o doc **04 §2–§4** (menos os providers reais, que são a task 15, e o wrap de hooks `before/after_prompt`, que é a task 16). Evolui conceitualmente o `system_prompt.rb` da Fase 0 para composição plugável com orçamento de tokens (doc 04 §8) — mas o provider `Prompt` em si é da task 15; aqui os testes usam providers fake.

O que esta task **habilita**: task 15 (providers reais implementam `ContextProvider`), task 16 (hooks envolvendo o Builder), task 17 (`PolicyRequest.context` recebe o pacote) e task 12 (`SendMessage` troca os stubs pelo Builder real).

Consome da task 1: `Harness::TokenEstimator` (D8), `Harness::ContextError` (D4), `Harness::Event` (D5), `Harness::AgentProfile.limits` (D6 — `provider_timeout: 5`, `context_budget: 8_000`).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/context/fragment.rb` | `ContextFragment` (Data + `.build` com defaults) |
| CREATE | `lib/harness/context/provider.rb` | Classe base `ContextProvider` + `ContextRequest` |
| CREATE | `lib/harness/context/builder.rb` | `ContextBuilder` + `ContextPackage` (algoritmo doc 04 §4) |
| MODIFY | `lib/harness.rb` | Adicionar os `require_relative` dos 3 arquivos (zero side-effects, doc 00 §3) |
| CREATE | `spec/harness/context/fragment_spec.rb` | Defaults do `.build`, imutabilidade |
| CREATE | `spec/harness/context/builder_spec.rb` | Seleção, fan-out, timeout, orçamento, ordem canônica, erros |

> O layout do doc 00 §3 fixa exatamente `lib/harness/context/{fragment,provider,builder}.rb`. Distribuição dos tipos: `ContextRequest` acompanha `provider.rb` (é o input do contrato de provider) e `ContextPackage` acompanha `builder.rb` (é o output do Builder).

### Step-by-Step Instructions

#### Step 1: `ContextFragment`

**File:** `lib/harness/context/fragment.rb`

`# frozen_string_literal: true` no topo (convenção Fase 0). Definir dentro de `module Harness` (o fragmento é tipo compartilhado — doc 00 §2 o lista em `Harness::`, não em `Harness::Context::`):

```ruby
module Harness
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned) do
    # placement: :system | :history | :tool_context   (RFC-0005 §2)
    # priority:  Integer; maior = mais importante (sobrevive a cortes)
    # tokens:    Integer | nil; estimado pelo Builder quando nil (L3)
    # source:    String — id do provider (auditoria)
    # pinned:    true → incortável no orçamento (ex.: identidade)
    def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                   pinned: false)
      new(content:, placement:, priority:, tokens:, source:, pinned:)
    end
  end
end
```

Assinatura e defaults são os do doc 04 §2 — não mudar. `placement` fora do enum não precisa de validação dura na Fase 1 (o doc não a exige), mas o Builder só agrupa os três placements conhecidos.

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/event.rb` — estilo de value object da Fase 0):
```ruby
# frozen_string_literal: true

module AgentRuntime
  Event = Data.define(:type, :data) do
    def to_h
      { type: type }.merge(data)
    end
  end
end
```

#### Step 2: `ContextProvider` (classe base) + `ContextRequest`

**File:** `lib/harness/context/provider.rb`

Copiar o contrato do doc 04 §2, literal:

```ruby
module Harness
  # Classe base de provider (RFC-0005 §2). Subclasses vivem em
  # Harness::Context::Providers (task 15).
  class ContextProvider
    def id = self.class.name          # override para nome estável
    def required? = false             # true → falha aborta o turno (D4)
    def enabled_for?(_profile) = true
    def call(_request) = []           # -> [ContextFragment]; pode fazer IO
  end

  ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                               :checkpoint)
  # session:    SessionStore::Session | nil (D2)
  # checkpoint: Checkpoint | nil (presente em ResumeTask — histórico vem dele)
end
```

Nada além disso — a base é deliberadamente mínima (L5: `required?` mora no provider, não no wiring).

#### Step 3: `ContextBuilder` + `ContextPackage` — esqueleto e seleção

**File:** `lib/harness/context/builder.rb`

```ruby
require "async"

module Harness
  ContextPackage = Data.define(:system, :history, :tool_context,
                               :fragments, :budget)
  # system:       String (concatenação final p/ with_instructions)
  # history:      [{role:, content:}] (p/ seed do chat)
  # tool_context: String | nil
  # fragments:    [ContextFragment] pós-corte (auditoria)
  # budget:       { cap:, used:, evicted: [source] }

  class ContextBuilder
    def initialize(providers:, hooks: nil, event_stream:,
                   estimator: TokenEstimator)
      ...
    end

    def call(request) # -> ContextPackage
  end
end
```

- `hooks:` é **armazenado e não usado nesta task** (default `nil`). A task 16 cria a classe `Hooks` e liga o par `before/after_prompt`. Não implementar nenhum comportamento de hook aqui.
- `require "async"` no topo do builder é permitido: `async` é dependência pinada do núcleo (D9); só `ruby_llm` é proibido em load-time fora do Executor.

**Seleção** (passo 1 do doc 04 §4): dupla condição —

```ruby
selected = @providers.select do |p|
  p.enabled_for?(request.profile) &&
    allowlisted?(p, request.profile.context_providers)
end
```

`allowlisted?` implementa a semântica de allowlist do D6 (a MESMA de tools/skills — "uma regra só, testada uma vez"):
- `nil` → todos passam;
- `[]` → nenhum passa;
- `[names]` → passa quem tiver `p.id` incluído (comparar como `String`).

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb` — a mesma semântica na Fase 0):
```ruby
    # Allowlist por agente (semântica OpenClaw):
    #   nil -> todas | [] -> nenhuma | [names] -> subconjunto final
    def effective(skills_policy)
      return all if skills_policy.nil?
      return [] if skills_policy.empty?

      names = Array(skills_policy).map(&:to_s)
      all.select { |s| names.include?(s.name) }
    end
```

#### Step 4: Produção — fan-out Async com barrier e timeout por provider

Passo 2 do doc 04 §4 + §5. Cada provider selecionado roda num fiber **filho** do fiber corrente (filho do fiber da task — cancelar a task cancela a produção em voo):

```ruby
timeout = request.profile.limits[:provider_timeout] # default 5 (D4/D6)

results = selected.map do |provider|
  [provider, Async do |t|
    t.with_timeout(timeout) { provider.call(request) }
  end]
end

fragments = []
results.each do |provider, task|
  fragments.concat(Array(task.wait))
rescue StandardError, Async::TimeoutError => e
  handle_provider_failure(provider, e)   # Step 5
end
```

Pontos obrigatórios:
- **Barrier** (L6): o Builder espera TODOS antes de orçar — o corte de orçamento é uma dependência cross-item real. Não usar pipeline/streaming de fragmentos.
- `Async::Task#with_timeout` — **nunca** `Timeout.timeout` da stdlib (D4: thread-based, viola o modelo Async/Fibers).
- `Array(task.wait)` tolera provider que devolve `nil` (contrato diz `[]`, mas o Builder é defensivo — ver Edge Cases).
- O acesso ao limite segue a estrutura de `AgentProfile.limits` da task 1 (D6 mostra um Hash com defaults; se a task 1 tiver exposto acesso por método, usar o que existir).

#### Step 5: Erros por provider — degradação vs. `ContextError`

Doc 04 §6 (aplicação do D4, linha "Context Builder"):

```ruby
def handle_provider_failure(provider, error)
  if provider.required?
    raise ContextError.new("provider obrigatório '#{provider.id}' falhou: #{error.message}")
    # ContextError expõe attr_reader :provider (D4) — setar provider: provider.id
  end
  @event_stream.emit(Event.new(
    type: :provider_warning,
    data: { provider: provider.id, message: error.message },
    meta: { at: Time.now.utc.iso8601 }
  ))
  # fragmentos do provider omitidos; turno segue (degradação graciosa)
end
```

- Provider **opcional** que falha ou estoura timeout → fragmentos omitidos + evento `:provider_warning { provider:, message: }`; o `call` continua.
- Provider **`required?`** que falha (inclusive timeout) → `ContextError` com `provider` preenchido; quem transforma isso em task `:failed` é o Executor (D4) — o Builder só levanta.
- O construtor de `ContextError` com `provider:` vem da task 1 (D4 declara `attr_reader :provider`); se a task 1 tiver dado outra assinatura ao construtor, seguir o código real.
- `meta` do evento: o Builder não conhece `task_id`/`seq` (correlação completa é preenchida na integração com o Executor, task 12); emitir com o que tem (ver Notes).

#### Step 6: Coleta e estimativa de tokens

Passo 3 do doc 04 §4 + L3: provider simples não conhece tokenização —

```ruby
fragments = fragments.map do |f|
  f.tokens ? f : f.with(tokens: @estimator.estimate(f.content))
end
```

`TokenEstimator.estimate` é o da task 1 (D8): `(text.to_s.length / 4.0).ceil` — o `to_s` cobre fragmentos `:history` cujo `content` é Hash.

#### Step 7: Orçamento — evicção global por priority ASC, pinned incortável

Passos 4–5 do doc 04 §4, D8 e L1. Manter o **índice de produção** de cada fragmento (posição na lista coletada) — ele é o desempate estável:

```ruby
cap  = request.profile.limits[:context_budget]   # default 8_000 (D6)
used = fragments.sum(&:tokens)
evicted = []

if used > cap
  # candidatos a corte: não-pinned, do menor priority para o maior;
  # empate de priority → menor índice de produção primeiro (corte estável:
  # entre iguais, cai o produzido antes — p/ :history isso descarta a
  # mensagem mais antiga primeiro, exatamente o efeito desejado em L7)
  cuttable = indexed_fragments.reject { |f, _i| f.pinned }
                              .sort_by { |f, i| [f.priority, i] }
  cuttable.each do |fragment, index|
    break if used <= cap
    used -= fragment.tokens
    evicted << fragment.source
    remove(index)
  end
  raise ContextError, "orçamento insolúvel: fragmentos pinned (#{used} tokens) excedem o cap (#{cap})" if used > cap
end
```

Regras (todas testáveis):
- Corte **global**, não por-placement (L1): as priorities escalonadas do histórico já produzem o efeito por-placement desejado.
- `pinned` **nunca** é cortado (D8). Se, cortado tudo que era cortável, ainda estourar (só pinned excede o cap) → `ContextError` com mensagem explícita — "configuração inválida deve falhar alto, não truncar identidade" (doc 04 §6).
- Para **exatamente** quando cabe (`used <= cap`), nunca corta a mais (doc 04 §7).
- `used == cap` não é estouro (só `>` dispara evicção).
- Evicção **não é erro**: registrar `budget.evicted` (lista de `source`, um por fragmento cortado — pode repetir source) e emitir **um** `:provider_warning` **agregado** quando algo foi cortado (doc 04 §6), ex.: `{ provider: "ContextBuilder", message: "orçamento: N fragmento(s) evictado(s) de [sources]" }`.

#### Step 8: Montagem — ordem canônica determinística

Passo 6 do doc 04 §4 + §3 (L2):

- `system`: fragmentos `:system` ordenados por `priority` **descendente**, empate por `source` **alfabético**, empate residual (mesmo priority E mesmo source) pelo índice de produção — a ordenação total é estável e determinística (handoff §6). Concatenar `content` com `"\n\n"`. Isso reproduz a saída da Fase 0: `Prompt(100) → Skill(80) → Request(40)` ≙ `base+SOUL → skills_block`.

```ruby
system = fragments.select { |f| f.placement == :system }
                  .sort_by.with_index { |f, i| [-f.priority, f.source, i] }
                  .map(&:content).join("\n\n")
```

- `history`: fragmentos `:history` em ordem **cronológica** = ordem de produção (a prioridade só decide **corte**, nunca reordena mensagens — doc 04 §3). Cada `content` é um Hash `{role:, content:}` (contrato com o provider `Session`, task 15) e vai direto para `package.history`.
- `tool_context`: fragmentos `:tool_context` concatenados com `"\n\n"`; `nil` se não houver nenhum.
- `fragments`: a lista pós-corte (auditoria), na ordem canônica.
- `budget`: `{ cap:, used:, evicted: }` com `used` = soma dos tokens pós-corte.

Retornar o `ContextPackage`. O Builder **não** conhece RubyLLM — quem faz `chat.with_instructions(package.system)` é o Executor (doc 04 §4).

#### Step 9: Requires em `lib/harness.rb`

Adicionar, na ordem de dependência (fragment → provider → builder), após os tipos base da task 1. `lib/harness.rb` permanece só-requires, zero side-effects (doc 00 §3).

### Edge Cases to Handle

1. **Provider devolve `nil` ou não-array** → `Array(...)` normaliza; sem crash (contrato diz `[]`, Builder é defensivo).
2. **Nenhum provider selecionado** (allowlist `[]` ou nenhum `enabled_for?`) → pacote vazio válido: `system == ""`, `history == []`, `tool_context == nil`, `used == 0` — não é erro.
3. **`used == cap` exato** → sem evicção, sem warning.
4. **Só pinned já excede o cap** → `ContextError` (nunca truncar pinned).
5. **Provider opcional lento** (> `provider_timeout`) → `Async::TimeoutError` capturado → warning + turno segue; **required lento** → `ContextError`.
6. **Fragmento com `tokens` já informado** → Builder não re-estima (L3: só preenche quando `nil`).
7. **Empate de priority na evicção** → índice de produção ASC (estável): entre history a 79 (teto L7), a mais antiga cai primeiro.
8. **Empate priority+source na montagem do system** → índice de produção (ordenação estável) — determinismo total exigido pelo handoff §6.
9. **Cancelamento da task durante a produção** → providers são fibers filhos; a subárvore Async é cancelada junto (doc 04 §5) — não precisa de código extra, mas não engolir `Async::Stop`.

## Testing

Builder **puro**, sem IO: providers fake devolvendo fragmentos roteirizados (doc 04 §7). Testes de fan-out/timeout rodam dentro de `Async { ... }` (ou `Sync { ... }`) no exemplo RSpec.

### Unit Tests

**File:** `spec/harness/context/fragment_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| defaults do build | `ContextFragment.build(content:, placement:, source:)` | `priority == 50`, `tokens.nil?`, `pinned == false` |
| imutabilidade | tentativa de mutação | `Data` congelado; `with` devolve cópia |

**File:** `spec/harness/context/builder_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| allowlist nil | `context_providers: nil` | todos os providers habilitados rodam |
| allowlist vazia | `context_providers: []` | nenhum roda; pacote vazio válido |
| allowlist nomeada | `context_providers: [id_a]` | só o provider `id_a` roda |
| enabled_for? falso | provider com `enabled_for? => false` | não roda mesmo com allowlist nil |
| agrupamento por placement | fragmentos `:system`/`:history`/`:tool_context` | cada um no campo certo do pacote |
| ordem canônica DESC | priorities 100/80/40 | system = 100 → 80 → 40, join `"\n\n"` |
| empate determinístico | dois fragmentos priority 80, sources "B" e "A" | "A" antes de "B" (alfabético); repetir a chamada dá saída idêntica (handoff §6) |
| history cronológico | history com priorities variadas | ordem de produção preservada (priority não reordena) |
| tokens estimados | fragmento com `tokens: nil` | Builder preenche via estimator (L3); `tokens` informado não é sobrescrito |
| orçamento corta menor priority | cap estourado | menor priority cai primeiro; para exatamente quando `used <= cap` |
| evicção estável em empate | dois fragmentos mesmo priority | o produzido antes cai primeiro |
| pinned incortável | pinned de priority baixa + estouro | pinned sobrevive; não-pinned de priority maior cai |
| pinned-only estoura | só fragmentos pinned > cap | `ContextError` com mensagem explícita |
| evicted registrado | corte acontece | `budget.evicted` lista os sources + 1 `:provider_warning` agregado no stream |
| used/cap no budget | qualquer chamada | `budget == { cap:, used:, evicted: }` coerente pós-corte |
| provider opcional falha | fake que levanta | fragmentos omitidos + `:provider_warning {provider:, message:}`; pacote montado com o resto |
| provider opcional dorme | fake com `Async::Task#sleep` > timeout | `:provider_warning`; turno segue |
| required falha | fake `required? => true` que levanta | `ContextError` com `provider` |
| required lento | fake required que dorme > timeout | `ContextError` |
| provider devolve nil | fake devolvendo `nil` | tratado como `[]` |

### Integration Tests (if applicable)

Não aplicável nesta task — a integração com providers reais é a task 15 e com o Executor é a task 12.

## Definition of Done

- [ ] `ContextFragment`/`ContextProvider`/`ContextRequest`/`ContextPackage` com as assinaturas exatas do doc 04 §2
- [ ] `ContextBuilder#call` implementa os 6 passos do doc 04 §4 (seleção → produção → coleta → agrupamento → orçamento → montagem)
- [ ] Semântica de allowlist `nil`/`[]`/`[names]` idêntica à de tools/skills (D6)
- [ ] Fan-out com barrier (L6), fibers filhos, `with_timeout` por provider (nunca `Timeout.timeout`)
- [ ] Evicção global priority ASC, pinned incortável, parada exata, `ContextError` em pinned-only estourando
- [ ] Ordem canônica determinística (priority DESC → source alfabético → índice estável) — mesma entrada, mesma saída, sempre
- [ ] Eventos `:provider_warning` (degradação e evicção agregada) emitidos via `EventStream`
- [ ] `# frozen_string_literal: true` em todos os arquivos; comentários em português
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key (handoff §6)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **`hooks:` dormente:** o parâmetro existe desde já (assinatura do doc 04 §2) mas o mecanismo `Hooks` só nasce na task 16 — armazenar e ignorar (default `nil`). Não escrever lógica condicional de hook nesta task.
- **`meta` do `:provider_warning`:** o catálogo D5 pede `meta { task_id:, session_id:, seq:, at: }`, mas o Builder não conhece `task_id`/`seq` (correlação é do Executor). Emitir com o que houver (`at:`, e `session_id` se `request.session`); `Event#to_h` já faz `meta.compact`. Lacuna registrada — alinhar com a task 12 quando o Executor passar a correlacionar.
- **Acesso a `limits`:** D6 declara `limits` como Hash com defaults; o doc 04 usa notação de ponto por concisão. Seguir o acesso real definido na task 1.
- **Desempate por índice de produção** (evicção e montagem): não está literal no doc 04, mas é a única forma de tornar a ordenação/corte totalmente determinísticos em empate de `priority`+`source` (exigência handoff §6) e de honrar L7 ("descarta as mais antigas primeiro" entre histories no teto 79). É detalhe de implementação, não decisão arquitetural nova.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 24 novos (3 fragment + 21 builder, incl. prova de fan-out concorrente), 367 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/context/fragment.rb`, `lib/harness/context/provider.rb`, `lib/harness/context/builder.rb`, `spec/harness/context/fragment_spec.rb`, `spec/harness/context/builder_spec.rb`
- **Arquivos modificados:** `lib/harness.rb` (requires)
- **Observações / decisões tomadas:**
  - `ContextFragment` é tipo COMPARTILHADO (`Harness::`, overview §2), criado agora (estava pendente). `ContextRequest` acompanha `provider.rb`, `ContextPackage` acompanha `builder.rb`.
  - Fan-out com **barrier** (L6): fibers filhos do fiber corrente, `with_timeout` por provider. `Async::TimeoutError` é `StandardError` (degrada); `Async::Stop` NÃO é (cancelamento propaga) — por isso o `rescue StandardError` é suficiente e correto.
  - Evicção global priority ASC com desempate por índice de produção; `pinned` incortável; `ContextError` (com `provider: "ContextBuilder"`) se só pinned excede. Um `:provider_warning` agregado por corte.
  - Montagem determinística: system por `[-priority, source, índice]`; history em ordem de produção (priority só corta, não reordena); tool_context concatenado ou `nil`.
  - `hooks:` armazenado e **dormente** (task 16).
  - **Seam de integração registrado (não bloqueia):** o `Executor` (task 12) hoje monta um `Executor::ContextRequest` (Struct própria, com `task`/`history`) para o `FakeContextBuilder` dos testes, enquanto o Builder real consome `Harness::ContextRequest` (session/message/profile/tenant/vars/checkpoint). São constantes distintas (a aninhada não colide). A reconciliação — o Executor produzir `Harness::ContextRequest` e o histórico one-shot virar um provider (task 15) — é da integração (tasks 15/26), conforme o próprio plano.
  - `:provider_warning` emite `meta` com `session_id`/`at` (o Builder não conhece `task_id`/`seq`) — lacuna registrada para a correlação do Executor (task 12).
