# Task 05 (P2B): Executor — capability assembly (entre Context e Policy, junção pós-Policy)

> **Techspec:** [P2B-01-capability-registry.md](../P2B-01-capability-registry.md) (§Fluxo, §Integração no Executor, L3/L4/L7) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** A

## Objetivo

Costurar o `CapabilityRegistry` (tasks 1-4) no `Executor` em DOIS pontos, sem
criar um estágio novo (RFC-0002 §7/§8):

1. **Entre o estágio 2 (Context) e o estágio 3 (Policy):** um sub-passo
   síncrono (`resolve_capabilities`) resolve cada capability de
   `profile.capabilities` (o grant, opt-in — D3) para o `impl_name` concreto
   via `CapabilityRegistry#resolve` (que já aplica deny+availability+priority
   internamente, task 1), valida que o `impl_name` está registrado no
   `tool_registry` e guarda a marcação `impl_name -> capability_name` no
   `TurnState` (`state.capability_names`).
2. **Depois de `@policy_engine.decide`:** as tools de origem-capability são
   instanciadas e reveste em `Capability::ResolvedTool` (nome estável, D4)
   **antes** do `ToolEnvelope` (`wrap_tools`), e **juntadas** ao conjunto já
   instanciado de `resolution.allowed_tools` — **fora** da `ToolAllowlist**:
   `candidate_tools`/`policy_request` **não mudam** (continuam só
   `tool_registry.entries`, tools diretas) e as capabilities **não** entram
   na Policy (D1/L3). O grant é `profile.capabilities`; o único filtro que a
   resolução aplica é `tools_deny` (SEMPRE vence) — não `tools_allow`.

`capability_registry: nil` no construtor deve reproduzir **exatamente** o
comportamento da Fase 1 — nenhuma tool nova aparece, nenhum código novo roda.

## Dependências

| Task | O que fornece | Por quê |
|---|---|---|
| [Task 01](./task-01.md) | `CapabilityRegistry#resolve` (determinístico, `Provider`, já aplica deny+availability+priority) | é o que o Executor chama no novo sub-passo |
| [Task 02](./task-02.md) | `CapabilityError`/`CapabilityUnavailable`/`CapabilityAmbiguous` + `Capability::ResolvedTool` | erro capturado no `rescue`; decorator usado no wrap pós-Policy |
| [Task 03](./task-03.md) | `AgentProfile#capabilities` (allowlist opt-in, `nil` = nenhuma) | é o que o Executor itera em `resolve_capabilities` |
| [Task 04](./task-04.md) | `contracts.capabilities` ativo no `PluginLoader` | garante que `impl_name` resolvido pelo registry está de fato em `tool_registry` (registrado pelo mesmo plugin) |

## Contexto

RFC-0002 §7/§8: features **estendem** estágios existentes, nunca criam um
fluxo paralelo. A resolução de capability não é um "estágio 2.5" com
lifecycle próprio — é um sub-passo síncrono, sem IO além do que o
`CapabilityRegistry#resolve` já encapsula (`available?`), que roda **dentro**
do mesmo bloco de `run_pipeline` que hoje monta `policy_request` (doc 05 §2).

**A Policy nunca vê tools de capability (D1/L3).** `candidate_tools` do
`policy_request` continua sendo, sem exceção, `tool_registry.entries` — as
tools diretas registradas no boot. Isso não é um detalhe de implementação: é
a decisão L3 do P2B-01 — a autorização de usar uma capability é **listá-la em
`profile.capabilities`**, não é decidida pela `ToolAllowlist`. Se a resolução
respeitasse `tools_allow` (como a leitura inicial da RFC-0004 §5.3 sugeria),
um agente que lista a capability mas não o `impl_name` cru teria a
capability filtrada para fora — obrigando um lens de allow separado e
quebrando o princípio de allowlist ÚNICA do `AgentProfile`. Por isso as tools
de capability são **juntadas ao tool set DEPOIS** de `@policy_engine.decide`
— nunca passam pela `ToolAllowlist`, e uma `tools_allow` não-nil (que
governa só as tools DIRETAS) não as remove.

Duas cabines de nome coexistem por design (D4):

- **Nome estável ao modelo**: a capability (`browse`) — o prompt/skill
  referencia isso, não importa qual plugin resolveu.
