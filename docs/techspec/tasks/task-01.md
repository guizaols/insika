# Task 01: Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb`

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Criar o namespace `Harness` com os quatro tipos base da Fase 1 — taxonomia de erros (D4), `Event` com metadados de correlação (D5), `AgentProfile` estendido com 4 campos novos (D6) e `TokenEstimator` (D8) — migrando `Event` e `AgentProfile` da Fase 0 com `to_h` e call sites compatíveis.

## Dependencies

None — this task can start immediately. (Grafo do tasks.md: `1 (tipos base) → —`.)

## Context

Esta é a primeira task da Etapa A (fundação) e a raiz do grafo de dependências: **todas** as demais tasks dependem direta ou indiretamente dela. Ela materializa a decisão D1 (namespace `Harness` em `lib/harness/`) e o início do mapa de evolução da Fase 0 (00-overview §4):

- `lib/agent_runtime/event.rb` → `lib/harness/event.rb` — estende com `meta` (D5); `to_h` compatível.
- `lib/agent_runtime/agent_profile.rb` → `lib/harness/agent_profile.rb` — estende com 4 campos novos (D6), todos com default (call sites da Fase 0 continuam válidos).
- `lib/harness/errors.rb` — **novo**, taxonomia completa de D4.
- `lib/harness/token_estimator.rb` — **novo**, heurística de D8 atrás de interface trocável.

O repositório hoje só tem docs — este é o primeiro código em `lib/`. A task também cria o entry point `lib/harness.rb` (layout alvo em 00-overview §3: "requires; zero side-effects") e o esqueleto mínimo de specs (`spec/spec_helper.rb`, `.rspec`), que as tasks seguintes reutilizam.

O que cada tipo habilita:

- `errors.rb` → contrato de erro de **todos** os estágios (D4); a task 4 usa `StoreError`, a task 9 usa `ValidationError`/`NotFoundError`, o Executor (task 10-12) usa o resto.
- `event.rb` → Event Stream com correlação (`task_id`/`seq`), pré-requisito da multiplexação e do replay (D5, tasks 10, 24).
- `agent_profile.rb` → ponto único de política por agente; `limits` alimenta os timeouts de D4, `policies`/`workflows_allow` alimentam o Policy Engine (task 17), `context_providers` o Builder (task 14), `prompt_refs` o PromptProvider (task 15).
- `token_estimator.rb` → orçamento de contexto do Builder (task 14).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/errors.rb` | Taxonomia completa de D4 (8 classes sob `Harness::Error`) |
| CREATE | `lib/harness/event.rb` | `Event = Data.define(:type, :data, :meta)` com `meta` default `{}` e `to_h` compatível (D5) |
| CREATE | `lib/harness/agent_profile.rb` | `AgentProfile` da Fase 0 + `context_providers`, `workflows_allow`, `policies`, `prompt_refs`, `limits` com defaults (D6) |
| CREATE | `lib/harness/token_estimator.rb` | `Harness::TokenEstimator.estimate(text) -> Integer` (D8) |
| CREATE | `lib/harness.rb` | Entry point: `require_relative` dos 4 arquivos; zero side-effects (00-overview §3) |
| CREATE | `spec/spec_helper.rb` | Setup mínimo de RSpec (sem RubyLLM, sem API key) |
| CREATE | `.rspec` | `--require spec_helper` |
| CREATE | `spec/harness/errors_spec.rb` | Hierarquia e attr_readers |
| CREATE | `spec/harness/event_spec.rb` | Compatibilidade do `to_h` com a Fase 0 + `meta` |
| CREATE | `spec/harness/agent_profile_spec.rb` | Defaults dos campos novos + semântica preservada da Fase 0 |
| CREATE | `spec/harness/token_estimator_spec.rb` | Heurística `length/4` |
| CREATE | `Gemfile` | Mínimo para rodar a suíte (`rspec`); pinagem final é a task 26 (D9) — ver Notes |

### Step-by-Step Instructions

#### Step 1: Taxonomia de erros (D4)

**File:** `lib/harness/errors.rb`

Criar exatamente a taxonomia de D4 (00-overview §1). O código de D4 declara os `attr_reader` mas não os construtores — implemente construtores por keyword com mensagem default, para que os call sites dos estágios (docs 03-05) possam levantar com contexto estruturado:

```ruby
# frozen_string_literal: true

