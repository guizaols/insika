# P2B-01 — Capability Registry: resolução intenção→implementação

> **RFC base:** 0004 (Capability Resolution), 0002 §5/§7 (montagem de tools entre
> Context e Policy), 0003 §5 (precedência de plugin).
> **Evolui:** `lib/harness/plugin/loader.rb`, `lib/harness/agent_profile.rb`,
> `lib/harness/executor.rb`, `lib/harness/errors.rb`, `config/wiring.rb`.
> **Novo:** `lib/harness/capability_registry.rb`,
> `lib/harness/capability/resolved_tool.rb`. **Overview:** D1–D4, D7.

## Objetivo

Desacoplar o agente da tool concreta: ele referencia uma **intenção**
(`:browse`), e o runtime resolve **qual** implementação atende — de forma
determinística, auditável e filtrável por política. Fecha a costura que a Fase 1
deixou pronta (`warn_reserved` em `plugin/loader.rb:109`) sem criar caminho
paralelo: resolução é sub-passo da montagem de tools (RFC-0002 §7).

## Fluxo

```
BOOT:
  plugin manifesto: contracts.capabilities: [browse]      (hoje: parseado e IGNORADO)
  entry.register(api):
    api.register_tool       "browse", BrowseTool
    api.register_capability :browse, tool: "browse", priority: 100
  -> CapabilityRegistry.register(:browse, impl_name: "browse", kind: :tool, plugin:, priority: 100)

TURNO (Executor, entre estágio 2 Context e estágio 3 Policy):
  para cada cap em profile.capabilities:                 [grant = listar a capability, L3]
    provider = CAPABILITY_REGISTRY.resolve(cap, profile:, context:)   [D2, puro/cacheável]
      1. candidatos = providers(cap)
      2. remove os available? == false
      3. remove os cujo impl_name está em profile.tools_deny  (deny SEMPRE vence)
      4. ordena priority desc (nil = mais baixo); desempate = precedência de plugin (announce)
      5. 1 no topo -> provider; 0 -> CapabilityUnavailable;
         >=2 com priority idêntica E mesmo plugin no topo -> CapabilityAmbiguous
      6. emit :capability_resolved { capability, chosen, candidates }
    entry = tool_registry.entry(provider.impl_name)     (kind :tool)

  policy_request: candidate_tools = tool_registry.entries   (SÓ tools diretas — inalterado)
  Policy.decide -> resolution.allowed_tools (raw, filtrado por tools_allow/deny)

  montagem final (run_pipeline, após Policy):
    impls-de-capability embrulhados: impl -> ResolvedTool(capability_name) -> ToolEnvelope
    tool set do turno = instantiate(resolution.allowed_tools) + capability-tools
  -> o modelo vê `browse`; o grant foi profile.capabilities; deny e os gates do
     Envelope (approval/side-effect, por impl_name) ainda valem; a allowlist RAW de
     tools NÃO estica nem encolhe capabilities (D1).
```

## Decisões

### L1 — `CapabilityRegistry` NÃO herda de `Registry` (D1)
`Registry` é conteúdo executável (RFC-0001 princípio 6). Capability é indireção:
guarda `Provider`s e resolve para um `impl_name` que OUTRO registry executa.
Compartilha só o espírito de imutabilidade pós-boot (registra no boot; sem
`freeze!`, imutável por construção — igual ao `Registry`).

### L2 — `resolve` é PURO e cacheável por `(capability, profile)` no turno (D2)
Sem IO próprio além de `available?` (que o Provider encapsula). O algoritmo da
RFC-0004 §5 é determinístico: MESMO input → MESMO output ou MESMO erro. O Executor
pode memoizar por turno (o profile é imutável no turno). Emite
`:capability_resolved` a cada resolução bem-sucedida (auditoria).

### L3 — Autorização de capability = `profile.capabilities`; resolução aplica só DENY (decisão D1, refina RFC-0004 §5.3)
**O grant para usar uma capability é listá-la em `profile.capabilities`** (opt-in
explícito, simétrico ao `skills`/`capabilities: nil = nenhuma`). A resolução NÃO
reusa a allowlist RAW de tools (`tools_allow`) para escolher o provider — só
aplica:
- **`tools_deny`** sobre `impl_name` (deny SEMPRE vence — uma tool proibida nunca
  respalda uma capability; único invariante de segurança preservado em todo lugar);
- **`available?`** (bin/env/health);
- **priority/precedência** (L4).

**Por quê (vs RFC-0004 §5.3 que mandava aplicar o `allow` também):** se a resolução
respeitasse `tools_allow` não-nil (= "conjunto final"), um agente que lista a
capability mas NÃO o impl concreto teria a capability filtrada para fora — e para
expor `browse` escondendo a tool crua seria preciso um lens de allow separado,
brigando com o princípio de **allowlist ÚNICA** do `AgentProfile`. Decisão: o
pinning por-agente de provider ("browse só com o browser X") fica para a
**evolução** (RFC-0004 §8) via um campo dedicado `capability_providers`
(`{cap => [impls]}`), não sobrecarregando `tools_allow`.