- **`impl_name` à resolução/Envelope**: o `tools_deny` (dentro do
  `CapabilityRegistry#resolve`), o `side_effect?` e o gate de aprovação
  continuam operando sobre o nome REAL registrado no `tool_registry`
  (`chromium_browse`, por ex.) — nunca sobre o apelido.

Por isso a marcação "esta entry veio de uma capability, e o nome estável é
X" **não pode viver na `Entry`** (`Registry::Entry` é `Data.define` imutável,
compartilhada entre TODOS os agentes/perfis — gravar ali vazaria a marcação
de um perfil para os demais). Ela viaja **à parte**, no `TurnState` (que já é
mutável por perfil-de-turno, doc 03 L5), como um `Hash` `impl_name => nome da
capability`, calculado uma vez pelo novo `resolve_capabilities` (ANTES da
Policy) e consultado depois, no ponto de junção pós-Policy (isso é o
"memoizado por turno" do doc P2B-01 — não é cache próprio do Executor, é
reuso do resultado já calculado, guardado no `state`).

**Achado de leitura do código atual (não estava explícito no doc original) —
ver "Notas" no fim:** o `ToolEnvelope` (`lib/harness/tool_envelope.rb`)
consulta `side_effect?`/`approval_required?`/`correlation_id` chamando
`__getobj__.name` — ou seja, se o `ResolvedTool` troca `name` para o
apelido, o Envelope passaria a procurar o side-effect/aprovação pelo NOME
ESTÁVEL, que não existe no `tool_registry` (só o `impl_name` está lá). Isso
quebraria silenciosamente o rastreio de side-effect para toda tool exposta
via capability. `ResolvedTool` já expõe `impl_name` para isso (L7) — falta o
`ToolEnvelope` **usar** esse método quando presente. Esta task inclui esse
ajuste mínimo.

## Arquivos

| Arquivo | Ação | Razão |
|---|---|---|
| `lib/harness/executor.rb` | MODIFY | `capability_registry:` no construtor; `resolve_capabilities` chamado em `run_pipeline` ANTES do `policy_request` (`policy_request` em si NÃO MUDA); `rescue CapabilityError`; após `@policy_engine.decide`, junção das capability-tools (instantiate → `Capability::ResolvedTool` → `wrap_tools`) ao conjunto instanciado de `resolution.allowed_tools`, sem duplicar impl já permitido direto |
| `lib/harness/turn_state.rb` | MODIFY | novo `attr_accessor :capability_names` (Hash `impl_name(String) => capability_name(String)`, default `{}`) |
| `lib/harness/tool_envelope.rb` | MODIFY | `side_effect?`/`approval_required?` (e o fallback de `correlation_id`) devem consultar `impl_name` quando o delegate responder a ele, senão `name` — ver "Contexto" acima. **Não estava no escopo original da task, mas é necessário para D4/L7 funcionarem de ponta a ponta; ver "Notas".** |
| `spec/harness/executor_chat_spec.rb` | MODIFY | testes unitários do wrap `impl → ResolvedTool → ToolEnvelope` e da consulta por `impl_name` no Envelope |
| `spec/harness/executor_pipeline_spec.rb` | MODIFY | testes de integração do sub-passo no `run_pipeline`: no-op sem `capability_registry`, `rescue CapabilityError` → `:failed stage: capability`, `candidate_tools`/`policy_request` inalterados, junção pós-Policy, deny esgotando candidatos falha o turno, dedup com tool direta |

## Passo a passo

### Passo 1 — Construtor: `capability_registry: nil`

**Padrão de referência (codebase)** — construtor atual (`lib/harness/executor.rb:16-38`):

```ruby
def initialize(context_builder:, policy_engine:, middleware:, hooks:,
               tool_registry:, skill_catalog:, profiles:,
               session_store:, task_store:, checkpoint_store:,
               event_stream:, workflow_registry: nil, pending_action_store: nil)
  @context_builder = context_builder
  # ...
  @workflow_registry = workflow_registry # estágio 6 do trigger_workflow (task 23)
  @pending_action_store = pending_action_store # gate de aprovação (P2-02)
  # ...
end
```

Acrescentar `capability_registry: nil` na assinatura (mesmo padrão dos outros
opcionais — `workflow_registry`/`pending_action_store` — default `nil` =
feature desligada) e `@capability_registry = capability_registry`.

