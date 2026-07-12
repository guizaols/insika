# Task 01 (P2B): CapabilityRegistry + resolução determinística

> **Techspec:** [P2B-01-capability-registry.md](../P2B-01-capability-registry.md) (L1, L2, L3, L4) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** A

## Objetivo
Criar o `CapabilityRegistry` — indireção pura (RFC-0004 §2, L1) que guarda
`Provider`s por capability e resolve determinística e auditavelmente **qual**
`impl_name` atende uma intenção (`:browse`), sem executar nada.

## Dependências
Nenhuma — pode começar já (Task 2 fornece as classes `CapabilityUnavailable`/
`CapabilityAmbiguous` definitivas em `errors.rb`; ver Notas para a estratégia de
acoplamento).

## Contexto
RFC-0002 §7 define a pipeline de montagem de tools como `Context → Capability →
Policy`: o Context já sabe quais capabilities o perfil pediu; a Capability
resolve cada uma para um `impl_name` concreto; a Policy (estágio 3, já
existente) roda de novo sobre esse `impl_name` para a checagem final. Este task
entrega só o núcleo puro de resolução — sem tocar `Executor`, `AgentProfile` ou
`PluginLoader` (isso é Task 3, 4 e 5). `CapabilityRegistry` **não** herda de
`Registry` (`lib/harness/registry.rb`): `Registry` guarda conteúdo executável
(factories); capability é metadado de resolução — o `resolve` devolve um
`Provider` (contém `impl_name`), que OUTRO registry (`ToolRegistry`/
`WorkflowRegistry`) de fato instancia. Este task habilita diretamente:
- **Task 4** (ativação de `contracts.capabilities` no `PluginLoader`): o
  `register_capability` da `StagingApi` vai chamar `CapabilityRegistry#register`.
- **Task 5** (capability assembly no `Executor`): vai chamar `#resolve` por
  capability do perfil, ANTES do `policy_request`, e capturar
  `CapabilityUnavailable`/`CapabilityAmbiguous` como `CapabilityError` de estágio
  `:capability`.

## Arquivos
| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `lib/harness/capability_registry.rb` | `Provider` (Data.define) + `CapabilityRegistry` (register/providers/capabilities/deregister_plugin/resolve) |
| MODIFY | `lib/harness.rb` | `require_relative "harness/capability_registry"` |
| CREATE | `spec/harness/capability_registry_spec.rb` | Suíte pura (sem `ruby_llm`) |

## Passo a passo

### Passo 1: `Provider` + guarda de erros forward (acoplamento com Task 2)
**Arquivo:** `lib/harness/capability_registry.rb`

Comece o arquivo com `# frozen_string_literal: true` e `module Harness`. Defina
`Provider = Data.define(:capability, :impl_name, :kind, :plugin, :priority,
:available)` dentro de `CapabilityRegistry` (mesmo padrão do `Entry` do
`Registry`). `available` é sempre um callable (`-> { true }` por default,
resolvido no `register`, nunca `nil` dentro de um `Provider` já registrado).

Logo abaixo do `module Harness`, ANTES da classe, adicione um guarda de
compatibilidade para `CapabilityUnavailable`/`CapabilityAmbiguous` — essas
classes são o escopo canônico da **Task 2** (`errors.rb`), mas este task já
precisa levantá-las. Use `defined?` para não colidir quando a Task 2 já tiver
rodado (ver Notas):

```ruby
module Harness
  # Stub temporário — Task 2 define as classes definitivas em errors.rb
  # (carregado ANTES deste arquivo em lib/harness.rb). Se já existirem, este
  # bloco é pulado: nada a fazer quando a Task 2 chegar.
  unless defined?(Harness::CapabilityUnavailable)
    class CapabilityError < Error; end

    class CapabilityUnavailable < CapabilityError
      def initialize(capability:)
        super("capability '#{capability}' sem provider disponível")
      end
    end

    class CapabilityAmbiguous < CapabilityError
      attr_reader :candidates

      def initialize(capability:, candidates:)
        @candidates = candidates
        super("capability '#{capability}' ambígua entre #{candidates.size} candidatos")
      end
    end
  end
end
```

