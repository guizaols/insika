# Task 08 (P2C): Smoke E2E fatia C (memória cross-session)

> **Techspec:** [00-overview.md](../00-overview.md) (§Critério) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Provar, com um teste E2E único, os 4 critérios de conclusão da fatia C
(`00-overview.md` §"Critério de conclusão da fatia", espelhado em
`P2C-02-remember-tool-and-wiring.md` §"Smoke E2E"):

1. Um agente com `memory: true` chama `remember(key: "plano", value:
   "premium")` na **sessão 1**; `:memory_written { kind: "fact", key: "plano"
   }` é emitido; o fato persiste no `MemoryStore` escopado pelo tenant.
2. Numa **sessão 2 nova** (mesmo tenant, mesmo agente), o
   `Context::Providers::Memory` recupera o fato e injeta `<memory>` no
   `system` do turno — o agente "lembra" sem ter sido dito de novo.
3. `remember(value: "cliente prefere email")` (sem `key`) grava uma **note**;
   `:memory_written { kind: "note" }` é emitido; notes recentes aparecem no
   contexto da sessão seguinte.
4. Um agente com `memory: nil` (default) não recebe o fragmento de memória
   nem a tool `remember` — **paridade Fase 1**, mesmo quando o TENANT já tem
   memória gravada (a única coisa que muda é o perfil).
5. Suíte inteira verde sem chave de API (store/provider/tool determinísticos;
   RubyLLM mockado só na integração) — critério herdado, este arquivo
   contribui como mais um spec da suíte.

O tenant flui via `Command.build(:send_message, payload, tenant: "acme")` —
prova o threading D6 ponta a ponta (Command → Task persistida →
`Executor#command_tenant` → `ContextRequest#tenant`/`TurnState#tenant` → o
provider de leitura E a tool `remember` usam o MESMO scope).

## Dependências

| # | Task | Componente | Status |
|---|------|-----------|--------|
| 4 | `Context::Providers::Memory` (read: facts + N notes recentes → fragmento `:system` p75; `enabled_for?` por `profile.memory`) | P2C-01 | ⬜ TODO |
| 6 | Executor `configure_chat`: cabeia `remember` de sistema (gate `@memory_store` + `profile.memory`) + `create_chat` lazy require | P2C-02 | ⬜ TODO |
| 7 | Wiring: `MEMORY_STORE` + provider em `CONTEXT_PROVIDERS` + inject no Executor + catálogo D5 (`:memory_written`) + wiring-load spec | P2C-02 | ⬜ TODO |

Transitivamente depende também das tasks 1 (`MemoryStore`), 2
(`AgentProfile.memory`) e 3 (tenant threading no `Executor`/`TurnState`) — são
pré-requisitos de 4 e 6, mas este spec só CONSOME a interface pública que elas
produzem (não reimplementa nada). Só compila/roda depois que 1–7 estiverem
mescladas, exatamente como o task-12 da fatia B dependia de 5/9/10/11. Nenhuma
das classes usadas aqui (`Harness::MemoryStore`,
`Harness::Context::Providers::Memory`, `Harness::Tools::Remember`,
`AgentProfile.memory`, `Executor#memory_store`) existe neste repo no momento
em que este doc foi escrito — ver Notas.

## Contexto

Herda o MESMO padrão do `spec/e2e/smoke_phase2b_spec.rb` (task-12 da fatia
B): `CommandBus` real → handler `SendMessage` real → `Executor` real, com
`ToolRegistry`/`PolicyRegistry`+`Policy::Engine`/`AgentProfile`/`SkillCatalog`
de PRODUÇÃO — só o `chat` (RubyLLM) é o duplo (`FakeChat` via stub de
`create_chat`). Sem dimensão de crash/reboot, in-process, sem subprocess
(mesmo raciocínio do Contexto do task-12).

**A ÚNICA diferença estrutural relevante em relação ao task-12: o
`context_builder`.** O smoke da fatia B usa `FakeContextBuilder` (de
`spec/support/fakes.rb`) porque nenhum dos 4 critérios da fatia B dependia do
CONTEÚDO do `system` — só de `chat.tools`/eventos. Aqui o critério 2 e o
critério 3 (segunda metade) exigem literalmente que o fragmento `<memory>`
apareça no `system` do turno — e `FakeContextBuilder#call` (fakes.rb:12-21)
**não roda providers nenhum**: monta `ContextPackage.new(request.profile.
base_prompt.to_s, history, nil)` na mão, ignorando completamente o
`Context::Providers::Memory`. Usá-lo aqui provaria zero sobre o read path —
o teste passaria mesmo que o provider estivesse quebrado. Por isso este spec
constrói um `Harness::ContextBuilder` REAL (`lib/harness/context/builder.rb`),
com uma lista de providers mínima:

