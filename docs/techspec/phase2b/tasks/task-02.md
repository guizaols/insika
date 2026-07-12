# Task 02 (P2B): Erros de capability + `Capability::ResolvedTool`

> **Techspec:** [P2B-01-capability-registry.md](../P2B-01-capability-registry.md) (D4, L7) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo
Fechar duas peças de suporte da resolução de capability que NÃO dependem do
`CapabilityRegistry` em si (task 1) e por isso podem nascer em paralelo:

1. Estender a taxonomia única de erros (`00-overview` D4 da Fase 1) com o
   estágio `:capability` — `CapabilityUnavailable` (0 candidatos) e
   `CapabilityAmbiguous` (≥2 empatados no topo), ambas subclasses de uma base
   `CapabilityError`. Sem isso a task 1 (resolução) e a task 5 (integração no
   Executor) não têm o que levantar/capturar.
2. Criar `Harness::Capability::ResolvedTool`, o decorator fino que troca só o
   `name` exposto ao modelo pelo nome ESTÁVEL da capability (D4/L7 do
   P2B-01) — a peça que a task 5 usa em `configure_chat` para embrulhar a tool
   resolvida ANTES do `ToolEnvelope`.

## Dependências
Nenhuma — pode começar já.

## Contexto
A Fase 1 fixou uma taxonomia única de erros (`lib/harness/errors.rb`,
comentário de topo: "erro vira evento, task tem estado terminal explícito,
checkpoint nunca é corrompido"). Cada subárvore de erro já carrega os dados
necessários para auditoria via `attr_reader` (ex.: `PolicyDenied#policy/reason`,
`ContextError#provider`, `TimeoutError#stage`) e é capturada no topo do fiber
do Executor, virando evento (`:error`/`:task_failed`) com o estágio certo.

O overview da fatia B (D7) é explícito: `CapabilityUnavailable`/
`CapabilityAmbiguous` **não ganham evento próprio** — propagam como erro de
estágio `:capability` (`CapabilityError`), reaproveitando os eventos
`:error`/`:task_failed` já existentes. Ou seja, esta task só cria as CLASSES;
o `rescue CapabilityError` no Executor (espelhando o `rescue ContextError` já
existente) é responsabilidade da task 5 — aqui não se toca `executor.rb`.

O segundo pedaço é o decorator `Capability::ResolvedTool`. A P2B-01 (D4) exige
que o agente veja a capability sob um nome ESTÁVEL (`browse`), independente de
qual implementação concreta (`impl_name`, ex. `"puppeteer_browser"`) resolveu —
isso é o que permite ao agente/skill referenciar `browse` de forma consistente
enquanto plugins trocam de implementação por trás. O padrão já existe no
código: `ToolEnvelope < SimpleDelegator` (`lib/harness/tool_envelope.rb`)
envolve a tool real e delega tudo, só adicionando comportamento por fora
(timeout/side-effect/approval) sem reimplementar `name`/`description`/
`execute`. `ResolvedTool` é o MESMO padrão, mas na direção oposta: ele
**substitui** um único método (`name`) e deixa todo o resto (inclusive o
`call`/`execute` que o RubyLLM invoca) fluir por `method_missing` do
`SimpleDelegator` direto para o impl — não há necessidade de redefinir
`execute`/`parameters`/`description` explicitamente, exatamente como o
`ToolEnvelope` não redefine `name`/`description`.

A ordem de embrulho definida pela L7 é **impl → ResolvedTool → ToolEnvelope**:
o Envelope por fora enxerga a call já renomeada (o modelo chama `browse`), mas
para decidir `side_effect?`/`approval_required?` ele precisa do `impl_name`
real (é o `tool_registry` que sabe se `"puppeteer_browser"` é side-effect, não
`"browse"`). Por isso `ResolvedTool` expõe `impl_name` — quem vai *consumir*
esse método ajustando `ToolEnvelope#side_effect?`/`#approval_required?`/
`#correlation_id` é a **task 5** (Executor); aqui só criamos e testamos o
decorator isoladamente.

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| MODIFY | `lib/harness/errors.rb` | + `CapabilityError`, `CapabilityUnavailable`, `CapabilityAmbiguous` |
| CREATE | `lib/harness/capability/resolved_tool.rb` | `Harness::Capability::ResolvedTool < SimpleDelegator` |
| MODIFY | `lib/harness.rb` | `require_relative "harness/capability/resolved_tool"` |
| MODIFY | `spec/harness/errors_spec.rb` | estende hierarquia + describes dos 2 novos erros |
| CREATE | `spec/harness/capability/resolved_tool_spec.rb` | contrato do decorator |

## Passo a passo

### Passo 1 — `CapabilityError` + `CapabilityUnavailable` + `CapabilityAmbiguous`

Adicionar ao final de `lib/harness/errors.rb`, seguindo a MESMA forma de
`PolicyDenied`/`ContextError`/`TimeoutError` (mensagem default construída dos
atributos, mas aceitando mensagem explícita como primeiro posicional).

**Padrão de referência (codebase, `lib/harness/errors.rb:23-31` e `:37-47`):**
```ruby
# provider required falhou -> task :failed
class ContextError < Error
  attr_reader :provider

  def initialize(message = nil, provider: nil)
    @provider = provider
    super(message || "provider #{provider} falhou")
  end
end

# Estouro de timeout de estágio. Dentro do namespace Harness a constante
# sombreia ::Timeout::Error da stdlib — referencie sem :: aqui dentro
# (D4 proíbe Timeout.timeout de stdlib de qualquer forma).
class TimeoutError < Error
  attr_reader :stage

  def initialize(message = nil, stage: nil)
    @stage = stage
    super(message || "timeout no estágio #{stage}")
  end
end
```

Novo bloco a acrescentar (mesmo estilo, estágio `:capability` — P2B overview
D7; NÃO ganha evento próprio, propaga pelos eventos `:error`/`:task_failed`
existentes):
```ruby
# Resolução de capability falhou (RFC-0004 §5, P2B-01 D2) -> task :failed no
# estágio :capability. Base da subárvore; NÃO ganha evento próprio (P2B
# overview D7) — propaga pelos eventos :error/:task_failed já existentes,
# mesma disciplina da taxonomia D4 da Fase 1.
class CapabilityError < Error; end

# 0 candidatos sobraram após disponibilidade + allow/deny da Policy
# (P2B-01 D2 passo 5).
class CapabilityUnavailable < CapabilityError
  attr_reader :capability

  def initialize(message = nil, capability: nil)
    @capability = capability
    super(message || "capability #{capability} sem provider disponível")
  end
end

# >=2 candidatos empatados no topo (mesma priority E mesma precedência de
# plugin) -> erro de configuração, NUNCA escolha silenciosa (P2B-01 D2/L4).
# `candidates` carrega o suficiente para o operador desempatar no manifesto
# (nomes + plugins + priorities — o formato exato é decidido pela task 1,
# que é quem monta a lista a partir dos Providers).
class CapabilityAmbiguous < CapabilityError
  attr_reader :capability, :candidates

  def initialize(message = nil, capability: nil, candidates: [])
    @capability = capability
    @candidates = candidates
    super(message || "capability #{capability} ambígua entre #{candidates.inspect}")
  end
end
```

Pontos de atenção:
- `CapabilityError` em si fica igual a `ProviderError`/`StoreError` (linha
  vazia, só herda) — nunca é levantada diretamente, só as duas subclasses.
- `candidates:` default `[]` (evita `NoMethodError` se alguém instanciar sem
  o kwarg em teste isolado) — mas na prática quem levanta (task 1) SEMPRE
  populará com os candidatos reais.
- Não adicionar `rescue`/integração com `executor.rb` aqui — é escopo da
  task 5 (dependência explícita: 1, 2, 3, 4).

### Passo 2 — `Capability::ResolvedTool`

Criar `lib/harness/capability/resolved_tool.rb`.

**Padrão de referência (codebase, `lib/harness/tool_envelope.rb:1-30`):**
```ruby
require "async"
require "delegate"

module Harness
  # Envolve cada tool permitida (doc 03 §5, doc 02 §2-§3): timeout por call (D4)
  # + registro de side-effect não-idempotente ANTES de o resultado voltar ao
  # modelo. Delega todo o resto (name/description/params) à tool real.
  #
  # O loop de tools é do RubyLLM; este é um decorator sobre as instâncias — o
  # Executor nunca dirige roundtrips.
  class ToolEnvelope < SimpleDelegator
    ...
    def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:,
                   skip_side_effects: [])
      super(tool)
      @state = state
      ...
    end
```

Note: `ToolEnvelope` só requer `"delegate"` (stdlib) + `"async"` (porque usa
`Async::Task.current.with_timeout`). `ResolvedTool` não precisa de `async` —
só `"delegate"`.

Implementação:
```ruby
# frozen_string_literal: true

require "delegate"

module Harness
  module Capability
    # Decorator fino (P2B-01 D4/L7): troca só o `name` exposto ao modelo pelo
    # nome ESTÁVEL da capability (ex. "browse"), independente de qual impl
    # concreta (`impl_name`, ex. "puppeteer_browser") a resolução escolheu.
    # `execute`/`parameters`/`description`/`call` continuam delegando ao impl
    # via SimpleDelegator — nada reimplementado, mesmo espírito do
    # `ToolEnvelope` (que também só adiciona comportamento por fora sem
    # reimplementar o que já delega).
    #
    # Ordem de embrulho em configure_chat (P2B-01 L7): impl -> ResolvedTool ->
    # ToolEnvelope. O Envelope, por fora, enxerga a call já renomeada (o
    # modelo chama `browse`); para side_effect?/approval ele precisa do
    # impl_name REAL (é o tool_registry quem sabe se "puppeteer_browser" é
    # side-effect, não "browse") — por isso `impl_name` fica exposto aqui.
    # Quem consome isso ajustando o ToolEnvelope é a task 5 (Executor); este
    # decorator só expõe o dado.
    class ResolvedTool < SimpleDelegator
      def initialize(impl, capability_name:, impl_name:)
        super(impl)
        @capability_name = capability_name.to_s
        @impl_name = impl_name.to_s
      end

      # Nome ESTÁVEL exposto ao modelo (D4) — sombreia o `name` do impl.
      def name = @capability_name

      # Nome concreto por trás da resolução — p/ side_effect?/approval no
      # ToolEnvelope (task 5), NUNCA exposto ao modelo.
      def impl_name = @impl_name
    end
  end
end
```

### Passo 3 — `require` em `lib/harness.rb`

`lib/harness.rb` é o composition-root de requires e tem uma regra explícita
(comentário no fim do arquivo): **não** requerer nada que puxe `ruby_llm` em
load-time (por isso `harness/tools/load_skill` fica de fora, carregado lazy
pelo Executor). `SimpleDelegator`/`"delegate"` é stdlib puro — `ResolvedTool`
não viola essa regra e pode ser requerido normalmente no topo, junto dos
outros decorators.

Inserir a linha logo ANTES de `require_relative "harness/tool_envelope"`
(mesma família de decorator `SimpleDelegator`):
```ruby
require_relative "harness/turn_state"
require_relative "harness/capability/resolved_tool"
require_relative "harness/tool_envelope"
require_relative "harness/executor"
```

Não é necessário requerer `harness/capability_registry` aqui (isso é escopo
da task 1) — `ResolvedTool` não referencia `CapabilityRegistry`, é um
decorator autocontido.

## Edge cases

- **Impl sem `description`/`parameters`** (tool "crua", sem DSL do
  `RubyLLM::Tool`): `ResolvedTool` não valida nem levanta nada — o
  `method_missing` do `SimpleDelegator` simplesmente propaga o
  `NoMethodError` do impl, se houver. Não é responsabilidade do decorator
  suprir isso.
- **`impl_name` sempre preservado, mesmo com múltiplos embrulhos**: como
  `ResolvedTool` guarda `@impl_name` num ivar próprio (não delega essa
  leitura), ele sobrevive a qualquer wrapping adicional por fora
  (`ToolEnvelope`) — é exatamente o dado que a task 5 precisa para consultar
  o `tool_registry` pelo nome REAL.
- **`name` chamado duas vezes por camadas diferentes**: `ResolvedTool#name`
  sempre devolve a capability; se o `ToolEnvelope` (task 5, futura mudança)
  precisar do nome do impl para lookups internos, deve usar
  `impl_name`, nunca assumir que `__getobj__.name` (uma camada abaixo) ainda
  é o nome do impl bruto — se `__getobj__` for outro `ResolvedTool`
  aninhado (não deveria acontecer no fluxo real, mas o decorator não impede),
  `__getobj__.name` devolveria a capability de novo, não o impl. Fora de
  escopo desta task resolver aninhamento — só documentar a armadilha.
- **Erros carregam dados para auditoria, não só mensagem**: tanto
  `CapabilityUnavailable#capability` quanto
  `CapabilityAmbiguous#capability/#candidates` precisam estar acessíveis via
  `attr_reader` (não só embutidos na string de `message`) — é o que permite
  ao evento `:error`/`:task_failed` (ou a um `rescue` futuro mais granular)
  inspecionar estruturadamente o que faltou, igual `PolicyDenied#policy/reason`
  já faz hoje.
- **`candidates:` vazio por omissão**: se algum caller futuro esquecer de
  passar `candidates:`, o erro ainda é instanciável (default `[]`) em vez de
  estourar `ArgumentError` — evita que um bug na task 1 (esquecer de montar a
  lista) derrube o turno com um erro DIFERENTE do que se pretendia relatar.

## Testes

**Arquivo:** `spec/harness/errors_spec.rb` (estende) +
`spec/harness/capability/resolved_tool_spec.rb` (novo)

| # | Cenário | Arquivo | Asserção |
|---|---|---|---|
| 1 | `CapabilityError`, `CapabilityUnavailable`, `CapabilityAmbiguous` entram na lista de hierarquia | `errors_spec.rb` | cada uma `be < Harness::Error`; `CapabilityUnavailable`/`Ambiguous` também `be < Harness::CapabilityError` |
| 2 | `CapabilityUnavailable.new(capability: "browse")` | `errors_spec.rb` | `#capability == "browse"`; `#message` inclui `"browse"` |
| 3 | `CapabilityUnavailable.new("msg custom", capability: "browse")` | `errors_spec.rb` | `#message == "msg custom"` (mensagem explícita vence o default) |
| 4 | `CapabilityAmbiguous.new(capability: "browse", candidates: [...])` | `errors_spec.rb` | `#capability == "browse"`; `#candidates == [...]`; `#message` menciona a capability |
| 5 | `CapabilityAmbiguous.new` sem `candidates:` | `errors_spec.rb` | não levanta `ArgumentError`; `#candidates == []` |
| 6 | tool fake com `name`/`description`/`execute` + `ResolvedTool.new(tool, capability_name: "browse", impl_name: "puppeteer_browser")` | `resolved_tool_spec.rb` | `#name == "browse"` (não o do impl) |
| 7 | mesmo setup | `resolved_tool_spec.rb` | `#impl_name == "puppeteer_browser"` |
| 8 | mesmo setup, chama `#execute(url: "x")` | `resolved_tool_spec.rb` | delega ao impl e devolve o resultado do impl (impl real chamado, args intactos) |
| 9 | mesmo setup, `#description`/`#call` | `resolved_tool_spec.rb` | delegam ao impl sem alteração (paridade com o padrão do `ToolEnvelope`) |
| 10 | impl `nil` acidental (`ResolvedTool.new(nil, ...)`) | `resolved_tool_spec.rb` | qualquer chamada delegada levanta erro do próprio `SimpleDelegator`/impl (não um erro silencioso do decorator) — smoke de que não há guard escondido |

Fake tool para o passo 6-9 (mesmo espírito do `ChargeTool` em
`spec/harness/tool_envelope_approval_spec.rb:14-20`):
```ruby
class FakeBrowseTool
  attr_reader :calls

  def initialize = (@calls = [])
  def name = "puppeteer_browser"
  def description = "abre uma página"
  def execute(url:) = (@calls << url) && "ok:#{url}"
  def call(args) = execute(**args)
end
```

## Definition of Done

- [ ] `CapabilityError`/`CapabilityUnavailable`/`CapabilityAmbiguous` em
      `lib/harness/errors.rb`, seguindo o estilo existente (mensagem default +
      `attr_reader` para auditoria)
- [ ] `Harness::Capability::ResolvedTool` criado em
      `lib/harness/capability/resolved_tool.rb`, `< SimpleDelegator`, só
      `name`/`impl_name` redefinidos
- [ ] `require_relative "harness/capability/resolved_tool"` em `lib/harness.rb`
      (sem puxar `ruby_llm`)
- [ ] `spec/harness/errors_spec.rb` estendido + `spec/harness/capability/resolved_tool_spec.rb` criado, cobrindo a tabela de testes acima
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task é deliberadamente estreita: NÃO cria `lib/harness/capability_registry.rb`
  (task 1), NÃO mexe em `agent_profile.rb` (task 3), NÃO mexe em
  `plugin/loader.rb` (task 4) e NÃO integra nada em `executor.rb` (task 5) —
  inclusive o ajuste de `ToolEnvelope#side_effect?`/`#approval_required?` para
  consultar `impl_name` em vez de `name` quando a tool vier de uma capability
  fica para a task 5, que é quem tem o contexto completo de `configure_chat`.
- Diretórios novos: `lib/harness/capability/` e `spec/harness/capability/` —
  confirmar que existem/são criados junto com os arquivos (sem `.rspec`/config
  adicional; o glob padrão do RSpec já cobre subdiretórios de `spec/`).
- Consistência de namespace (fiel à P2B-01 §Interfaces): `CapabilityRegistry`
  fica em `Harness::CapabilityRegistry` (top-level, arquivo
  `lib/harness/capability_registry.rb`, task 1), enquanto `ResolvedTool` fica
  namespaced em `Harness::Capability::ResolvedTool` (arquivo dentro de
  `lib/harness/capability/`). A assimetria é do próprio techspec, não um erro
  desta task — não "corrigir" renomeando nada.