### Passo 2 — `TurnState` ganha `capability_names`

`lib/harness/turn_state.rb` atual já documenta os campos "internos" (não
fazem parte do contrato do doc 03 §3):

```ruby
# Interno (não faz parte do contrato do doc 03 §3): correlação tool_call
# corrente <-> decorators de tool (side-effects/skip, task 13).
attr_accessor :current_tool_call
```

Seguir o mesmo padrão: acrescentar logo abaixo (ou junto de `allowed_tools`)

```ruby
# Interno (P2B, D4): impl_name(String) -> nome ESTÁVEL da capability que o
# resolveu, calculado por resolve_capabilities ANTES do policy_request e
# consultado DEPOIS de @policy_engine.decide, na junção pós-Policy (Passo 5),
# para decidir quais impls entram como Capability::ResolvedTool. {} = sem
# capability_registry ou profile.capabilities vazio (paridade Fase 1).
attr_accessor :capability_names
```

e inicializar `@capability_names = {}` no `initialize` (evita `nil` em todo
call-site que faz `state.capability_names[...]` ou `.key?`; os specs que usam
`Struct` em vez de `TurnState` — `executor_chat_spec.rb` — não têm esse
campo, então todo código que lê `capability_names` deve tolerar sua ausência
via `state.respond_to?(:capability_names) ? state.capability_names : {}`,
igual ao `@state.respond_to?(:requires_approval)` que o `ToolEnvelope` já
faz).

### Passo 3 — `resolve_capabilities(profile, context)` — o novo sub-passo (ANTES da Policy)

Novo método privado em `executor.rb`. Resolve e **valida** contra o
`tool_registry` (o `impl_name` sempre aponta pra lá —
`contracts.capabilities`/`register_capability`, task 4 — nunca para um
registry paralelo); **não** toca `candidate_tools`/`policy_request` — esses
continuam vendo só `tool_registry.entries` (D1/L3):

```ruby
# Sub-passo de resolução ENTRE Context e Policy (RFC-0002 §7/§8, D3 do
# P2B-01) — não é estágio novo, não tem lifecycle próprio, e NÃO alimenta
# candidate_tools (essas continuam SÓ tool_registry.entries — D1/L3: a
# capability não passa pela ToolAllowlist). Resolve cada capability do
# perfil para a Entry concreta já registrada no tool_registry e guarda a
# marcação impl_name -> capability_name para a junção pós-Policy (Passo 5).
# Erros de resolução (Unavailable/Ambiguous, ou impl_name não registrado)
# propagam como CapabilityError — captura única no rescue de `execute`
# (Passo 4). Sem @capability_registry OU sem profile.capabilities: {}
# (no-op, paridade Fase 1 — D3 do overview).
def resolve_capabilities(profile, context)
  return {} if @capability_registry.nil?

  Array(profile.capabilities).each_with_object({}) do |cap_name, names|
    provider = @capability_registry.resolve(cap_name, profile: profile, context: context,
                                                       event_stream: @event_stream)
    next if provider.kind == :workflow # exposição ao loop do agente fica p/ follow-up (L5)

    entry = @tool_registry.entries.find { |e| e.name == provider.impl_name.to_s }
    if entry.nil?
      raise CapabilityError, "capability '#{cap_name}' resolveu para impl " \
                             "'#{provider.impl_name}', não registrado em tool_registry"
    end

    names[entry.name] ||= cap_name.to_s # 1ª capability a reivindicar um impl vence
  end
end
```

Chamar em `run_pipeline`, **depois** do estágio 2 (Context já montado —
`resolve` recebe o `context` para providers cujo `available?` dependa dele) e
**antes** do `policy_request` (só para preencher `state.capability_names` a
tempo da junção pós-Policy — `policy_request` em si não lê esse campo).

**Padrão de referência (codebase) — `run_pipeline` atual**
(`lib/harness/executor.rb:342-373`):