```ruby
Harness::ContextBuilder.new(
  providers: [
    Harness::Context::Providers::Prompt.new(base: "Você é um agente de teste."),
    Harness::Context::Providers::Memory.new(store: memory_store, notes_limit: 10)
  ],
  event_stream: event_stream, hooks: NullHooks.new
)
```

- **Prompt** entra porque é `required? == true` (identidade pinned) — é o
  provider mais barato de satisfazer e deixa o wiring mais fiel ao
  `config/wiring.rb` real (que sempre tem Prompt); não é estritamente
  necessário para os 4 critérios, mas evitar um `ContextBuilder` com um único
  provider "de propósito" reduz a distância entre este smoke e a composição
  real.
- **Request**, **Skill**, **ToolSearch** e **Session** (os outros providers de
  `CONTEXT_PROVIDERS` em `config/wiring.rb:71-79`) ficam de fora
  deliberadamente: nenhum dos 4 critérios os exercita, e a `Session`
  provider em particular tornaria o teste sensível a comportamento de
  histórico que não é o que está sob teste aqui (a fatia C não muda nada
  sobre histórico). `assemble_tool_instances`/`resolve_capabilities`
  (P2B) também não entram — não há `capability_registry`/`tool_catalog`
  neste smoke (`nil` nos dois, default do `Executor`, paridade).
- **`NullHooks`** (fakes.rb) serve tanto para o `ContextBuilder` quanto para o
  `Executor` — é passthrough puro (`around(pair, subject) { yield subject }`),
  compatível com a assinatura que ambos esperam.

