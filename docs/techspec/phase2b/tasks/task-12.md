# Task 12 (P2B): Smoke E2E fatia B (capability + tool search)

> **Techspec:** [00-overview.md](../00-overview.md) (§Critério) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Med · **Etapa:** C

## Objetivo

Provar, com um teste E2E único, os 4 critérios de conclusão da fatia B
(`00-overview.md` §"Critério de conclusão da fatia"):

1. `:browse` com 2 providers de priority distinta resolve para o de maior
   priority; priority idêntica no topo (mesmo plugin) → `CapabilityAmbiguous`
   (turno falha em `:capability`); provider `available? == false` é descartado
   ANTES do desempate; toda resolução bem-sucedida emite `:capability_resolved`.
2. A tool chega ao modelo sob o nome ESTÁVEL da capability (não o `impl_name`);
   a Policy filtra pelo `impl_name` real.
3. Um agente com `tools_deferred` não recebe essas tools no prompt inicial; o
   modelo chama `tool_search("...")`, a(s) tool(s) relevante(s) são promovidas
   e ficam chamáveis; `:tool_search { query, matched }` é emitido;
   `tools_deferred: nil` reproduz a Fase 1 (tudo cabeado eager).
4. Suíte inteira verde sem chave de API (RubyLLM mockado só na integração) —
   critério herdado, este arquivo contribui como mais um spec da suíte.

## Dependências

| # | Task | Componente | Status |
|---|------|-----------|--------|
| 5 | Executor: capability assembly (resolve por `profile.capabilities` → join pós-Policy → `rescue :capability` → wrap `ResolvedTool`) | P2B-01 | ⬜ TODO |
| 10 | Executor `configure_chat`: partição eager/deferred + `ToolSearch` de sistema (catálogo vem do provider, task 8) | P2B-02 | ⬜ TODO |
| 11 | Wiring (`CAPABILITY_REGISTRY`+`TOOL_CATALOG`) + catálogo de eventos D5 | P2B-01/02 | ⬜ TODO |

Este task só compila/roda depois que 5, 10 e 11 estiverem mescladas — ele
consome a interface pública que essas tasks produzem (novos kwargs do
`Executor`, campos do `AgentProfile`, `CapabilityRegistry`, `ToolCatalog`,
eventos `:capability_resolved`/`:tool_search`). Nenhuma dessas tasks tem
arquivo escrito ainda neste repo (só `task-01.md`/`02`/`03`/`04`/`07`
existem em `docs/techspec/phase2b/tasks/`) — ver Notas sobre a task 9
especificamente.

## Contexto

A fatia A (Fase 2, `docs/techspec/phase2/tasks/task-14.md` — não existe mais
como arquivo neste repo, mas o resultado é `spec/e2e/smoke_resume_spec.rb`)
tinha uma dimensão de **crash/reboot**: o critério exigia sobreviver a
`kill -9` no meio do turno, o que exigiu subir um PROCESSO real
(`spec/support/smoke/serve.rb` + `boot_app.rb` + shim de `ruby_llm` via
`RUBYOPT=-I`) para poder matá-lo de verdade.

A fatia B **não tem** essa dimensão — nenhum dos 4 critérios envolve
durabilidade entre processos. Por isso este task reusa o padrão mais leve já
existente na suíte para integração real com `CommandBus` + `Executor` +
RubyLLM mockado **in-process**: `spec/harness/integration/send_message_flow_spec.rb`
(CommandBus real → handler `SendMessage` real → `Executor` real, só
`create_chat` stubado para devolver um `FakeChat` roteirizado de
`spec/support/fake_chat.rb`). Este é o MESMO espírito do smoke da fatia A
(RubyLLM mockado, sem chave de API, sem tocar a gem) só que sem o overhead de
subprocess — que aqui não compra nada (não há crash a sobreviver). O arquivo
fica em `spec/e2e/` e leva a tag `:smoke`, pela mesma convenção de
descoberta/localização do `smoke_resume_spec.rb` — mas os componentes
`CapabilityRegistry`, `ToolRegistry`, `Policy::Engine`+`ToolAllowlist`,
`ToolCatalog` e `AgentProfile` usados aqui são os de PRODUÇÃO (nada é
reimplementado); só o `chat` (RubyLLM) é o duplo.