module Harness
  # Taxonomia única de erros da Fase 1 (00-overview D4).
  # Regra geral: erro vira evento, task tem estado terminal explícito,
  # checkpoint nunca é corrompido.
  class Error < StandardError; end

  class ValidationError < Error; end  # Command malformado -> HTTP 422, nenhuma Task criada
  class NotFoundError   < Error; end  # session/task/agente inexistente -> HTTP 404

  # Policy Engine negou -> evento :policy_denied, task :failed
  class PolicyDenied < Error
    attr_reader :policy, :reason

    def initialize(message = nil, policy: nil, reason: nil)
      @policy = policy
      @reason = reason
      super(message || "policy #{policy} negou: #{reason}")
    end
  end

  # provider required falhou -> task :failed
  class ContextError < Error
    attr_reader :provider

    def initialize(message = nil, provider: nil)
      @provider = provider
      super(message || "provider #{provider} falhou")
    end
  end

  class ProviderError  < Error; end  # RubyLLM esgotou retries -> task :failed
  class StoreError     < Error; end  # backend de persistência falhou -> task :failed
  class CancelledError < Error; end  # cancelamento cooperativo -> task :cancelled

  # estouro de timeout de estágio
  class TimeoutError < Error
    attr_reader :stage

    def initialize(message = nil, stage: nil)
      @stage = stage
      super(message || "timeout no estágio #{stage}")
    end
  end
end
```

Não adicione classes além dessas oito — a taxonomia é fechada por D4; novos erros exigem emenda no 00-overview.

#### Step 2: `Event` com `meta` (D5)

**File:** `lib/harness/event.rb`

Migrar de `AgentRuntime::Event` adicionando o terceiro campo `meta` com default `{}` (compatibilidade: os call sites da Fase 0 constroem `Event.new(type:, data:)` sem meta) e o `to_h` de D5.

**Reference pattern from codebase** (Fase 0 — `docs/harness_handoff/reference-implementation/lib/agent_runtime/event.rb`, código atual completo):

```ruby
# frozen_string_literal: true

module AgentRuntime
  # Tudo que o runtime emite durante um turno é um Event.
  # O consumidor (seu sistema WhatsApp) reage por :type.
  #
  #   :skill_activated  { name: }
  #   :tool_call        { name:, arguments: }
  #   :tool_result      { name:, result: }
  #   :content          { delta: }        # pedaço de texto
  #   :done             { content: }      # texto final consolidado
  #   :error            { message: }
  Event = Data.define(:type, :data) do
    def to_h
      { type: type }.merge(data)
    end
  end
end
```

**Delta exato da Fase 1:** namespace `Harness`, campo `:meta`, default via override de `initialize` (suportado por `Data` no Ruby ≥ 3.2), `to_h` conforme D5, e comentário atualizado com o catálogo canônico fechado (tabela de D5 — os 15 tipos):

```ruby
# frozen_string_literal: true

module Harness
  # Tudo que o runtime emite é um Event (catálogo canônico fechado em
  # 00-overview D5 — novos tipos exigem atualizar aquela tabela).
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotônico por task).
  # :done e :error são mantidos pelo contrato com o consumidor da Fase 0;
  # :task_completed/:task_failed são os equivalentes com correlação.
  Event = Data.define(:type, :data, :meta) do
    def initialize(type:, data:, meta: {})
      super
    end

    def to_h = { type:, **data, meta: meta.compact }
  end
end
```

Notas de precisão:

- `to_h` mantém `type` e as chaves de `data` **planas no topo**, como na Fase 0; `meta` é chave adicional (aditiva — consumidor Fase 0 ignora chaves desconhecidas). `meta.compact` remove nils (ex.: `session_id: nil` num turno one-shot não vai pro wire).
- Formato SSE inalterado: `data: {json}\n\n` (D5) — nada a fazer aqui, é responsabilidade do doc 07.
- Não valide `type` contra o catálogo em runtime — o catálogo é contrato de revisão (D5), não guard clause.

#### Step 3: `AgentProfile` estendido (D6)

**File:** `lib/harness/agent_profile.rb`

**Reference pattern from codebase** (Fase 0 — `docs/harness_handoff/reference-implementation/lib/agent_runtime/agent_profile.rb`, código atual completo):

```ruby
# frozen_string_literal: true