**Junção pós-Policy (não passa pela `ToolAllowlist`):** as tools de capability são
autorizadas pelo grant acima e **juntadas ao tool set DEPOIS do estágio 3** — assim
uma `tools_allow` RAW não-nil (que governa tools DIRETAS) não as remove. A Policy
continua rodando sobre o resultado concreto pelos gates que importam (deny já
aplicado; `ApprovalRequired` no Envelope por `impl_name`; custo/tenant = futuro).
**Sem dupla-exposição:** o impl aparece ao modelo só sob o nome estável da
capability; só vira tool crua se o agente o listar SEPARADAMENTE em `tools_allow`.

### L4 — Desempate determinístico; empate real = `CapabilityAmbiguous` (D2/D5)
Ordenação: **`priority` desc como chave primária** (RFC-0004 §5.4); `priority: nil`
ordena como **o mais baixo** (abaixo de qualquer inteiro — sem normalizar para 0,
que colidiria com um `priority: 0` explícito); empate de priority quebra por
**precedência de plugin** = ordem de `announce` das gems (RFC-0003 §5). Só é
`CapabilityAmbiguous` o empate **residual**: mesma `priority` E mesmo plugin no
topo (dois providers indistinguíveis registrados pelo MESMO plugin — erro de
config do autor do plugin, falha alto, D2). Providers de plugins DIFERENTES nunca
dão ambíguo (a precedência sempre resolve). `CapabilityAmbiguous` lista os
candidatos (nomes + plugins + priorities) para diagnóstico.

### L5 — `kind: :tool` é o alvo exposto ao modelo; `:workflow` fica registrável mas com exposição adiada
`register_capability` aceita `tool:` e `workflow:` (RFC-0004 §3) — o registry
guarda ambos os `kind`. Mas a **exposição ao loop do agente** nesta fatia cobre só
`kind: :tool` (a tool renomeada entra no `with_tools`). Capabilities de workflow
resolvem igual (o registry as guarda e resolve), porém sua exposição via
`TriggerWorkflow`/`WorkflowAllowlist` fica como follow-up — evita acoplar dois
caminhos de exposição numa fatia só. Registrar `kind: :workflow` sem consumidor
emite warn (não silencia).

### L6 — Ativar `contracts.capabilities` sem quebrar plugins da Fase 1
`warn_reserved` (loader.rb:109) vira parsing real: `build_discovered` ganha
`capability_names` (de `contracts.capabilities`); `StagingApi#register_capability`
valida que a capability foi declarada no manifesto (mesma disciplina de
`register_tool` vs `contracts.tools`: não declarada → warn + ignora). Plugin sem
`contracts.capabilities` continua idêntico (o bloco é opcional). Rollback do
Loader (`deregister_plugin`) passa a limpar também as capabilities do plugin.

### L7 — `ResolvedTool` só troca o `name`; o resto delega (D4)
`Capability::ResolvedTool < SimpleDelegator` (padrão do `ToolEnvelope`): expõe
`name` = nome da capability, delega `execute`/`parameters`/`description` ao impl.
**Ordem de embrulho em `run_pipeline`** (não em `configure_chat` — o `wrap_tools`/
`ToolEnvelope` já roda no estágio 3, ANTES do `configure_chat` ver as tools):
`impl → ResolvedTool → ToolEnvelope`, entre `instantiate_tools` e `wrap_tools`. O
Envelope opera sobre a call renomeada; **`ToolEnvelope` passa a chavear
side-effect/approval por `impl_name`** (`respond_to?(:impl_name) ? impl_name :
name`) — senão o lookup no `tool_registry` (chaveado por `impl_name`) quebraria sob
o alias. `tool_envelope.rb` entra na lista de arquivos da task 5.

## Interfaces

### `CapabilityRegistry` (`lib/harness/capability_registry.rb`)
```ruby
module Harness
  class CapabilityRegistry
    Provider = Data.define(:capability, :impl_name, :kind, :plugin, :priority, :available)
    #   kind:      :tool | :workflow
    #   priority:  Integer | nil (nil herda precedência de plugin)
    #   available: callable -> bool (default -> { true })

    def register(capability, impl_name:, kind:, plugin: nil, priority: nil, available: nil)
    def providers(capability)  # -> [Provider] (todos os candidatos, ordem de registro)
    def capabilities           # -> [Symbol]
    def deregister_plugin(plugin_id) # rollback do Loader (L6), simétrico ao Registry
    def resolve(capability, profile:, context: {}, event_stream: nil)
      # -> Provider (o escolhido) | raise CapabilityUnavailable | raise CapabilityAmbiguous
  end
end
```

### `AgentProfile` — novo campo `capabilities`
```ruby
# capabilities: allowlist de intenções que o agente pode usar (RFC-0004 §6).
#   nil  = nenhuma capability (comportamento Fase 1 — só tools diretas)
#   [names] = essas capabilities são resolvidas e expostas
AgentProfile = Data.define(..., :capabilities)   # + no build(capabilities: nil)
```
> Semântica escolhida: `nil`/ausente = nenhuma (não "todas"). Capability é opt-in
> explícito — diferente de `tools_allow` (`nil` = todas) porque expor toda
> capability registrada por engano acoplaria o agente a plugins que ele não pediu.
> Documentar essa assimetria no comentário do campo.