**Risco D6 herdado (ver Notas):** a task 9 (`Tools::ToolSearch`) é quem prova,
contra o `ruby_llm` 1.16 real, se `chat.with_tools` chamado DENTRO de um
`execute` afeta o round seguinte do MESMO `ask` (promoção "no mesmo turno") ou
só o PRÓXIMO turno (fallback documentado em D6). O `FakeChat` desta suíte é um
duplo síncrono que não reproduz o loop real do `ruby_llm` — ele só prova que o
MECANISMO de código (`ToolSearch#execute` chama `chat.with_tools`, e a tool
promovida aparece em `chat.tools` e é chamável ali mesmo) funciona
deterministicamente. Isso é necessário mas não suficiente para fechar o
critério 3 contra o comportamento real da gem — essa prova é escopo exclusivo
da task 9. Este task assume o caminho PRIMÁRIO (mesmo turno, o mais simples de
testar e o que a P2B-02 descreve como fluxo principal) e documenta o ajuste
para o fallback de 2 turnos caso a task 9 conclua o contrário (ver Notas).

## Arquivos

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `spec/e2e/smoke_phase2b_spec.rb` | Suíte única cobrindo os 4 critérios (capability + tool search) |

Nada em `spec/support/smoke/*` (shim de subprocess da fatia A) é tocado —
esta fatia não precisa dele (ver Contexto). `spec/support/fake_chat.rb` já
expõe tudo que este spec precisa (`tools`, `script`, `with_tools`) sem
alteração.

## Passo a passo

### Passo 1 — Wiring auxiliar (registries + catálogo + perfis)

**Padrão de referência (codebase — `send_message_flow_spec.rb:10-32`, wiring
real com `let`s + stub de `create_chat`):**
```ruby
let(:executor) do
  Harness::Executor.new(
    context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
    middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
    tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
    profiles: { "sales" => profile }, session_store: session_store,
    task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream
  )
end
...
before do
  bus.register(:send_message, handler)
  allow(executor).to receive(:create_chat).and_return(scripted_chat)
end
```

Este task troca `NullPolicyEngine`/`FakeToolRegistry` (stubs de unidade) pelos
componentes REAIS de produção — é o que faz este spec um smoke E2E de verdade,
não um teste de pipeline isolado:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "async"