**Captura do `system`:** o `Executor#configure_chat` (executor.rb:672-674) faz
`chat.with_instructions(system) unless system.empty?`. O `FakeChat`
(`spec/support/fake_chat.rb:11,27-30`) já expõe `attr_reader :instructions`,
setado dentro de `with_instructions` — **não é preciso capturar nada de
dentro do `chat.script`** (o `with_instructions` roda em `configure_chat`,
ANTES do `chat.ask`/script rodar). Basta ler `chat.instructions` depois que
`run_turn` retorna. Isso é mais simples do que a redação de
`P2C-02-remember-tool-and-wiring.md` §"Smoke E2E" sugere ("o `system` do chat,
capturado no script do `FakeChat`") — ver Notas sobre esse ajuste.

**`MemoryStore`/`Context::Providers::Memory` NÃO precisam de require
explícito** (diferente de `Tools::Remember`): são classes puras (sem
`RubyLLM::Tool`), como o `PendingActionStore` — entram em `lib/harness.rb`
direto (tasks 1 e 4) e já estão carregadas via `require_relative
"../lib/harness"` do `spec_helper.rb`. **`Tools::Remember` PRECISA** do
require explícito (`require "harness/tools/remember"` no topo do arquivo),
igual a `load_skill`/`tool_search` no `smoke_phase2b_spec.rb` — ela herda de
`RubyLLM::Tool` e o `Executor` só a carrega lazy DENTRO de `configure_chat`
(D9); como `create_chat` é stubado aqui (`allow(executor).to
receive(:create_chat)`), esse require lazy nunca roda.

**Duas "sessões" = dois `session_id` distintos, mesmo tenant.** A redação do
critério ("sessão 1"/"sessão 2 nova") é literal: usa-se
`session_store.create(id: ...)` (SessionStore real) para cada uma, e o MESMO
`tenant: "acme"` no `Command.build` de cada turno — não turnos one-shot sem
`session_id`. Isso é deliberado: o `MemoryStore` é escopado por TENANT, não
por `session_id` (D2 do overview — "NÃO escopar por session_id, seria
session-scoped, anularia o cross-session"), então o teste precisa mostrar
sessões (conversas) DIFERENTES enxergando a MESMA memória — usar dois
`session_id`s reais é a prova mais literal disso, mesmo que o mecanismo
funcionasse igual com dois turnos one-shot (o scope não olha pra
`session_id` de qualquer forma).

**Isolamento por `it` (RSpec random order, `spec_helper.rb:20`):** cada `it`
tem seu próprio `backend`/`memory_store` (memoizados por exemplo via `let` —
não sobrevivem entre `it`s). Os critérios 1 e 2 são causalmente encadeados
("escreve na sessão 1, lê na sessão 2") mas viram DOIS `it`s independentes:
o critério 1 prova a ESCRITA via a tool (turno real, `remember` chamada pelo
"modelo"); o critério 2 SEMEIA o fato direto no `MemoryStore`
(`memory_store.put_fact(...)`, bypassando a tool) e roda só o turno de
LEITURA. Isso isola a asserção (o critério 2 testa o provider de leitura +
wiring, não re-testa a tool de escrita, que o critério 1 já cobre
exaustivamente) e evita duplicar a mecânica de "rodar um turno de escrita"
em todo `it` só para popular o estado — sem abrir mão de nenhuma garantia dos
critérios (a suíte de contrato do `MemoryStore`, task 1, já prova que
`put_fact`/`add_note` fazem exatamente o que a tool faz por baixo). O
critério 4 (paridade) semeia fato E note para o MESMO tenant "acme" por essa
mesma via direta, de propósito: prova que o gate é o `profile.memory`, não a
ausência de dado no tenant.

## Arquivos

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `spec/e2e/smoke_phase2c_spec.rb` | Suíte única cobrindo os 4 critérios (memória cross-session) |

Nenhum arquivo de produção é tocado por esta task (é só o smoke). Reusa
`spec/support/fakes.rb` (`NullHooks`, `PassthroughMiddleware`, `SpyEventStream`)
e `spec/support/fake_chat.rb` sem alteração — nenhum dos dois precisa de
ajuste para este cenário.

## Passo a passo

### Passo 1 — Wiring auxiliar (stores reais + `MemoryStore` + `ContextBuilder` real)

**Padrão de referência (codebase — `smoke_phase2b_spec.rb:25-38`, adaptado:
troca `FakeContextBuilder` por um `Harness::ContextBuilder` real com
Prompt+Memory, acrescenta `memory_store`):**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "async"
# O Executor a carrega lazy em create_chat; aqui create_chat é stubado, então
# requeremos explícito (mesma disciplina do smoke_phase2b_spec — load_skill/
# tool_search). MemoryStore e Context::Providers::Memory NÃO precisam disso
# (classes puras, sem RubyLLM::Tool — já entram via `require "harness"`).
require "harness/tools/remember"

# Smoke E2E da fatia C (P2C): CommandBus + SendMessage + Executor + RubyLLM
# mockado (FakeChat via stub de create_chat). Componentes REAIS: MemoryStore,
# Context::Providers::Memory, ContextBuilder, AgentProfile, Policy::Engine +
# ToolAllowlist. Só o `chat` é duplo — ver Contexto sobre por que o
# ContextBuilder também é REAL aqui (diferente do smoke_phase2b).
RSpec.describe "smoke E2E: memória cross-session (fatia C)", :smoke do
  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }

  let(:memory_store)  { Harness::MemoryStore.new(store: backend) } # P2C-01 (task 1)
  let(:tool_registry) { Harness::ToolRegistry.new } # vazio: `remember` é tool de SISTEMA, não passa por aqui

  let(:policy_registry) do
    Harness::PolicyRegistry.new.tap { |r| r.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist) }
  end
  let(:policy_engine) { Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream) }

  # ContextBuilder REAL (não FakeContextBuilder!) — só assim o
  # Context::Providers::Memory roda de verdade (ver Contexto).
  let(:context_builder) do
    Harness::ContextBuilder.new(
      providers: [
        Harness::Context::Providers::Prompt.new(base: "Você é um agente de teste."),
        Harness::Context::Providers::Memory.new(store: memory_store, notes_limit: 10) # P2C-01 (task 4)
      ],
      event_stream: event_stream, hooks: NullHooks.new
    )
  end

  let(:profiles) do
    {
      "rememberer" => Harness::AgentProfile.build(
        id: "rememberer", model: "fake", policies: [:tool_allowlist], memory: true # P2C-01 (task 2)
      ),
      "no_memory" => Harness::AgentProfile.build(
        id: "no_memory", model: "fake", policies: [:tool_allowlist] # memory: nil (default) — paridade
      )
    }
  end

  let(:executor) do
    Harness::Executor.new(
      context_builder: context_builder, policy_engine: policy_engine,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      memory_store: memory_store # NOVO kwarg (P2C-02, task 6/7)
    )
  end

  let(:bus) do
    Harness::CommandBus.new(event_stream: event_stream).tap do |b|
      b.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end