module AgentRuntime
  # Configuração por agente (data-driven, não uma subclasse por tenant).
  # Semântica de allowlist idêntica à do OpenClaw.
  #
  # tools_allow: nil/[]  -> sem restrição (todas as required + optional opt-in)
  #              [names]  -> conjunto final (não faz merge com defaults)
  # tools_deny:  [names]  -> sempre removidas
  # skills:      nil      -> todas as skills
  #              []       -> nenhuma skill
  #              [names]  -> subconjunto (conjunto final)
  AgentProfile = Data.define(
    :id, :model, :provider, :base_prompt, :prompt_files,
    :tools_allow, :tools_deny, :skills
  ) do
    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills
      )
    end

    # opt-in de tool optional = estar na allow do agente.
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
```

**Delta exato da Fase 1:** namespace `Harness` + 5 campos novos no `Data.define` (D6: `context_providers`, `workflows_allow`, `policies`, `prompt_refs`, `limits`), todos com default no `build`. Preserve `tool_opted_in?` e o comentário de semântica, estendido:

```ruby
# frozen_string_literal: true

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  AgentProfile = Data.define(
    :id, :model, :provider,           # Fase 0
    :base_prompt, :prompt_files,      # Fase 0
    :tools_allow, :tools_deny,        # Fase 0
    :skills,                          # Fase 0
    :context_providers,               # NOVO — allowlist de providers (RFC-0005 §4.1)
    :workflows_allow,                 # NOVO — aplicado pela WorkflowAllowlist (doc 05 §2)
    :policies,                        # NOVO — nomes no Policy Registry (estágio 3)
    :prompt_refs,                     # NOVO — nomes do Prompt Catalog (doc 04 §2)
    :limits                           # NOVO — timeouts/orçamentos (D4/D8)
  ) do
    DEFAULT_LIMITS = {
      turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
      context_budget: 8_000, max_turns: 25, max_tool_calls: 50
    }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {})
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits)
      )
    end

    # opt-in de tool optional = estar na allow do agente (Fase 0, inalterado).
    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
```

Notas de precisão:

- Defaults conforme D6: `context_providers: nil` e `workflows_allow: nil` seguem a semântica de allowlist (nil = todos); `policies: []` e `prompt_refs: []` são listas de nomes vazias por default; `limits` faz merge raso sobre `DEFAULT_LIMITS` (valores de D6: `turn_timeout: 300, tool_timeout: 60, provider_timeout: 5, context_budget: 8_000, max_turns: 25, max_tool_calls: 50`).
- **Não** implemente aqui a avaliação das allowlists de providers/workflows — isso é do Builder (task 14) e do Policy Engine (task 17). O profile só carrega dados.

#### Step 4: `TokenEstimator` (D8)

**File:** `lib/harness/token_estimator.rb`

```ruby
# frozen_string_literal: true

module Harness
  # Estimativa de tokens barata atrás de interface (00-overview D8).
  # Default: text.length / 4 (erra ~±15%, absorvido pela margem do budget).
  # Trocável por tokenizer real sem tocar no Builder: qualquer objeto que
  # responda a #estimate(text) -> Integer serve como substituto (injeção no
  # composition root, doc 04).
  module TokenEstimator
    module_function

    def estimate(text)
      (text.to_s.length / 4.0).ceil
    end
  end
end
```

Assinatura exata de D8: `Harness::TokenEstimator.estimate(text) -> Integer`. `to_s` cobre `nil` (→ 0) sem exceção.

#### Step 5: Entry point e esqueleto de specs

**File:** `lib/harness.rb`

**Reference pattern from codebase** (Fase 0 — `docs/harness_handoff/reference-implementation/lib/agent_runtime.rb`):

```ruby
# frozen_string_literal: true

require_relative "agent_runtime/event"
require_relative "agent_runtime/skill_catalog"
...
module AgentRuntime
end
```

Versão Fase 1 (só com o que existe até esta task; tasks seguintes acrescentam linhas):

```ruby
# frozen_string_literal: true

require_relative "harness/errors"
require_relative "harness/event"
require_relative "harness/agent_profile"
require_relative "harness/token_estimator"