RSpec.describe "smoke E2E: capability resolution + tool search (fatia B)", :smoke do
  # Tool "crua" o bastante p/ passar pelo Registry/ToolEnvelope/ResolvedTool —
  # SimpleDelegator delega #call/#name/#description; nada de RubyLLM::Tool
  # exigido aqui (a tool em si não precisa herdar da gem, só respond_to?).
  class FakeCapTool
    def initialize(name) = (@name = name)
    def name = @name
    def description = "fake #{@name}"
    def call(_args = {}) = "executed:#{@name}"
  end

  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }

  let(:tool_registry)        { Harness::ToolRegistry.new }
  let(:capability_registry)  { Harness::CapabilityRegistry.new } # P2B-01 (task 1)
  let(:tool_catalog)         { Harness::ToolCatalog.new(tool_registry: tool_registry) } # P2B-02 (task 6)

  let(:policy_registry) do
    Harness::PolicyRegistry.new.tap { |r| r.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist) }
  end
  let(:policy_engine) { Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream) }

  let(:profiles) do
    {
      "cap_top" => Harness::AgentProfile.build(
        id: "cap_top", model: "fake", policies: [:tool_allowlist], capabilities: [:browse]
      ),
      "cap_deny_top" => Harness::AgentProfile.build(
        id: "cap_deny_top", model: "fake", policies: [:tool_allowlist],
        capabilities: [:browse], tools_deny: ["browser_b"]
      ),
      "cap_ambiguous" => Harness::AgentProfile.build(
        id: "cap_ambiguous", model: "fake", policies: [:tool_allowlist],
        capabilities: [:ambiguous_cap]
      ),
      "deferred_ok" => Harness::AgentProfile.build(
        id: "deferred_ok", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email], tools_deferred: ["send_email"]
      ),
      "deferred_nil" => Harness::AgentProfile.build(
        id: "deferred_nil", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email] # tools_deferred: nil (default) — paridade Fase 1
      )
    }
  end

  let(:executor) do
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: policy_engine,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      capability_registry: capability_registry, # NOVO kwarg (task 5), default nil
      tool_catalog: tool_catalog                 # NOVO kwarg (task 10), default nil
    )
  end

  let(:bus) do
    Harness::CommandBus.new(event_stream: event_stream).tap do |b|
      b.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end

  before do
    # Cada impl é uma tool NORMAL do registry (é assim que um plugin real
    # registraria: register_tool + register_capability sobre o MESMO
    # impl_name — P2B-01 fluxo) — necessário p/ o Executor instanciar via
    # factory quando a capability resolve para ele.
    %w[browser_a browser_b browser_c impl_x impl_y eager_tool send_email].each do |n|
      tool_registry.register(n) { FakeCapTool.new(n) }
    end

    # :browse — a=10/p1, b=50/p2, c=100/p3 mas INDISPONÍVEL (available? false).
    # Sem o filtro de disponibilidade, "c" venceria por priority; com ele, "b" vence.
    capability_registry.register(:browse, impl_name: "browser_a", kind: :tool, plugin: "p1", priority: 10)
    capability_registry.register(:browse, impl_name: "browser_b", kind: :tool, plugin: "p2", priority: 50)
    capability_registry.register(:browse, impl_name: "browser_c", kind: :tool, plugin: "p3", priority: 100,
                                 available: -> { false })

    # :ambiguous_cap — 2 providers do MESMO plugin "pA", mesma priority 50.
    # (P2B-01 L4: plugins DIFERENTES desempatam por ordem de registro; mesmo
    # plugin empatado é sempre CapabilityAmbiguous — ver task-01.md Notas.)
    capability_registry.register(:ambiguous_cap, impl_name: "impl_x", kind: :tool, plugin: "pA", priority: 50)
    capability_registry.register(:ambiguous_cap, impl_name: "impl_y", kind: :tool, plugin: "pA", priority: 50)
  end
```

### Passo 2 — Helper para disparar um turno síncrono

Sem `session_id` (one-shot), o turno NÃO passa pelo `SessionActor` mesmo com
`@supervised` — vai direto ao `spawn` (ver `executor.rb#spawn_in_session`).
Isso simplifica o helper em relação ao `dispatch_and_wait` de
`send_message_flow_spec.rb` (que precisa de `session_id`/`stop_session_actors`
porque testa serialização de sessão — fora de escopo aqui).

**Padrão de referência (codebase — `send_message_flow_spec.rb:58-80`,
adaptado: aqui não há sessão, então não há `SessionActor` a encerrar):**
```ruby
  TERMINAL = %w[completed failed cancelled].freeze

  def run_turn(agent:, chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = bus.dispatch(Harness::Command.build(:send_message, { agent: agent, message: "oi" }))
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end
```

### Passo 3 — Cenário 1: priority resolve + indisponível descartado + evento