**Padrão de referência (codebase — taxonomia de erro por estágio, `errors.rb`):**
```ruby
class ContextError < Error
  attr_reader :provider

  def initialize(message = nil, provider: nil)
    @provider = provider
    super(message || "provider #{provider} falhou")
  end
end
```

### Passo 2: `register`
**Arquivo:** `lib/harness/capability_registry.rb`

```ruby
def initialize
  @providers = Hash.new { |h, k| h[k] = [] } # capability(Symbol) -> [Provider], ordem de registro
end

def register(capability, impl_name:, kind:, plugin: nil, priority: nil, available: nil)
  unless %i[tool workflow].include?(kind)
    raise ArgumentError, "kind inválido: #{kind.inspect} (use :tool ou :workflow)"
  end

  warn "[capability_registry] '#{capability}' registrada com kind: :workflow — " \
       "exposição ao agente adiada (L5)" if kind == :workflow

  @providers[capability.to_sym] << Provider.new(
    capability: capability.to_sym, impl_name: impl_name.to_s, kind: kind,
    plugin: plugin&.to_s, priority: priority, available: available || -> { true }
  )
  self
end
```

Ao contrário do `Registry#register`, **não há "primeiro vence"**: registrar
duas vezes a mesma capability é o caso normal (múltiplos providers concorrendo
pela resolução) — a deduplicação/desempate acontece no `resolve`, não aqui.

**Padrão de referência (codebase — `register` do `Registry`, contraste no comentário acima):**
```ruby
def register(name, callable = nil, plugin: nil, **metadata, &block)
  name = name.to_s
  factory = block || (callable.nil? ? nil : -> { callable })
  raise ArgumentError, "registro sem factory: #{name}" if factory.nil?

  if @entries.key?(name)
    existing = @entries[name]
    warn "[registry] '#{name}' já registrada por #{existing.plugin.inspect}; " \
         "descartando registro de #{plugin.inspect} (primeiro vence)"
    return self
  end
  @entries[name] = Entry.new(name: name, plugin: plugin&.to_s, metadata: metadata, factory: factory)
  self
end
```

### Passo 3: `providers`, `capabilities`, `deregister_plugin`
**Arquivo:** `lib/harness/capability_registry.rb`

```ruby
def providers(capability) = @providers[capability.to_sym].dup

def capabilities = @providers.keys

# Rollback do Loader (L6), simétrico ao Registry#deregister_plugin. Remove só
# os Providers do plugin; capabilities sem NENHUM provider restante somem de
# `capabilities` (o Hash.new-com-bloco recria a entry vazia se reconsultada,
# então limpe a chave também quando ficar vazia).
def deregister_plugin(plugin_id)
  @providers.each_value { |list| list.delete_if { |p| p.plugin == plugin_id.to_s } }
  @providers.delete_if { |_cap, list| list.empty? }
  nil
end
```

### Passo 4: `resolve` — filtro de disponibilidade e de deny (o grant fica fora daqui)
**Arquivo:** `lib/harness/capability_registry.rb`

```ruby
def resolve(capability, profile:, context: {}, event_stream: nil)
  candidates = providers(capability)
  candidates = candidates.select { |p| p.available.call }
  candidates = apply_deny(candidates, profile)

  raise CapabilityUnavailable.new(capability: capability) if candidates.empty?

  chosen = pick_top(candidates, capability)
  event_stream&.emit(Harness::Event.new(
                        type: :capability_resolved,
                        data: {
                          capability: capability.to_sym,
                          chosen: chosen.impl_name,
                          candidates: candidates.map { |p| { impl_name: p.impl_name, plugin: p.plugin, priority: p.priority } }
                        }
                      ))
  chosen
end

private

# Resolução aplica SÓ `tools_deny` sobre `impl_name` (deny SEMPRE vence) — NÃO
# aplica `tools_allow` (L3/D3 do overview): o grant para usar a capability é
# listá-la em `profile.capabilities`, conferido pelo Executor (Task 5) ANTES de
# chamar `resolve`, não aqui. Reusar `tools_allow` faria um agente que lista só
# a capability (não o impl cru) ter o provider filtrado para fora — ver L3 na
# tech spec pro raciocínio completo. Pinning por-agente de provider
# (`capability_providers`) é evolução (RFC-0004 §8).
def apply_deny(candidates, profile)
  deny = Array(profile.tools_deny).map(&:to_s)
  candidates.reject { |p| deny.include?(p.impl_name) }
end
```