```

### Passo 2 — Helper para disparar um turno síncrono (com `session_id`+`tenant`)

**Padrão de referência (codebase — `smoke_phase2b_spec.rb:98-114`, adaptado:
acrescenta `session_id`/`tenant` ao payload/Command, já que a fatia C precisa
das DUAS dimensões, diferente da fatia B que não usava sessão nem tenant):**

```ruby
  TERMINAL = %w[completed failed cancelled].freeze

  def run_turn(agent:, tenant:, session_id: nil, message: "oi", chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    payload = { agent: agent, message: message }
    payload[:session_id] = session_id if session_id

    result = nil
    Sync do |parent|
      result = bus.dispatch(Harness::Command.build(:send_message, payload, tenant: tenant)) # D6
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end
```

### Passo 3 — Cenário 1: grava fato via tool na sessão 1

O "modelo" (roteirizado no `FakeChat#script`) chama a tool `remember` — a
mesma tool que `configure_chat` cabeou de sistema porque
`@memory_store && state.profile.memory` (P2C-02 §"Integração no Executor").

```ruby
  it "sessão 1: remember(key: 'plano', value: 'premium') grava fato; emite :memory_written; persiste no MemoryStore" do
    session_store.create(id: "sess-1")
    chat = FakeChat.new
    chat.script = proc do
      tool = tools.find { |t| t.name.to_s == "remember" }
      tool.execute(key: "plano", value: "premium")
    end

    task, = run_turn(agent: "rememberer", tenant: "acme", session_id: "sess-1", chat: chat)
    expect(task.status).to eq(:completed)

    ev = event_stream.events.find { |e| e.type == :memory_written }
    expect(ev).not_to be_nil
    expect(ev.data).to eq(kind: "fact", key: "plano")

    fact = memory_store.get_fact(tenant: "acme", key: "plano")
    expect(fact.value).to eq("premium")
  end
```

### Passo 4 — Cenário 2: sessão 2 nova (mesmo tenant) lembra o fato

Semeia o `MemoryStore` DIRETO (a escrita via tool já foi provada isolada no
Cenário 1 — ver Contexto) e roda só o turno de LEITURA numa sessão nova.

```ruby
  it "sessão 2 nova (mesmo tenant): <memory> no system reflete o fato gravado na sessão 1" do
    memory_store.put_fact(tenant: "acme", key: "plano", value: "premium")
    session_store.create(id: "sess-2")

    task, chat = run_turn(agent: "rememberer", tenant: "acme", session_id: "sess-2")
    expect(task.status).to eq(:completed)

    expect(chat.instructions).to include("<memory>")
    expect(chat.instructions).to match(/key="plano">\s*premium/)
  end
```

### Passo 5 — Cenário 3: note (sem `key`) — grava + aparece na sessão seguinte

```ruby
  it "remember sem key grava note; :memory_written {kind: note}; a note aparece no contexto da sessão seguinte" do
    session_store.create(id: "sess-3a")
    chat_write = FakeChat.new
    chat_write.script = proc do
      tool = tools.find { |t| t.name.to_s == "remember" }
      tool.execute(value: "cliente prefere email")
    end

    task_a, = run_turn(agent: "rememberer", tenant: "acme", session_id: "sess-3a", chat: chat_write)
    expect(task_a.status).to eq(:completed)

    ev = event_stream.events.find { |e| e.type == :memory_written }
    expect(ev.data[:kind]).to eq("note")
    expect(ev.data[:key]).not_to be_nil # id da note, não uma key de fato

    expect(memory_store.notes(tenant: "acme").map(&:text)).to include("cliente prefere email")

    session_store.create(id: "sess-3b")
    task_b, chat_read = run_turn(agent: "rememberer", tenant: "acme", session_id: "sess-3b")
    expect(task_b.status).to eq(:completed)
    expect(chat_read.instructions).to include("<memory>", "cliente prefere email")
  end
```

### Passo 6 — Cenário 4: paridade — `memory: nil` não recebe fragmento nem tool

Semeia fato E note para o MESMO tenant "acme" de propósito: prova que o gate
é o `profile.memory` (D5), não a ausência de memória gravada para o tenant.

```ruby
  it "memory: nil (default) -> sem <memory> no system, sem tool remember (paridade Fase 1)" do
    memory_store.put_fact(tenant: "acme", key: "plano", value: "premium")
    memory_store.add_note(tenant: "acme", text: "cliente prefere email")
    session_store.create(id: "sess-4")

    seen_names = nil
    chat = FakeChat.new
    chat.script = proc { seen_names = tools.map { |t| t.name.to_s } }

    task, = run_turn(agent: "no_memory", tenant: "acme", session_id: "sess-4", chat: chat)
    expect(task.status).to eq(:completed)

    expect(chat.instructions.to_s).not_to include("<memory>")
    expect(seen_names).not_to include("remember")
  end
end
```

## Edge cases

1. **`FakeContextBuilder` não serve para este smoke** (ver Contexto): não
   roda providers, então usá-lo tornaria os critérios 2/3 (leitura) vácuos —
   passariam mesmo com o `Context::Providers::Memory` quebrado. Resolvido
   com `Harness::ContextBuilder` real + lista mínima de providers.
2. **`chat.instructions` já basta** — não é preciso instrumentar o
   `chat.script` para capturar o `system`: `with_instructions` roda em
   `configure_chat`, antes do `ask`/script (executor.rb:672-674,
   fake_chat.rb:27-30). Ver Notas sobre o desvio da redação original do
   P2C-02.
3. **Isolamento por `it` via `let`** (RSpec random order): `memory_store`/
   `backend` são memoizados POR EXEMPLO — nada escrito num `it` sobrevive
   para o próximo. Cenários 2-4 semeiam o estado que precisam direto no
   `MemoryStore`, em vez de depender de ordem de execução entre `it`s (ver
   Contexto).
4. **Duas sessões reais, mesmo tenant** — o `MemoryStore` é escopado só por
   tenant (D2); usar `session_id`s DIFERENTES via `SessionStore.create` (não
   turnos one-shot) é a prova mais literal do enunciado "sessão 1"/"sessão 2
   nova", mesmo que o mecanismo de scope não olhe para `session_id`.
   `SendMessage#call` exige que a sessão já exista
   (`@session_store.find(p[:session_id]) || raise NotFoundError`) — por isso
   todo `session_id` usado é criado via `session_store.create(id: ...)` ANTES
   do `run_turn`.
5. **Tenant chega ao `remember` E ao provider pelo MESMO caminho (D6)** — não
   testado por asserção redundante separada aqui (seria reimplementar o
   teste da task 3); a PROVA é indireta e suficiente: o Cenário 1 grava com
   `tenant: "acme"` via Command, e `memory_store.get_fact(tenant: "acme",
   ...)` só encontra o fato porque a tool usou o MESMO scope — se o threading
   estivesse quebrado (ex.: tool sempre usando `_default`), a asserção do
   Cenário 1 falharia.
6. **Note tem `id` gerado (`SecureRandom.uuid`), não uma `key` legível** — a
   asserção do evento no Cenário 3 checa só `ev.data[:key]).not_to be_nil`
   (presença), não um valor fixo — o id é não-determinístico por design
   (P2C-02 `Tools::Remember#execute`).
7. **Paridade não é "tenant vazio"** — Cenário 4 semeia fato+note para
   "acme" (o MESMO tenant usado nos outros cenários) de propósito, para que
   a ausência de `<memory>`/tool seja atribuível SÓ ao gate de perfil, não a
   coincidência de tenant sem dado.
8. **Sem `capability_registry`/`tool_catalog`** — este smoke não exercita
   Tool Search/Capability (fatia B); ambos ficam `nil` (default do
   `Executor`), paridade com qualquer wiring que não os declare.

## Testes

Este arquivo **é** o teste (task só de integração/smoke, sem código de
produção novo). Cenários:

| # | Caso | O que exercita | Esperado |
|---|------|-----------------|----------|
| 1 | `rememberer`, sessão 1 | modelo chama `remember(key:, value:)` | `:memory_written {kind: "fact", key: "plano"}` emitido; `MemoryStore.get_fact(tenant: "acme", key: "plano").value == "premium"` |
| 2 | `rememberer`, sessão 2 nova (fato pré-semeado) | `Context::Providers::Memory` (read) + `ContextBuilder` real + wiring | `chat.instructions` inclui `<memory>` com `plano`/`premium` |
| 3 | `rememberer`, sessão 3a (write) → sessão 3b (read) | `remember` sem `key` grava note; note aparece na leitura seguinte | `:memory_written {kind: "note"}`; `memory_store.notes` inclui o texto; `chat.instructions` da sessão 3b inclui `<memory>` + o texto da note |
| 4 | `no_memory`, mesmo tenant com memória já gravada | `enabled_for?(profile)` do provider + gate duplo do `configure_chat` (`@memory_store` + `profile.memory`) | `chat.instructions` SEM `<memory>`; `chat.tools` SEM `remember` |

## Definition of Done

- [ ] Os 4 critérios de conclusão da fatia C verdes (00-overview.md
      §"Critério de conclusão da fatia"), cada um coberto por ≥1 exemplo
      deste arquivo
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Nenhuma das classes usadas por este spec existe no repo no momento em
  que este doc foi escrito** (`Harness::MemoryStore`,
  `Harness::Context::Providers::Memory`, `Harness::Tools::Remember`,
  `AgentProfile.memory`, `Executor#memory_store`) — só os docs `P2C-01`/
  `P2C-02` as especificam. As assinaturas usadas aqui (`MemoryStore.new
  (store:)`, `#put_fact(tenant:, key:, value:)`, `#get_fact(tenant:, key:)`,
  `#add_note(tenant:, text:)`, `#notes(tenant:, limit:)`,
  `Context::Providers::Memory.new(store:, notes_limit:)`,
  `AgentProfile.build(..., memory:)`, `Executor.new(..., memory_store:)`)
  seguem EXATAMENTE o que `P2C-01-memory-store-and-read.md` e
  `P2C-02-remember-tool-and-wiring.md` documentam — confirmar contra a
  implementação real das tasks 1-7 ao escrever o código; ajustar este spec
  se algum nome divergir (mesmo aviso que o task-12 fez para
  `capability_registry:`/`tool_catalog:`).
- **Desvio da redação do P2C-02 §"Smoke E2E" (mismatch documentado, conforme
  pedido):** o doc descreve o critério 2 como "o `system` do chat (capturado
  no script do `FakeChat`) inclui `<memory>`" — sugerindo que seria preciso
  capturar o `system` de DENTRO do `chat.script` (como o Cenário 4 do
  `smoke_phase2b_spec.rb` faz para `tools`, via closure). Isso não é
  necessário aqui: `configure_chat` chama `chat.with_instructions(system)`
  ANTES de `chat.ask` (que é quem roda o `script`), e o `FakeChat` já expõe
  `attr_reader :instructions` setado ali dentro (`fake_chat.rb:11,27-30`).
  Basta ler `chat.instructions` depois que `run_turn` retorna — mais simples
  e não exige um `script` customizado para os cenários que só leem memória
  (Cenários 2 e a metade de leitura do 3). Nenhuma garantia é perdida: a
  asserção é sobre o MESMO valor, só lido de um lugar mais direto.