```ruby
  it "resolve para o provider de maior priority disponível; descarta indisponível; emite :capability_resolved" do
    task, chat = run_turn(agent: "cap_top")
    expect(task.status).to eq(:completed)

    resolved = event_stream.events.find { |e| e.type == :capability_resolved }
    expect(resolved).not_to be_nil
    expect(resolved.data[:capability]).to eq(:browse)
    expect(resolved.data[:chosen]).to eq("browser_b") # vence "a" (priority 50 > 10)
    # "browser_c" (priority 100) NUNCA aparece — foi descartado por available? antes do ranking
    expect(resolved.data[:candidates].map { |c| c[:impl_name] }).to contain_exactly("browser_a", "browser_b")

    # nome ESTÁVEL exposto ao modelo (D4): o chat viu "browse", não "browser_b"
    tool = chat.tools.find { |t| t.respond_to?(:name) && t.name.to_s == "browse" }
    expect(tool).not_to be_nil
    expect(tool.impl_name).to eq("browser_b") if tool.respond_to?(:impl_name)
  end
```

### Passo 4 — Cenário 2: Policy filtra por `impl_name` dentro da resolução

```ruby
  it "a Policy (tools_deny) filtra por impl_name DENTRO da resolução, não só depois" do
    task, = run_turn(agent: "cap_deny_top") # tools_deny: ["browser_b"]
    expect(task.status).to eq(:completed)

    resolved = event_stream.events.select { |e| e.type == :capability_resolved }.last
    expect(resolved.data[:chosen]).to eq("browser_a") # "b" foi negado -> próximo elegível
  end
```

### Passo 5 — Cenário 3: empate no topo → `CapabilityAmbiguous` → turno falha

**Padrão de referência (codebase — `executor_pipeline_spec.rb:117-132`, forma
de asserir estágio via `task.executions.last.error`):**
```ruby
expect(task.executions.last.error).to include("stage" => "policy")
```

```ruby
  it "empate no topo (mesma priority, mesmo plugin) -> CapabilityAmbiguous; turno falha em :capability" do
    task, = run_turn(agent: "cap_ambiguous")

    expect(task.status).to eq(:failed)
    expect(task.executions.last.error["class"]).to eq("Harness::CapabilityAmbiguous")
    expect(task.executions.last.error["stage"]).to eq("capability")
    expect(event_stream.types).to include(:task_failed, :error)
    # D7: CapabilityAmbiguous NÃO ganha evento próprio — nunca aparece :capability_resolved p/ esta capability
    expect(event_stream.events.select { |e| e.type == :capability_resolved }).to be_empty
  end
```

### Passo 6 — Cenário 4: Tool Search — deferred não aparece de cara; promove; chamável

O script do `FakeChat` roda `instance_exec`'ado NO CONTEXTO do chat (`self` =
`FakeChat`), então `expect(...)` não é chamável ali dentro (o `FakeChat` não
inclui `RSpec::Matchers`) — captura os fatos em variáveis locais fechadas pelo
proc (closures Ruby não são afetadas por `instance_exec`, só `self` muda) e
asserta DEPOIS, fora do script:

```ruby
  it "tools_deferred não aparece de cara; tool_search promove; chamável no mesmo turno; emite :tool_search" do
    initial_names = nil
    promoted_result = nil
    chat = FakeChat.new
    chat.script = proc do
      initial_names = tools.map { |t| t.name.to_s }
      ts = tools.find { |t| t.name.to_s == "tool_search" }
      ts.execute(query: "enviar email")
      promoted = tools.find { |t| t.name.to_s == "send_email" }
      promoted_result = promoted&.call({})
    end

    task, = run_turn(agent: "deferred_ok", chat: chat)
    expect(task.status).to eq(:completed)

    expect(initial_names).to include("eager_tool", "tool_search")
    expect(initial_names).not_to include("send_email") # deferred: fora do prompt inicial

    expect(promoted_result).to eq("executed:send_email") # promovida + chamável NO MESMO turno (D6, caminho primário)

    ev = event_stream.events.find { |e| e.type == :tool_search }
    expect(ev).not_to be_nil
    expect(ev.data[:query]).to eq("enviar email")
    expect(ev.data[:matched]).to include("send_email")
  end
```

### Passo 7 — Cenário 5: `tools_deferred: nil` → paridade Fase 1