**Padrão de referência (codebase — `Policy::Builtin::ToolAllowlist`; aqui só a metade `deny` se aplica — ver Nota abaixo):**
```ruby
class ToolAllowlist < Base
  def decide(request)
    profile = request.profile
    deny = request.candidate_tools
           .select { |e| e.metadata[:optional] && !profile.tool_opted_in?(e.name) }
           .map { |e| e.name.to_s }
    deny += Array(profile.tools_deny).map(&:to_s)

    allow = profile.tools_allow.nil? ? nil : Array(profile.tools_allow).map(&:to_s)
    Decision.allow(allow_tools: allow, deny_tools: deny.uniq)
  end
end
```
> Nota: essa classe pertence à Policy (estágio 3) e filtra TOOLS DIRETAS pelo
> par allow/deny completo — não é o `resolve` de capability. Aqui reaplicamos
> só a parte `deny` (`optional`/`tool_opted_in?` é metadado de
> `ToolRegistry::Entry`, não existe em `Provider`); `tools_allow` **não entra**
> — ver L3/D3. A `ToolAllowlist` continua rodando depois sobre o `impl_name` já
> resolvido, mas as tools de capability são juntadas ao tool set DEPOIS do
> estágio 3 (Task 5), então essa `tools_allow` (quando não-nil) não as filtra
> de novo.

### Passo 5: `resolve` — ordenação, desempate por precedência de plugin, ambiguidade
**Arquivo:** `lib/harness/capability_registry.rb`