module Harness
end
```

Zero side-effects no load (00-overview §3) e **nenhum** `require "ruby_llm"` (regra de testabilidade, D9/handoff §6).

**File:** `spec/spec_helper.rb`

```ruby
# frozen_string_literal: true

require_relative "../lib/harness"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
```

**File:** `.rspec`

```
--require spec_helper
--format documentation
```

**File:** `Gemfile` (mínimo — a pinagem completa de D9 é a task 26):

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

group :development, :test do
  gem "rspec", "~> 3.13"
end
```

### Edge Cases to Handle

1. **`Event` sem `meta`** — `Event.new(type: :done, data: { content: "x" })` deve funcionar (default `{}`), e `to_h` deve incluir `meta: {}`. É o caminho de compatibilidade dos call sites migrados do `runner.rb` (task 11).
2. **`meta` com nils** — `meta: { task_id: "t1", session_id: nil, seq: 1, at: nil }` → `to_h` retorna `meta: { task_id: "t1", seq: 1 }` (`compact`).
3. **Colisão de chave `type`/`meta` em `data`** — não trate; o catálogo D5 é fechado e nenhum tipo tem `data` com essas chaves. Não adicione guard.
4. **`Harness::TimeoutError` vs `::Timeout::Error` da stdlib** — nomes distintos, mas dentro do módulo `Harness` a constante local sombreia; sempre referencie sem `::` dentro do namespace e documente no comentário (D4 proíbe `Timeout.timeout` de stdlib de qualquer forma).
5. **`AgentProfile.build` com `limits` parcial** — `limits: { turn_timeout: 60 }` deve resultar em merge (demais chaves de `DEFAULT_LIMITS` presentes), nunca substituição total.
6. **`tools_deny`/`policies`/`prompt_refs` como valor único** — `Array()` normaliza (padrão da Fase 0 para `prompt_files`/`tools_deny`).
7. **`TokenEstimator.estimate(nil)` e `("")`** — retornam `0`, nunca exceção.

## Testing

### Unit Tests

**File:** `spec/harness/errors_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| hierarquia | cada uma das 8 classes `< Harness::Error < StandardError` | `be < Harness::Error` para todas |
| PolicyDenied attrs | `PolicyDenied.new(policy: "x", reason: "y")` | `#policy == "x"`, `#reason == "y"`, message default contém ambos |
| ContextError attrs | `ContextError.new(provider: "session")` | `#provider == "session"` |
| TimeoutError attrs | `TimeoutError.new(stage: :turn)` | `#stage == :turn` |
| mensagem explícita | `PolicyDenied.new("msg", policy: "x")` | `#message == "msg"` |

**File:** `spec/harness/event_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| compat Fase 0 — construção | `Event.new(type: :content, data: { delta: "oi" })` sem meta | não levanta; `meta == {}` |
| compat Fase 0 — to_h plano | `to_h` de `:done` com `data: { content: "oi" }` | `{ type: :done, content: "oi", meta: {} }` — mesmas chaves planas da Fase 0 + `meta` aditivo |
| compat Fase 0 — todos os tipos legados | `:skill_activated`, `:tool_call`, `:tool_result`, `:content`, `:done`, `:error` | `to_h[:type]` e chaves de `data` planas no topo, como no `to_h` da Fase 0 (`{ type: type }.merge(data)`) |
| meta com correlação | `meta: { task_id: "t1", seq: 3, at: "..." }` | `to_h[:meta] == { task_id: "t1", seq: 3, at: "..." }` |
| meta.compact | meta com valores nil | nils ausentes de `to_h[:meta]` |
| imutabilidade | `Data` congela | `event.frozen?` é true; sem setters |

**File:** `spec/harness/agent_profile_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| compat Fase 0 — build mínimo | `AgentProfile.build(id: "a", model: "m")` (assinatura da Fase 0) | não levanta; campos Fase 0 com os mesmos defaults de antes |
| defaults novos | build mínimo | `context_providers: nil`, `workflows_allow: nil`, `policies: []`, `prompt_refs: []`, `limits == DEFAULT_LIMITS` |
| limits merge parcial | `limits: { turn_timeout: 60 }` | `limits[:turn_timeout] == 60` e `limits[:tool_timeout] == 60`, `limits[:context_budget] == 8_000` etc. (merge, não substituição) |
| valores de DEFAULT_LIMITS | conferir contra D6 | `{ turn_timeout: 300, tool_timeout: 60, provider_timeout: 5, context_budget: 8_000, max_turns: 25, max_tool_calls: 50 }` |
| tool_opted_in? preservado | `tools_allow: ["a"]` | `tool_opted_in?("a")` true; `tool_opted_in?("b")` false; com `tools_allow: nil` → false |
| normalização Array() | `tools_deny: "x"`, `policies: "p"`, `prompt_refs: "r"` | viram `["x"]`, `["p"]`, `["r"]` |