```ruby
  it "tools_deferred: nil -> paridade Fase 1 (tudo cabeado eager, sem tool_search de sistema)" do
    seen_names = nil
    chat = FakeChat.new
    chat.script = proc { seen_names = tools.map { |t| t.name.to_s } }

    task, = run_turn(agent: "deferred_nil", chat: chat)
    expect(task.status).to eq(:completed)

    expect(seen_names).to include("eager_tool", "send_email")
    expect(seen_names).not_to include("tool_search") # sem deferred, sem builtin de sistema
  end
end
```

## Edge cases

1. **Empate de priority entre plugins DIFERENTES não é ambíguo** (L4 da
   task-01): não testado neste smoke (é unit da task 1) — aqui só o caso
   ambíguo real (mesmo plugin) fecha o critério 1.
2. **`available? == false` descartado ANTES do ranking**: coberto no Cenário 1
   (`browser_c`, priority mais alta, nunca aparece nos `candidates` do
   evento nem é escolhido).
3. **Nome estável vs `impl_name` na Policy**: o Cenário 1 asserta `tool.name ==
   "browse"` (o que o modelo vê) separadamente de `tool.impl_name ==
   "browser_b"` (o que a Policy decidiu) — não confundir os dois no assert.
4. **Exposição direta dos impls além da capability**: como `cap_top`/
   `cap_deny_top` usam `tools_allow: nil` (irrestrito), `browser_a`/`browser_b`
   também podem aparecer em `chat.tools` sob o PRÓPRIO nome (além de
   `"browse"` renomeado) — isso é uma interação esperada da semântica `nil =
   todas` reaplicada pela task 1/5 sobre `candidate_tools`, não um defeito
   deste smoke. Por isso os cenários 1/2 NÃO asserem exclusividade
   (`chat.tools` == só isso); só presença do nome certo com o `impl_name`
   certo. Se um deployment real quiser esconder o impl da exposição direta,
   precisa de um design à parte (não coberto pela P2B-01 atual — ver Notas).
5. **Deferred não aparece de cara**: Cenário 4, `initial_names` (capturado
   ANTES da promoção, dentro do próprio `script`) não inclui `"send_email"`.
6. **Promoção no mesmo turno OU em dois turnos**: este arquivo assume o
   caminho PRIMÁRIO (D6, mesmo `ask`) porque é o que o `FakeChat` síncrono
   consegue exercitar deterministicamente. Se a task 9 (ao validar contra
   `ruby_llm` 1.16 real) concluir o fallback, o Cenário 4 deste arquivo PRECISA
   virar dois turnos — ver Notas para o esqueleto do ajuste.
7. **Paridade Fase 1 com `tools_deferred: nil`**: Cenário 5 — nenhuma tool
   escondida, sem `tool_search` de sistema no chat.

## Testes

Este arquivo **é** o teste (task só de integração/smoke, sem código de
produção novo). Cenários:

| # | Caso | O que exercita | Esperado |
|---|------|-----------------|----------|
| 1 | `cap_top` | 2 providers disponíveis + 1 indisponível de priority mais alta | resolve `"browser_b"`; `"browser_c"` fora dos candidatos; `:capability_resolved` com `chosen`/`candidates` corretos; chat vê tool `"browse"` (nome estável) com `impl_name == "browser_b"` |
| 2 | `cap_deny_top` | `tools_deny` cobre o impl vencedor | resolve `"browser_a"` (próximo elegível) — Policy filtra `impl_name` DENTRO da resolução |
| 3 | `cap_ambiguous` | 2 providers mesmo plugin, mesma priority | turno `:failed`; `error["class"] == "Harness::CapabilityAmbiguous"`; `error["stage"] == "capability"`; nenhum `:capability_resolved` emitido para essa capability |
| 4 | `deferred_ok` | tool `send_email` deferred; modelo chama `tool_search` | `send_email` ausente do `chat.tools` inicial; presente e CHAMÁVEL após `tool_search`; `:tool_search { query, matched }` emitido |
| 5 | `deferred_nil` | `tools_deferred` omitido | todas as `allowed_tools` cabeadas eager; sem tool `tool_search` de sistema no chat |