Ordenação: `priority` desc como chave primária, com `nil` tratado como o valor
**mais baixo possível** — abaixo de qualquer inteiro, inclusive negativo (D5;
**não** normalizar `nil` para `0`, que colidiria com um `priority: 0`
explícito). Desempate por precedência de **plugin** (RFC-0003 §5): entre
candidatos de plugins **diferentes** — `nil` conta como mais um valor de
plugin, tanto quanto `"a"` ou `"b"` — o registrado primeiro (menor índice em
`providers(capability)`) vence, sem ambiguidade. Dois candidatos que
compartilham o **mesmo** `plugin` (inclusive quando ambos são `plugin: nil` —
nenhum dos dois tem precedência de anúncio a invocar contra o outro) empatados
em priority não têm desempate possível → `CapabilityAmbiguous` (L4: "priority
idêntica E mesmo plugin no topo").

```ruby
def pick_top(candidates, capability)
  indexed = providers(capability).each_with_index.to_h { |p, i| [p, i] }

  # nil sempre perde para qualquer Integer (positivo, zero ou negativo): o
  # rank é [0, _] pra nil e [1, priority] pra inteiro — arrays Ruby comparam
  # posição a posição, então [0, *] < [1, *] sempre, sem colidir com
  # priority: 0 explícito.
  rank = ->(p) { p.priority.nil? ? [0, 0] : [1, p.priority] }
  top_rank = candidates.map(&rank).max
  top = candidates.select { |p| rank.call(p) == top_rank }

  return top.first if top.size == 1

  # Mesmo `plugin` (nil incluso) = sem precedência entre si -> Ambiguous se
  # sobrar >1 no mesmo grupo. Plugins diferentes SEMPRE desempatam por ordem
  # de registro (proxy de announce, RFC-0003 §5) -> nunca ambíguo.
  groups = top.group_by(&:plugin).values
  raise CapabilityAmbiguous.new(capability: capability, candidates: top) if groups.any? { |g| g.size > 1 }

  groups.min_by { |g| indexed[g.first] }.first
end
```

## Edge cases
1. Empate de `priority` entre providers de **plugins diferentes** (inclusive
   quando um dos dois é `plugin: nil` e o outro não — `nil` também conta como
   "um plugin diferente" de qualquer plugin nomeado) → desempate pela ordem de
   registro (proxy da ordem de anúncio dos plugins, RFC-0003 §5): o primeiro
   registrado vence, silenciosamente (não é ambiguidade).
2. Empate de `priority` entre providers do **mesmo `plugin`** — inclusive
   quando **ambos** têm `plugin: nil` (nenhum dos dois tem precedência de
   plugin a invocar contra o outro) → `CapabilityAmbiguous` (L4).
3. `available.call == false` → candidato descartado ANTES do desempate e ANTES
   do deny; se isso zera o conjunto → `CapabilityUnavailable`.
4. `tools_deny` do perfil sobre o `impl_name` do candidato → sempre remove,
   mesmo que fosse o único/topo (pode levar a `CapabilityUnavailable`); deny
   é o ÚNICO filtro de política aplicado pelo `resolve` (D3/L3).
5. `tools_allow` do perfil **não filtra candidatos** — o `resolve` ignora esse
   campo por completo (D3/L3): o grant é `profile.capabilities`, conferido
   fora do `resolve` (Task 5, Executor); um provider de maior priority nunca é
   descartado por não estar em `tools_allow`.
6. `priority: nil` ordena como o **mais baixo possível** — perde inclusive
   para um `priority: -100` explícito. Não é normalizado para `0` (colidiria
   com um `priority: 0` explícito, que deve ganhar de `nil`).
7. Capability nunca registrada (`providers(cap)` vazio) → mesmo caminho do
   edge case 3, `CapabilityUnavailable` (não é erro de programação, é
   configuração ausente).
8. `deregister_plugin` de um plugin sem nenhum provider é no-op (espelha
   `Registry#deregister_plugin`).
9. `resolve` sem `event_stream:` (default `nil`) não quebra — só não emite
   (mantém `resolve` chamável em teste puro sem stream).

## Testes
**Arquivo:** `spec/harness/capability_registry_spec.rb`

| Caso | O que testa | Esperado |
|------|--------------|----------|
| `register` + `providers` | candidatos aparecem na ordem de registro | `providers(:browse).map(&:impl_name)` na ordem certa |
| `capabilities` | lista as capabilities com ≥1 provider | inclui só as registradas |
| resolve por priority | 2 providers, priorities distintas | resolve para o de maior priority |
| desempate plugins diferentes | mesma priority, plugins "a" e "b", "a" registrado antes | resolve para o do plugin "a" |
| desempate mesmo plugin | mesma priority, mesmo `plugin:` | `raise CapabilityAmbiguous` com os 2 candidatos |
| desempate `nil` vs plugin nomeado | mesma priority, um `plugin: nil` e outro `plugin: "a"` | NÃO é ambíguo — resolve por ordem de registro (edge case 1) |
| desempate `nil` vs `nil` | mesma priority, ambos `plugin: nil` | `raise CapabilityAmbiguous` (edge case 2) |
| `available? == false` | provider indisponível descartado | não aparece nem no `CapabilityAmbiguous` nem escolhido |
| `tools_deny` do profile | deny cobre o `impl_name` do único candidato | `raise CapabilityUnavailable` |
| `tools_allow` do profile não filtra | allow não inclui o `impl_name` de maior priority | resolve igual (allow ignorado — D3/L3) |
| 0 candidatos | capability nunca registrada | `raise CapabilityUnavailable` |
| `:capability_resolved` emitido | resolução bem-sucedida com `event_stream:` (spy) | evento com `capability`, `chosen`, `candidates` (lista completa pós-filtro) |
| sem `event_stream:` | `resolve(..., event_stream: nil)` | não levanta, não emite |
| `priority: nil` perde de priority negativa | `nil` vs `priority: -100` | resolve para `-100` (nil é sempre o mais baixo) |
| `priority: nil` só empata com `nil` | dois providers `priority: nil`, plugins diferentes | resolve por ordem de registro (não ambíguo) |
| `deregister_plugin` | remove só os providers do plugin | `providers(cap)` reflete a remoção; capability sem providers some de `capabilities` |
| `register` kind inválido | `kind: :foo` | `raise ArgumentError` |
| `register` kind `:workflow` | registra normalmente | `warn` emitido (`output(/workflow/).to_stderr`), provider aparece em `providers` |

## Definition of Done
- [ ] `CapabilityRegistry` implementado exatamente com a interface de
      `P2B-01-capability-registry.md` (`register`/`providers`/`capabilities`/
      `deregister_plugin`/`resolve`)
- [ ] `resolve` puro (sem IO além do `available.call` do próprio Provider) e
      determinístico: mesmo input → mesma escolha ou mesmo erro
- [ ] `:capability_resolved` emitido em toda resolução bem-sucedida com
      `event_stream:` presente
- [ ] `lib/harness.rb` requer `harness/capability_registry`
- [ ] Suíte verde sem chave de API (registry é PURO, testado sem `ruby_llm`)
- [ ] Rubocop limpo
- [ ] Code review

## Notas
- **Acoplamento com Task 2:** este task define `CapabilityError`/
  `CapabilityUnavailable`/`CapabilityAmbiguous` num guarda `unless
  defined?(...)` dentro do próprio `capability_registry.rb`, só para o
  registry funcionar e ser testável isoladamente. A Task 2 é a dona canônica
  dessas classes (`lib/harness/errors.rb`, carregado ANTES de
  `capability_registry.rb` em `lib/harness.rb`) — quando ela rodar, o guarda
  é pulado automaticamente (nenhuma colisão de `class ... < ...`, nenhum
  código a remover manualmente). Se a ordem de merge for invertida (Task 2
  antes desta), o guarda nunca chega a definir nada — também sem efeito.
  Não é necessário sequenciar as duas tasks; a Task 5 (Executor) é quem
  realmente depende da forma FINAL dessas classes.
- **Cache por-turno (L2):** este task **não** implementa cache — `resolve` é
  puro e cacheável, mas a memoização por `(capability, profile)` é
  responsabilidade do `Executor` (Task 5), que sabe quando um turno começa e
  termina. Não adicione memoização interna ao `CapabilityRegistry` (evitaria
  reconfigurar dinamicamente providers em testes/rollback).
- **`kind: :workflow`:** registrável e resolvível nesta task (L5), mas SEM
  consumidor — nenhuma outra parte do código chama `resolve` pedindo
  `kind: :workflow` até um follow-up futuro. O `warn` no `register` existe
  para não silenciar essa lacuna.
- **Resolução é deny-only (D3/L3) — não reintroduzir `tools_allow` aqui:** o
  `resolve` só aplica `tools_deny` + `available?` + priority/precedência. O
  grant para usar uma capability é listá-la em `profile.capabilities`,
  conferido pelo Executor (Task 5) antes de chamar `resolve` — não pelo
  registry. Mesmo que pareça "mais seguro" reaplicar `tools_allow` dentro do
  `resolve`, isso reabriria o problema que a decisão fecha: um agente que lista
  a capability mas não o impl concreto em `tools_allow` teria o provider
  filtrado para fora por engano. Ver P2B-01 L3 pro raciocínio completo.
- **Desempate `nil`-vs-`nil` de plugin é `Ambiguous`, não resolução
  silenciosa:** o `group_by(&:plugin)` do Passo 5 não trata `nil` como caso
  especial — dois candidatos `plugin: nil` empatados em priority caem no MESMO
  grupo (`nil`) e resultam em `CapabilityAmbiguous`, exatamente como no edge
  case 2. Um provider sem `plugin:` não carrega nenhuma precedência de
  anúncio para desempatar contra outro provider também sem `plugin:`.