### `errors.rb` — novos erros de estágio `:capability`
```ruby
class CapabilityError     < Error; end   # base; stage :capability -> task :failed
class CapabilityUnavailable < CapabilityError
  def initialize(capability:) ; ... ; end   # 0 candidatos após filtro
class CapabilityAmbiguous   < CapabilityError
  attr_reader :candidates
  def initialize(capability:, candidates:) ; ... ; end  # >=2 empatados no topo
```

### `Capability::ResolvedTool` (`lib/harness/capability/resolved_tool.rb`)
```ruby
module Harness
  module Capability
    class ResolvedTool < SimpleDelegator
      def initialize(impl, capability_name:, impl_name:)
      def name = @capability_name          # nome ESTÁVEL exposto ao modelo (D4)
      def impl_name = @impl_name            # p/ side_effect?/approval no Envelope
      # execute/parameters/description delegam ao impl
    end
  end
end
```

### Entry API do plugin (`plugin/loader.rb` StagingApi)
```ruby
def register_capability(name, tool: nil, workflow: nil, priority: nil, available: nil)
  # valida contra contracts.capabilities (L6); staged; efetivado no commit!
  # exatamente um de tool:/workflow: (senão warn + ignora)
end
```

## Integração no Executor (`executor.rb`)

- Novo `@capability_registry` no construtor (default `nil` → sem capabilities,
  paridade Fase 1).
- Novo método `resolve_capabilities(profile, context)` chamado em `run_pipeline`
  **antes** de `policy_request` (D3): devolve `[{entry:, capability_name:}]`
  (memoizado por turno). Erros levantam `CapabilityError` → capturado em `execute`
  como novo `rescue CapabilityError` (espelha o `rescue ContextError`, stage
  `:capability`).
- `policy_request`: `candidate_tools` permanece `tool_registry.entries` (SÓ tools
  diretas — inalterado). As tools de capability NÃO entram na `ToolAllowlist` (D1,
  L3): são autorizadas pelo grant `profile.capabilities` + deny + resolução, e
  **juntadas ao tool set final após o estágio 3**. A marcação `{impl_name →
  capability_name}` viaja no `TurnState` (não na Entry).
- **Ponto do wrap (corrigido no detalhamento da task 5):** o `ToolEnvelope`
  (`wrap_tools`) já roda no `run_pipeline` (estágio 3), ANTES de o `configure_chat`
  ver as tools — então o `ResolvedTool` **não** entra no `configure_chat`. Ordem
  correta em `run_pipeline`: `instantiate_tools` → **embrulha os impls de origem-
  capability em `ResolvedTool(capability_name:)`** → `wrap_tools` (`ToolEnvelope`).
  Assim o Envelope opera sobre a call já renomeada (D4).
- **`ToolEnvelope` passa a consultar `impl_name` (não `name`) (task 5):** hoje
  `side_effect?`/`approval_required?`/correlação usam `__getobj__.name`, que num
  `ResolvedTool` resolveria para o nome ESTÁVEL (capability) e quebraria o lookup
  no `tool_registry` (chaveado por `impl_name`). O Envelope passa a preferir
  `respond_to?(:impl_name) ? impl_name : name`. `tool_envelope.rb` entra na lista
  de arquivos da task 5.

## Testes (fazem parte de cada task)

- **Contrato do `CapabilityRegistry`** (puro, sem gem): register/providers;
  resolução por priority (nil = mais baixo); desempate por precedência de plugin;
  `available? == false` descartado; **`tools_deny` do profile sobre impl_name
  descarta candidato** (deny vence); `tools_allow` NÃO restringe providers (D1/L3);
  0 → `Unavailable`; ≥2 same-priority-same-plugin → `Ambiguous` com candidatos;
  plugins distintos empatados → precedência resolve (não é ambíguo);
  `:capability_resolved` emitido.
- **Loader**: `contracts.capabilities` parseado; `register_capability` validado
  contra o manifesto; plugin sem o bloco inalterado; `deregister_plugin` limpa
  capabilities.
- **`ResolvedTool`**: `name` = capability, `execute`/`impl_name` delegam.
- **Executor (integração, RubyLLM mockado)**: agente com `capabilities: [:browse]`
  vê a tool `browse` (nome estável) no chat; Policy nega o impl → capability some;
  ambíguo → turno falha em `:capability`.

## Fora de escopo (RFC-0004 §8 evolução)

Seleção por custo/latência; fallback automático em cadeia; capability versionada;
cache por-sessão (nesta fatia o cache é por-turno). Exposição de capability de
workflow ao agente (L5). **Pinning de provider por agente** ("browse só com o
browser X") via `profile.capability_providers` (`{cap => [impls]}`) — adiado (D1/L3);
até lá o provider é escolhido por priority/precedência/availability + `tools_deny`.