## Definition of Done

- [ ] Os 4 critérios de conclusão da fatia B verdes (00-overview §"Critério de
      conclusão da fatia"), cada um coberto por ≥1 exemplo deste arquivo
- [ ] Cenário 4 confirmado contra o desfecho REAL da task 9 (mesmo turno ou
      fallback de 2 turnos — ver Notas) antes de fechar esta task
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Dependência não fechada no momento da escrita deste doc:** as tasks 5, 9,
  10 e 11 ainda não têm `task-NN.md` neste repo (só 01/02/03/04/07 existem em
  `docs/techspec/phase2b/tasks/`) — em particular a task 9 (`Tools::ToolSearch`,
  o "gargalo de risco" apontado em `tasks.md` §"Concerns") ainda não provou o
  comportamento do `ruby_llm` 1.16 quanto a `with_tools` dentro de um
  `execute` afetar o round seguinte do MESMO `ask`. Este arquivo assume o
  caminho PRIMÁRIO (mesmo turno) por ser o único demonstrável de forma
  determinística com um `FakeChat` síncrono (que não reproduz o loop real da
  gem) — **não é uma prova independente do comportamento real da gem**, só do
  mecanismo de código (`ToolSearch#execute` chama `chat.with_tools`).
- **Ajuste se a task 9 confirmar o fallback D6** (promoção só visível no
  PRÓXIMO turno): o Cenário 4 (Passo 6) precisa virar 2 turnos:
  - Turno 1 (chat A, perfil `deferred_ok`): script só chama
    `ts.execute(query: "enviar email")`; asserta `:tool_search` emitido e que
    `chat.tools` (NESTE chat) ainda NÃO inclui `"send_email"` chamável (a
    promoção não "grudou" no mesmo `ask`).
  - Turno 2 (chat B, MESMA sessão/profile, SEM chamar `tool_search` de novo):
    asserta que `chat.tools` (o array que `configure_chat` monta neste NOVO
    turno) já inclui `"send_email"` cabeada EAGER — prova que a promoção do
    turno anterior persistiu via `TurnState`/checkpoint (D6 fallback).
  - O mecanismo exato de persistência (nome do campo no checkpoint/TurnState)
    é decisão da task 9/10, ainda não especificada além do apontamento em D6
    — ajustar os nomes assim que essas tasks fecharem.
- **Nomes de kwarg assumidos** (`capability_registry:`, `tool_catalog:` no
  `Executor.new`) seguem a nomenclatura natural sugerida pelas seções
  "Integração no Executor" de `P2B-01`/`P2B-02` (`@capability_registry`,
  `@tool_catalog`) — confirmar contra a assinatura real produzida pela task 5
  e pela task 10 ao implementar; ajustar este spec se divergir.
- **Gap de design observado, fora de escopo desta task** (edge case 4): não há
  hoje (P2B-01/L3) um jeito de expor uma capability sob nome estável
  ESCONDENDO o `impl_name` de exposição direta — `tools_deny` no impl também
  remove o candidato da resolução (deny sempre vence), e `tools_allow` restrito
  ao necessário para a resolução também libera o impl diretamente. Sinalizar
  no review da task 5 caso vire um requisito; não é bloqueio para fechar o
  critério de conclusão da fatia (que só exige o nome estável aparecer e a
  Policy filtrar por impl_name, ambos cobertos).
- Este arquivo não toca `spec/support/smoke/*` (o shim de subprocess da fatia
  A) — deliberado (ver Contexto). Se um critério futuro da fatia B vier a
  exigir durabilidade entre processos, esse shim é o ponto de partida certo
  (`boot_app.rb` + `shims/ruby_llm.rb`), não este arquivo.