- **Por que o `ContextBuilder` é real aqui e não na fatia B:** a fatia B
  (task-12) não tinha nenhum critério sobre CONTEÚDO do `system` — só sobre
  `chat.tools`/eventos — então `FakeContextBuilder` bastava. A fatia C
  introduz o primeiro critério de smoke que depende de um Context Provider
  específico produzir o fragmento certo; usar o fake aqui daria um FALSO
  VERDE (o teste passaria mesmo com o provider quebrado). Esta é a
  divergência de padrão mais importante deste task em relação ao
  `smoke_phase2b_spec.rb` — sinalizada explicitamente conforme pedido.
- **Isolamento por `it` via semeadura direta no `MemoryStore`** (Cenários
  2-4): alternativa deliberada a encadear tudo num `it` só (como o
  `smoke_phase2b_spec.rb` fez para a promoção do Tool Search dentro do MESMO
  turno). Rejeitada aqui porque re-rodar um turno de escrita em todo `it` só
  para popular estado (a) duplicaria a mecânica já provada exaustivamente no
  Cenário 1 e (b) acoplaria os cenários de leitura a qualquer regressão do
  write path, tornando a falha menos localizável. A suíte de contrato do
  `MemoryStore` (task 1) já garante que `put_fact`/`add_note` fazem
  exatamente o que a tool faz por baixo — semear direto é seguro e mais
  isolado.
- **`tools_deny`/`tools_allow` não entram neste smoke** — os perfis usados
  (`rememberer`/`no_memory`) não declaram `tools_allow` (default `nil` =
  todas as diretas do `tool_registry`, que está vazio de propósito); a
  tool `remember` nunca passa pela `ToolAllowlist` (é de sistema, como
  `load_skill`/`tool_search`) — nada aqui testa interação
  `remember`×`tools_deny` (fora de escopo do critério de conclusão da
  fatia; não é um gap, é um não-requisito).