**File:** `spec/harness/token_estimator_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| heurística /4 | `estimate("a" * 400)` | `100` |
| ceil | `estimate("abc")` (3 chars) | `1` |
| string vazia | `estimate("")` | `0` |
| nil | `estimate(nil)` | `0` |
| retorno Integer | qualquer entrada | `be_a(Integer)` |

### Integration Tests (if applicable)

Não aplicável — tipos puros sem colaboradores. O teste de integração relevante (Event no wire SSE) pertence à task 24.

## Definition of Done

- [ ] Os 4 arquivos de `lib/harness/` criados com o conteúdo especificado; `lib/harness.rb` carrega tudo sem side-effects
- [ ] `to_h` do `Event` compatível com a Fase 0 (chaves de `data` planas + `meta` aditivo) — testes de compatibilidade verdes
- [ ] `AgentProfile.build` aceita a assinatura da Fase 0 inalterada (novos campos todos com default)
- [ ] Taxonomia de erros idêntica a D4 (nem mais nem menos classes; attr_readers presentes)
- [ ] `TokenEstimator.estimate` conforme D8
- [ ] Suíte roda **sem ruby_llm instalado** e sem chave de API (`bundle exec rspec` verde com o Gemfile mínimo)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Lacuna registrada (Gemfile):** o techspec só especifica o Gemfile pinado na task 26 (D9), mas rodar a suíte desde a task 1 exige ao menos `rspec`. Esta task cria um Gemfile mínimo (só grupo test); a task 26 o substitui pela versão final pinada + `Gemfile.lock` commitado. Não adicione `ruby_llm`/`async`/`sqlite3` aqui — `async` e `sqlite3` entram na task 4, quando forem de fato usados.
- Os arquivos da Fase 0 em `docs/harness_handoff/reference-implementation/` **não são apagados** — são documentação de referência do handoff. A "migração" é criação dos equivalentes em `lib/harness/` (00-overview §4: nada da Fase 0 é jogado fora).
- Requer Ruby ≥ 3.2 (`Data.define` com override de `initialize` por keywords). A Fase 0 já usa `Data.define`.
- Convenções (brief/Fase 0): `# frozen_string_literal: true` no topo, `Data.define` para value objects, comentários em português, classes pequenas.

---

## Conclusão

- **Concluído em:** 2026-07-06
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 32 novos, 0 existentes, 0 falhas (`bundle exec rspec` verde, sem ruby_llm instalado)
- **Arquivos criados:** `lib/harness.rb`, `lib/harness/{errors,event,agent_profile,token_estimator}.rb`, `spec/spec_helper.rb`, `.rspec`, `spec/harness/{errors,event,agent_profile,token_estimator}_spec.rb`, `Gemfile`, `Gemfile.lock`, `.gitignore`
- **Arquivos modificados:** nenhum (primeiro código do repo)
- **Observações:**
  - Repositório git inicializado nesta task (não existia); baseline `main` com os docs, trabalho em `feature/harness-fase1` (sem `staging`/remote ainda — adaptação registrada).
  - **Desvio pequeno do plano:** `DEFAULT_LIMITS` não pode ser atribuída dentro do bloco do `Data.define` — constante em bloco vaza para o escopo léxico (`Harness::DEFAULT_LIMITS`). Solução: classe `AgentProfile` reaberta após o `Data.define` para hospedar a constante e os métodos. Comportamento e interface idênticos aos planejados; as tasks 2+ que citarem o padrão "métodos no bloco do Data.define" devem preferir reabertura quando houver constante.
  - Verificado load limpo: `require "harness"` não define side-effects nem carrega `ruby_llm`.