```ruby
@hooks.around(:task, state) do |state|
  request = build_context_request(task, profile, state, resume_from)
  state.context = @context_builder.call(request)
  drain_and_maybe_suspend(task, actor)

  save_initial_checkpoint(task, profile, state)

  # estágio 3: Policy (candidate_skills vêm do CATÁLOGO, não do contexto)
  resolution = @policy_engine.decide(policy_request(profile, task, state))
  skip = resume_from ? @checkpoint_store.side_effects(task.id, turn: state.turn) : []
  state.actor = actor
  state.approval_coordinator = self
  state.requires_approval = resolution.respond_to?(:requires_approval) ? resolution.requires_approval : []
  state.allowed_tools = wrap_tools(instantiate_tools(resolution.allowed_tools), state, skip)
  state.allowed_skills = resolution.allowed_skills
  drain_and_maybe_suspend(task, actor)
```

Inserir a chamada logo após `save_initial_checkpoint` (não depende de
checkpoint nem o afeta — a ordem entre as duas não importa funcionalmente;
manter depois preserva a leitura "checkpoint do turno primeiro, resolução de
capability depois"):

```ruby
  save_initial_checkpoint(task, profile, state)

  # sub-passo de resolução de capability (D3): ENTRE Context e Policy. Só
  # preenche state.capability_names para a junção PÓS-Policy (Passo 5) — o
  # policy_request abaixo NÃO muda (candidate_tools continua tool_registry.entries).
  state.capability_names = resolve_capabilities(profile, state.context)

  # estágio 3: Policy (candidate_skills vêm do CATÁLOGO, não do contexto;
  # candidate_tools = tool_registry.entries, SÓ tools diretas — inalterado)
  resolution = @policy_engine.decide(policy_request(profile, task, state))
```

`policy_request` (`lib/harness/executor.rb:479-487`) **não muda nesta task**
— continua exatamente:

```ruby
def policy_request(profile, task, state)
  Harness::Policy::PolicyRequest.new(
    profile: profile,
    command: rebuild_command(task),
    context: state.context,
    candidate_tools: @tool_registry.respond_to?(:entries) ? @tool_registry.entries : [],
    candidate_skills: @skill_catalog.effective(profile.skills)
  )
end
```

### Passo 4 — `rescue CapabilityError` em `execute` (espelha `ContextError`)

**Padrão de referência (codebase)** — captura única atual
(`lib/harness/executor.rb:202-221`):

```ruby
rescue CancelledError
  # ...
rescue PolicyDenied => e
  emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task) # D5
  fail_task(task, e, stage: :policy)
rescue ContextError => e
  fail_task(task, e, stage: :context)
rescue ProviderError => e
  fail_task(task, e, stage: :ruby_llm)
```

Acrescentar logo após `rescue ContextError` (mesma forma — nenhum evento
próprio, D7 do overview: falhas de capability não ganham evento dedicado,
propagam via `:task_failed`/`:error` já existentes). Cobre tanto o
`resolve_capabilities` do Passo 3 quanto a junção pós-Policy do Passo 5 (as
duas rodam dentro do mesmo `run_pipeline`, sob a mesma captura única):

```ruby
rescue ContextError => e
  fail_task(task, e, stage: :context)
rescue CapabilityError => e
  fail_task(task, e, stage: :capability)
rescue ProviderError => e
```

### Passo 5 — Junção PÓS-Policy: `impl → ResolvedTool → ToolEnvelope`, fora da `ToolAllowlist`

`candidate_tools`/`policy_request` (Passo 3) não mudam — a Policy decide
`resolution.allowed_tools` olhando só para as tools DIRETAS. As tools de
capability nunca passaram por ali; elas são **acrescentadas** ao conjunto já
instanciado logo depois, exatamente como o Fluxo do P2B-01 descreve:

```
montagem final (run_pipeline, após Policy):
  impls-de-capability embrulhados: impl -> ResolvedTool(capability_name) -> ToolEnvelope
  tool set do turno = instantiate(resolution.allowed_tools) + capability-tools
```

**Padrão de referência (codebase)** — linha atual em `run_pipeline`:

```ruby
state.allowed_tools = wrap_tools(instantiate_tools(resolution.allowed_tools), state, skip)
```

vira:

```ruby
state.allowed_tools = wrap_tools(assemble_tool_instances(resolution.allowed_tools, state), state, skip)
```

Dois métodos privados novos:

```ruby
# Junta as instâncias diretas (Policy, ToolAllowlist) às de origem-capability
# (grant = profile.capabilities, Passo 3) — a segunda categoria NUNCA passou
# pela Policy (D1/L3). Evita dupla-exposição (L3): se o MESMO impl_name
# também foi permitido diretamente (tools_allow explícito o inclui), a
# instância DIRETA é descartada — o modelo vê só o apelido da capability,
# nunca os dois nomes para o mesmo impl.
def assemble_tool_instances(allowed, state)
  names = state.respond_to?(:capability_names) ? state.capability_names : {}
  return instantiate_tools(allowed) if names.empty?

  direct = instantiate_tools(allowed).reject { |tool| names.key?(tool.name.to_s) }
  direct + capability_tool_instances(names)
end

# impl_name -> Capability::ResolvedTool(capability_name:), AINDA sem
# ToolEnvelope (wrap_tools embrulha o conjunto inteiro no call site, junto
# das tools diretas — mesma ordem impl -> ResolvedTool -> ToolEnvelope, D4).
# entry já foi validada contra tool_registry em resolve_capabilities (Passo 3).
def capability_tool_instances(names)
  names.map do |impl_name, capability_name|
    entry = @tool_registry.entries.find { |e| e.name == impl_name }
    Capability::ResolvedTool.new(entry.factory.call, capability_name: capability_name, impl_name: impl_name)
  end
end
```

`configure_chat` **não muda** nesta task — ela só CONSOME
`state.allowed_tools` já 100% instanciado e envelopado
(`chat.with_tools(*tools)`), como hoje. O wrap tem que entrar **dentro de
`run_pipeline`, entre `instantiate_tools`/junção e `wrap_tools`**, nunca
dentro de `configure_chat` (ela roda no estágio 5, depois do `wrap_tools` já
ter acontecido no estágio 3).

### Passo 6 — `ToolEnvelope`: side-effect/aprovação por `impl_name`

**Padrão de referência (codebase)** — `lib/harness/tool_envelope.rb` atual:

```ruby
def approval_required?
  @state.respond_to?(:requires_approval) &&
    Array(@state.requires_approval).include?(__getobj__.name.to_s)
end
# ...
def side_effect?
  @tool_registry.respond_to?(:side_effect?) &&
    @tool_registry.side_effect?(__getobj__.name)
end
```

Ambos usam `__getobj__.name` — se `__getobj__` for um `ResolvedTool`,
`.name` é o apelido (capability), não o `impl_name` real que está no
`tool_registry`/em `requires_approval` (a Policy nunca decidiu sobre o
apelido — só sobre `impl_name`, e só quando a tool também é direta; o
`tools_deny` que protege a capability já foi aplicado dentro de
`CapabilityRegistry#resolve`, Passo 3). Introduzir um helper privado e trocar
as duas chamadas (e o fallback de `correlation_id`, pela mesma razão — ver
seu comentário sobre "correlação por nome"):

```ruby
# impl_name real quando o delegate é um Capability::ResolvedTool (D4/L7);
# senão o próprio #name (tool direta, comportamento Fase 1 inalterado).
def real_name
  __getobj__.respond_to?(:impl_name) ? __getobj__.impl_name.to_s : __getobj__.name.to_s
end
```

e trocar `__getobj__.name`/`__getobj__.name.to_s` por `real_name` nos três
usos (`approval_required?`, `side_effect?`, `correlation_id`).

## Edge cases

- `profile.capabilities: nil` (ou `@capability_registry: nil`) → `resolve_capabilities` devolve `{}`; `candidate_tools`/`policy_request` (inalterados) e `resolution.allowed_tools` instanciado sem junção nenhuma — comportamento idêntico à Fase 1 (nenhuma tool nova, nenhum wrap).
- **Deny esgota os candidatos → falha o turno, NÃO "some" silenciosamente**: `tools_deny` é aplicado **dentro** de `CapabilityRegistry#resolve` (task 1), antes até de a Policy rodar. Se o `impl_name` negado era o único candidato da capability, `resolve` levanta `CapabilityUnavailable` → `CapabilityError` (Passo 4) → task `:failed`, `stage: "capability"`. Se sobra outro candidato (priority/precedência), a resolução segue para ele normalmente — sem erro. (Diferente da Fase de leitura inicial da task, em que o "sumiço" acontecia via Policy sobre `candidate_tools`; agora a capability nem chega à Policy, então o único ponto de deny é a resolução em si.)
- `tools_allow` RAW **não-nil** que NÃO inclui o `impl_name` da capability **não afeta a capability** (D1/L3): a junção acontece DEPOIS de `@policy_engine.decide`, então uma `tools_allow` restritiva (que filtra `resolution.allowed_tools` das tools DIRETAS) não tem chance de olhar para a capability. A capability aparece de qualquer forma, desde que resolvida com sucesso — só `tools_deny` (dentro da resolução) e `available?`/priority a filtram.
- `CapabilityUnavailable`/`CapabilityAmbiguous` (0 ou ≥2 empatados no `CapabilityRegistry#resolve`) → propaga como `CapabilityError` → `rescue CapabilityError` (Passo 4) → task `:failed`, `stage: "capability"`; nenhum evento `:capability_resolved` para essa capability (D7 — falha de resolução não emite evento próprio, só `:task_failed`/`:error`).
- `impl_name` resolvido mas **não registrado** em `tool_registry` (config quebrada entre `CapabilityRegistry` e `ToolRegistry`) → `resolve_capabilities` levanta `CapabilityError` explícito (mesmo tratamento acima) — nunca silencia.
- Provider resolvido com `kind: :workflow` → `resolve_capabilities` **ignora** (não adiciona a `capability_names`); exposição de capability-workflow ao loop do agente é follow-up (L5). Não falha o turno.
- Duas capabilities do mesmo perfil resolvem para o **mesmo** `impl_name` → `names[entry.name] ||= cap_name` — a primeira capability a reivindicar aquele impl "vence" o apelido; a segunda simplesmente não tem efeito adicional (a tool já está marcada). Documentar como limitação conhecida (RFC-0004 §8 não cobre múltiplos apelidos por impl).
- `impl_name` já é uma tool **diretamente** permitida pelo perfil (`tools_allow` inclui o nome real, e a Policy o mantém em `resolution.allowed_tools`) — `assemble_tool_instances` (Passo 5) descarta a instância DIRETA daquele nome (`reject` por `capability_names.key?`); a versão-capability (`ResolvedTool`) é quem entra. O modelo só vê o apelido, nunca os dois nomes para o mesmo impl — é o comportamento correto: uma vez que o perfil declarou a capability, o nome estável é o único exposto para aquele impl.
- `ResolvedTool` preserva `impl_name` — o `ToolEnvelope` (Passo 6) consulta por ele em `side_effect?`/`approval_required?`/`correlation_id`; sem esse ajuste, side-effect e aprovação de tools expostas via capability ficariam sempre `false`/nunca-exigidas (checkpoint de resumabilidade quebraria silenciosamente para elas).
- Turno de `trigger_workflow` (workflow) com `profile.capabilities` preenchido: a mesma junção pós-Policy roda (o código é compartilhado entre os dois caminhos, doc 03 §4.1) — as tools passadas ao `workflow.call(..., tools: state.allowed_tools)` já vêm com o apelido, se aplicável. Não há tratamento especial nesta task (workflow não consulta `chat`, então não há diferença prática; documentar só para quem for escrever o teste).

## Testes

**Arquivo:** `spec/harness/executor_chat_spec.rb` (unitários, sem gem — Structs) + `spec/harness/executor_pipeline_spec.rb` (integração do `run_pipeline`, RubyLLM mockado via `FakeChat`)

| # | Cenário | Arquivo | Asserção |
|---|---|---|---|
| 1 | `capability_registry: nil` no construtor | pipeline | turno idêntico à Fase 1 — nenhuma `Capability::ResolvedTool` no `chat.tools`, nenhum evento novo |
| 2 | `profile.capabilities: nil` com `capability_registry` presente | pipeline | `resolve_capabilities` devolve `{}`; `policy_request.candidate_tools` == `tool_registry.entries` (nada muda, sem tocar nesse método) |
| 3 | `capabilities: [:browse]` resolve para impl registrado | chat/pipeline | `chat.tools.map(&:name)` inclui `"browse"` (não o impl_name); o objeto em `chat.tools` é um `ToolEnvelope` cujo `__getobj__` é um `Capability::ResolvedTool`; `policy_request.candidate_tools` NÃO contém entry extra por causa da capability |
| 4 | `tools_deny` inclui o único `impl_name` candidato da capability | pipeline | `CapabilityRegistry#resolve` levanta `CapabilityUnavailable` → task `:failed`, `stage: "capability"` (NÃO um sumiço silencioso — a capability nunca chegou à Policy) |
| 5 | `tools_allow` RAW não-nil que NÃO inclui o `impl_name` da capability | pipeline | a tool `"browse"` aparece em `chat.tools` mesmo assim (junção é pós-Policy; `tools_allow` só filtra tools diretas) |
| 6 | `CapabilityRegistry#resolve` levanta `CapabilityAmbiguous`/`CapabilityUnavailable` | pipeline | task `:failed`, `executions.last.error["stage"] == "capability"`; eventos incluem `:task_failed`, `:error`; NÃO inclui evento de capability dedicado |
| 7 | `impl_name` de uma capability TAMBÉM permitido direto (`tools_allow` o inclui, Policy o mantém em `allowed_tools`) | pipeline | `chat.tools` tem UMA única entrada para aquele impl, sob o apelido da capability (nunca as duas: crua + apelidada) |
| 8 | `ToolEnvelope` sobre um `Capability::ResolvedTool` marcado `side_effect: true` no `tool_registry` (pelo `impl_name`) | chat (unit, `wrap_tools`) | `side_effect?` verdadeiro; `checkpoint_store.record_side_effect` chamado com o `call_id` (não quebra por procurar pelo apelido) |
| 9 | `ToolEnvelope` sobre um `Capability::ResolvedTool` cujo `impl_name` está em `state.requires_approval` | chat (unit) | `approval_required?` verdadeiro (gate de aprovação disparado mesmo com o apelido exposto ao modelo) |
| 10 | `impl_name` resolvido não registrado em `tool_registry` (registry mal configurado) | pipeline | `CapabilityError` explícito → `:failed stage: "capability"` |
| 11 | Provider resolvido com `kind: :workflow` | unit (`resolve_capabilities`) | não entra em `capability_names`; turno não falha |

## Definition of Done

- [ ] `capability_registry: nil` no construtor reproduz a Fase 1 byte-a-byte (specs existentes de `executor_pipeline_spec.rb`/`executor_chat_spec.rb` continuam verdes sem alteração)
- [ ] `resolve_capabilities` chamado em `run_pipeline` entre Context e Policy, resultado guardado em `state.capability_names`; `policy_request`/`candidate_tools` permanecem intocados (só `tool_registry.entries`)
- [ ] `rescue CapabilityError` em `execute`, espelhando `rescue ContextError` (`stage: :capability`, sem evento próprio)
- [ ] Junção pós-Policy: `impl -> Capability::ResolvedTool -> ToolEnvelope` correta em `run_pipeline`, fora da `ToolAllowlist`, sem dupla-exposição de um impl_name simultaneamente direto e capability
- [ ] `ToolEnvelope#side_effect?`/`#approval_required?`/`#correlation_id` consultam `impl_name` quando o delegate responde a ele
- [ ] Suíte verde sem chave de API (RubyLLM mockado só na integração)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **COORDENAÇÃO:** Task 10 (Etapa B) também edita `configure_chat` (partição
  eager/deferred de Tool Search) — como esta task **não** toca
  `configure_chat` (o wrap correto fica em `run_pipeline`, fora dele), o
  conflito de arquivo com a task 10 fica restrito a mudanças de contexto ao
  redor (mesmo método, blocos de código diferentes). Ainda assim, sequenciar
  5 antes de 10 (ordem do plano) ou mesclar com atenção ao diff de
  `configure_chat`.
- **Fora do escopo original listado, mas necessário:** o ajuste do
  `ToolEnvelope` (Passo 6) não estava nos arquivos indicados inicialmente
  para esta task — sem ele, D4/L7 ficam incompletos (side-effect/aprovação
  de tools expostas via capability nunca disparam). Incluído aqui para a
  task fechar o critério de conclusão 2 da fatia (00-overview.md).
- **Histórico:** uma versão anterior deste detalhamento previa fundir as
  entries de capability em `candidate_tools`/`policy_request` (passando pela
  `ToolAllowlist`). A revisão do `P2B-01-capability-registry.md` (§Fluxo,
  L3) corrigiu isso: a Policy nunca vê tools de capability; o grant é só
  `profile.capabilities`, e a junção acontece depois de `@policy_engine.decide`.
  Este arquivo já reflete a versão corrigida — nada a reconciliar.
