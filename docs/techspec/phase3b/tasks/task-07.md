# Task 07 (P3B): Smoke E2E loopback (federação outbound→inbound)

> **Techspec:** [00-overview.md](../00-overview.md) (§Critério) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Provar a federação A2A **ponta a ponta, nos dois sentidos**, in-process e sem
rede: um agente `orchestrator` chama a tool `remote_worker`; o
`A2A::Client` (Task 01/02) faz `message/send`/`tasks/get` contra um
`LoopbackHttp` que roteia direto para o `A2A::App` **inbound** (Task da fatia
A) do agente `worker`; o turno do `worker` roda de verdade (CommandBus +
Executor reais); o texto final volta ao modelo do `orchestrator`. Fecha os 5
itens do "Critério de conclusão da fatia" do `00-overview.md`: chamada
outbound com `:a2a_call`, loopback ponta a ponta, erro remoto → `{ error: }`
sem derrubar o turno, paridade sem `HARNESS_A2A_REMOTES`, e suíte verde sem
chave de API.

## Dependências

Task 06 (wiring de produção: `A2A_CLIENT` + `Http` + registro lazy por
remoto + catálogo D5). Este smoke NÃO reusa `config/wiring.rb` diretamente
(como `smoke_phase3a_spec.rb` também não reusa o composition root de
produção) — monta os próprios dois wirings de teste, mas só faz sentido
depois que TODAS as peças que ele integra estão implementadas e estáveis:
`A2A::Client#send_message`/`#get_task` (Task 01), `Client#call`
(Task 02, poll + encapsulamento de erro D3/L5), `Tools::A2ARemote`
(Task 04, D1/D4), e o formato de registro em bloco lazy que a Task 06
consolidou em produção (este smoke espelha o MESMO formato, só que com
`require` explícito no topo do spec em vez de lazy — ver Passo 3).

## Contexto

### Loopback = outbound chamando o próprio inbound, no MESMO processo

A fatia A (P3A) já fez o harness SER um agente A2A inbound
(`Harness::Server::A2A::App#rpc`, `server/a2a/app.rb`) — é o que
`spec/e2e/smoke_phase3a_spec.rb` exercita com um `CommandBus` +
`Executor` + `FakeChat` reais. Esta fatia (P3B) fecha o outro lado: o
harness passa a **chamar** um agente remoto via `Tools::A2ARemote` →
`A2A::Client`. Em vez de bater numa URL real, o `http` injetado no `Client`
é um `LoopbackHttp` que redireciona `post_json(url, body)` direto para
`inbound_app.rpc(body)` — o "remoto" é o NOSSO PRÓPRIO `A2A::App` inbound,
rodando com seu próprio `CommandBus`/`Executor`/`FakeChat`, no mesmo
processo Ruby e no MESMO reactor `Async` (`Sync do ... end`) do teste. Não
há rede, socket, nem porta — por isso "loopback": a volta completa
(orchestrator → tool → Client → LoopbackHttp → App inbound → Executor do
worker → resposta) acontece dentro de uma única árvore de fibers.

### Herda o padrão de wiring de `smoke_phase3a_spec.rb`

Este spec MONTA DUAS instâncias completas do mesmo padrão que
`spec/e2e/smoke_phase3a_spec.rb` já usa para o inbound sozinho: backend
(`Harness::Stores::Memory`) + `SessionStore`/`TaskStore`/`CheckpointStore`
+ `EventStream` + `SkillCatalog` vazio + `profiles` + `Executor` (com
`FakeContextBuilder`/`NullPolicyEngine`/`PassthroughMiddleware`/
`NullHooks`) + `CommandBus` registrando `create_session`/`send_message`/
`cancel_task`. Uma cópia disso é o **worker** (ganha também o `A2A::App`
inbound); outra é o **orchestrator** (ganha a tool `remote_worker` no lugar
do `A2A::App`). Não compartilham NENHUM store/executor entre si — são dois
agentes federados completamente isolados, exatamente como seriam dois
processos distintos numa federação real.

### `create_chat` stubado nos dois lados; `A2ARemote`/`ruby_llm` requeridos explícito

Como em `smoke_phase2b_spec.rb`/`smoke_phase3a_spec.rb`, o `Executor` NUNCA
toca `ruby_llm` de verdade — `create_chat` é stubado (`allow(executor).to
receive(:create_chat).and_return(chat)`) para devolver um `FakeChat`. Mas
`Tools::A2ARemote < RubyLLM::Tool` (Task 04) PRECISA da gem carregada para
existir como classe/instância — como o `require` lazy de produção
(bloco de `REGISTRY.register`, Task 06) não roda aqui (não passamos pelo
wiring real), o spec requer explícito no topo, mesma disciplina do
comentário de `smoke_phase2b_spec.rb`: "O Executor os carrega lazy em
`create_chat`; aqui `create_chat` é stubado, então requeremos explícito".

## Arquivos

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `spec/e2e/smoke_phase3b_spec.rb` | `LoopbackHttp` + wiring `worker` (inbound) + wiring `orchestrator` (outbound com `remote_worker`) + 3 cenários do Critério |

## Passo a passo

### Passo 1 — `LoopbackHttp`

No topo do arquivo, junto dos `require`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "async"
require "ruby_llm"
require_relative "../../server/a2a/app"
require_relative "../../server/a2a/client"
require_relative "../../lib/harness/tools/a2a_remote"

# post_json(url, body) -> Hash: em vez de bater em rede, redireciona DIRETO
# ao #rpc do A2A::App inbound (mesmo processo, mesmo reactor). `_url` é
# ignorado de propósito — não há endereço nenhum para resolver (D2 do
# overview: "smoke loopback... o outbound chama o inbound in-process").
LoopbackHttp = Struct.new(:inbound) do
  def post_json(_url, body) = inbound.rpc(body)
end
```

**Padrão de referência (techspec, P3B-02 §Smoke E2E loopback):** a mesma
struct, ipsis literis — não é um double de teste "inventado", é peça do
próprio desenho da fatia (D2 do overview: "Smoke: um http de loopback que
roteia `post_json` para o nosso `A2A::App#rpc` inbound").

### Passo 2 — wiring do `worker` (inbound)

Cópia do padrão de `smoke_phase3a_spec.rb` (mesmos `let`s: `backend`,
`session_store`, `task_store`, `checkpoint_store`, `event_stream`,
`skill_catalog`, `profiles`, `executor`, `bus`), com o profile `"worker"` no
lugar de `"assistant"`, e um `let(:worker_app)` (`Harness::Server::A2A::App`)
no lugar do `let(:a2a)`:

```ruby
let(:worker_profiles) do
  { "worker" => Harness::AgentProfile.build(id: "worker", model: "fake", base_prompt: "WORKER") }
end
let(:worker_backend)          { Harness::Stores::Memory.new }
let(:worker_session_store)    { Harness::SessionStore.new(store: worker_backend) }
let(:worker_task_store)       { Harness::TaskStore.new(store: worker_backend) }
let(:worker_checkpoint_store) { Harness::CheckpointStore.new(store: worker_backend) }
let(:worker_event_stream)     { Harness::EventStream.new }

let(:worker_executor) do
  Harness::Executor.new(
    context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
    middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
    tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
    profiles: worker_profiles, session_store: worker_session_store, task_store: worker_task_store,
    checkpoint_store: worker_checkpoint_store, event_stream: worker_event_stream
  )
end

let(:worker_bus) do
  Harness::CommandBus.new(event_stream: worker_event_stream).tap do |b|
    b.register(:create_session, Harness::Commands::CreateSession.new(session_store: worker_session_store, event_stream: worker_event_stream))
    b.register(:send_message, Harness::Commands::SendMessage.new(profiles: worker_profiles, session_store: worker_session_store, task_store: worker_task_store, executor: worker_executor))
    b.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: worker_task_store, executor: worker_executor))
  end
end

let(:worker_app) do
  Harness::Server::A2A::App.new(
    command_bus: worker_bus, task_store: worker_task_store, session_store: worker_session_store,
    profiles: worker_profiles, skill_catalog: Harness::SkillCatalog.new([]),
    config: { a2a_agent: "worker", base_url: "https://worker.example" }
  )
end
```

### Passo 3 — wiring do `orchestrator` (outbound) + `remote_worker`

O `orchestrator` ganha um `Harness::ToolRegistry` REAL (não
`FakeToolRegistry`) com **um** tool registrado — `remote_worker` — cujo
`client` usa o `LoopbackHttp` apontando ao `worker_app` do Passo 2:

```ruby
let(:orchestrator_profiles) do
  { "orchestrator" => Harness::AgentProfile.build(id: "orchestrator", model: "fake", base_prompt: "ORCH") }
end
let(:orchestrator_backend)          { Harness::Stores::Memory.new }
let(:orchestrator_session_store)    { Harness::SessionStore.new(store: orchestrator_backend) }
let(:orchestrator_task_store)       { Harness::TaskStore.new(store: orchestrator_backend) }
let(:orchestrator_checkpoint_store) { Harness::CheckpointStore.new(store: orchestrator_backend) }
let(:orchestrator_event_stream)     { SpyEventStream.new } # precisa inspecionar :a2a_call

# client de saída: http = loopback pro worker_app (Passo 2); sleeper NO-OP
# (ver Notas — a interação de reactor dispensa espera real neste smoke).
let(:a2a_client) do
  Harness::Server::A2A::Client.new(http: LoopbackHttp.new(worker_app), sleeper: ->(_seconds) {})
end

let(:orchestrator_tool_registry) do
  Harness::ToolRegistry.new.tap do |r|
    r.register("remote_worker", plugin: "a2a") do
      Harness::Tools::A2ARemote.new(
        client: a2a_client, url: "https://worker.example/a2a", tool_name: "remote_worker",
        description: "Delega ao agente A2A remoto 'worker'", event_stream: orchestrator_event_stream
      )
    end
  end
end

let(:orchestrator_policy_engine) do
  # allowed_tools = as Entries do registry (mesma forma que a Resolution real
  # devolve — `assemble_tool_instances`/`instantiate_tools` do Executor chamam
  # `.factory.call` em qualquer allowed que responda a `:factory`). É assim
  # que a tool fica, ao mesmo tempo, NO tool_registry E permitida (enunciado
  # do critério "remote_worker no tool_registry + allowed").
  NullPolicyEngine.new(allowed_tools: orchestrator_tool_registry.entries)
end

let(:orchestrator_executor) do
  Harness::Executor.new(
    context_builder: FakeContextBuilder.new, policy_engine: orchestrator_policy_engine,
    middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
    tool_registry: orchestrator_tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
    profiles: orchestrator_profiles, session_store: orchestrator_session_store,
    task_store: orchestrator_task_store, checkpoint_store: orchestrator_checkpoint_store,
    event_stream: orchestrator_event_stream
  )
end

let(:orchestrator_bus) do
  Harness::CommandBus.new(event_stream: orchestrator_event_stream).tap do |b|
    b.register(:send_message, Harness::Commands::SendMessage.new(
      profiles: orchestrator_profiles, session_store: orchestrator_session_store,
      task_store: orchestrator_task_store, executor: orchestrator_executor
    ))
  end
end
```

Para o **cenário 3** ("sem remotos"), um segundo par
`orchestrator_tool_registry`/`orchestrator_policy_engine`/`orchestrator_executor`
SEM o `register("remote_worker")` (um `Harness::ToolRegistry.new` vazio +
`NullPolicyEngine.new` default, `allowed_tools: []`) — paridade Fase 1: o
turno roda igual, só que sem nenhuma tool `remote_*` no chat.

### Passo 4 — helper para dirigir o turno do `orchestrator`

Mesmo formato de `run_turn`/`send_and_finish` (`smoke_phase2b_spec.rb`/
`smoke_phase3a_spec.rb`): `dispatch(:send_message)` + poll no
`task_store` até estado terminal, tudo dentro de `Sync do |parent| ... end`
(um único reactor para o teste inteiro — o turno do `worker`, disparado de
dentro do turno do `orchestrator`, nasce como fiber-filho da MESMA árvore):

```ruby
TERMINAL = %w[completed failed cancelled].freeze

def run_orchestrator_turn(chat:)
  allow(orchestrator_executor).to receive(:create_chat).and_return(chat)
  result = nil
  Sync do |parent|
    result = orchestrator_bus.dispatch(
      Harness::Command.build(:send_message, { agent: "orchestrator", message: "pergunta" })
    )
    100.times do
      t = orchestrator_task_store.find(result[:task_id])
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.005)
    end
  end
  orchestrator_task_store.find(result[:task_id])
end
```

O turno do `worker` é disparado a partir de dentro do `script` do
`FakeChat` do orchestrator (quando ele chama `tool.call(message:)`) — o
`allow(worker_executor).to receive(:create_chat).and_return(worker_chat)`
correspondente precisa estar armado ANTES desse `Sync`, uma vez por
cenário (ver Passo 5).

### Passo 5 — os 3 cenários

**Cenário 1 — sucesso (worker responde "42"):**

```ruby
it "orchestrator chama remote_worker; o turno do worker roda no inbound; '42' volta ao modelo; emite :a2a_call" do
  worker_chat = FakeChat.new
  worker_chat.final_content = "42"
  allow(worker_executor).to receive(:create_chat).and_return(worker_chat)

  tool_result = nil
  orch_chat = FakeChat.new
  orch_chat.final_content = "a resposta é 42"
  orch_chat.script = proc do
    tool = tools.find { |t| t.name.to_s == "remote_worker" }
    tool_result = tool.call(message: "quanto é 6x7?")
  end

  task = run_orchestrator_turn(chat: orch_chat)

  expect(task.status).to eq(:completed)
  expect(tool_result).to eq("42")

  event = orchestrator_event_stream.events.find { |e| e.type == :a2a_call }
  expect(event).not_to be_nil
  expect(event.data[:agent]).to eq("remote_worker")
  expect(event.data[:state]).to eq("completed")
end
```

**Cenário 2 — worker falha (erro remoto → `{ error: }`, turno segue):**

```ruby
it "worker que falha -> a tool devolve { error: } e o turno do orchestrator completa" do
  worker_chat = FakeChat.new
  worker_chat.script = proc { raise "worker indisponível" } # turno do worker -> :failed
  allow(worker_executor).to receive(:create_chat).and_return(worker_chat)

  tool_result = nil
  orch_chat = FakeChat.new
  orch_chat.script = proc do
    tool = tools.find { |t| t.name.to_s == "remote_worker" }
    tool_result = tool.call(message: "quanto é 6x7?")
  end

  task = run_orchestrator_turn(chat: orch_chat)

  expect(task.status).to eq(:completed) # D4: erro remoto NÃO derruba o turno do orchestrator
  expect(tool_result).to be_a(Hash)
  expect(tool_result[:error]).not_to be_nil

  event = orchestrator_event_stream.events.find { |e| e.type == :a2a_call }
  expect(event.data[:state]).to eq("failed")
end
```

**Cenário 3 — sem remotos (paridade D6):**

```ruby
it "sem remote_worker no tool_registry -> nenhuma tool remote_* exposta; turno completa normal" do
  empty_registry = Harness::ToolRegistry.new
  bare_executor = Harness::Executor.new(
    context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new, # allowed_tools: [] default
    middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
    tool_registry: empty_registry, skill_catalog: Harness::SkillCatalog.new([]),
    profiles: orchestrator_profiles, session_store: orchestrator_session_store,
    task_store: orchestrator_task_store, checkpoint_store: orchestrator_checkpoint_store,
    event_stream: orchestrator_event_stream
  )
  bare_bus = Harness::CommandBus.new(event_stream: orchestrator_event_stream).tap do |b|
    b.register(:send_message, Harness::Commands::SendMessage.new(
      profiles: orchestrator_profiles, session_store: orchestrator_session_store,
      task_store: orchestrator_task_store, executor: bare_executor
    ))
  end

  seen_names = nil
  chat = FakeChat.new
  chat.script = proc { seen_names = tools.map { |t| t.name.to_s } }
  allow(bare_executor).to receive(:create_chat).and_return(chat)

  result = nil
  Sync do |parent|
    result = bare_bus.dispatch(Harness::Command.build(:send_message, { agent: "orchestrator", message: "oi" }))
    100.times do
      t = orchestrator_task_store.find(result[:task_id])
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.005)
    end
  end

  task = orchestrator_task_store.find(result[:task_id])
  expect(task.status).to eq(:completed)
  expect(seen_names).not_to include("remote_worker")
  expect(seen_names.grep(/\Aremote_/)).to be_empty
end
```

> Este 3º cenário é redundante DE PROPÓSITO com o `wiring_load_spec.rb` da
> Task 06 (que já garante "sem env → nenhum `remote_*` no `REGISTRY`") — a
> diferença é o NÍVEL: a Task 06 prova a paridade no WIRING (o tool nunca é
> registrado); este cenário prova a mesma paridade no TURNO (o `chat.tools`
> do modelo nunca vê `remote_*`, fim a fim). Os dois são baratos e cobrem
> camadas diferentes — manter os dois (P3B-02 §Testes já lista ambos).

## Edge cases

1. **`tool.call(message:)`, não `tool.execute(message:)`:** `A2ARemote`
   herda `RubyLLM::Tool#call(args)` (normaliza chaves, valida keywords,
   chama `execute(**args)`) — o script do `FakeChat` deve invocar `.call`
   (o ponto de entrada real que o RubyLLM/`ToolEnvelope` usam), não
   `.execute` direto, para exercitar a MESMA superfície que a produção usa
   (`lib/harness/tool_envelope.rb#call` delega a `__getobj__.call(args)`).
   Ver `smoke_phase2b_spec.rb` L153-155 (`ts.execute(...)` é exceção
   documentada ali por ser uma tool de sistema promovida — `A2ARemote` é
   tool normal, usa `.call`).
2. **`worker_chat`/`orch_chat` são `create_chat` stubs DISTINTOS em
   Executors DISTINTOS** — não confundir qual `allow(...).to receive
   (:create_chat)` pertence a qual lado; um teste que esquecer de armar o
   stub do `worker_executor` faz o turno do worker tentar `RubyLLM.chat`
   de verdade e falhar (sem chave de API) — o turno do worker viraria
   `:failed` por `ProviderError`, contaminando o cenário 1 com um erro
   "errado" (que passaria pelo MESMO caminho `{ error: }` do cenário 2 sem
   querer).
3. **Erro remoto (cenário 2) não precisa de exceção real no `worker_chat`
   propositalmente exótica** — qualquer forma que faça o turno do worker
   terminar `:failed` serve (uma exceção no `script`, ou trocar
   `worker_executor` por um `policy_engine: DenyAllPolicyEngine.new` só
   para este teste). A forma mais direta é `chat.script = proc { raise
   "..." }` — mesma técnica de falha de chat já usada em specs de
   integração do Executor.
4. **Ordem de `require` importa:** `require "ruby_llm"` e
   `require_relative ".../a2a_remote"` no TOPO do arquivo (não dentro de
   um bloco lazy) — porque este spec NÃO passa pelo `config/wiring.rb` de
   produção (onde o require lazy da Task 06 vive); sem o require
   explícito, `Harness::Tools::A2ARemote` nem existiria como constante ao
   montar o `orchestrator_tool_registry`.
5. **`:a2a_call` correlação (`meta: {}`):** o evento não tem `task_id`/
   `session_id` (P3B-02 L3 — tools de registry não recebem `TurnState`) —
   os testes correlacionam pelo `type: :a2a_call` + `data[:agent]`, nunca
   por `meta`.
6. **Interação de reactor (ver Notas):** a ordem exata de quando o turno
   do `worker` roda em relação ao `send_message` do `Client` é o ponto
   mais delicado deste smoke — validar empiricamente ao implementar (ver
   Notas) antes de fixar as asserções de `tool_result`.

## Testes

**Arquivo:** `spec/e2e/smoke_phase3b_spec.rb`

| Cenário | Exercita | Esperado |
|---|---|---|
| 1. Sucesso | `orchestrator` chama `remote_worker(message:)` → `Client#call` → `LoopbackHttp` → `worker_app.rpc` → turno do `worker` (FakeChat "42") → volta pelo `Client` | `tool_result == "42"`; `task.status == :completed` (orchestrator); evento `:a2a_call` com `agent: "remote_worker"`, `state: "completed"` |
| 2. Erro remoto | `worker_chat` levanta → turno do `worker` termina `:failed` → `A2A::App#tasks_get` projeta `state: "failed"` → `Client#call` encapsula → tool devolve `{ error: }` | `tool_result` é `Hash` com `:error` presente; `task.status == :completed` (orchestrator NÃO falha, D4); evento `:a2a_call` com `state: "failed"` |
| 3. Sem remotos | `orchestrator_tool_registry` vazio (sem `register("remote_worker")`) | `chat.tools` não inclui nenhum nome `remote_*`; `task.status == :completed` (paridade Fase 1) |

## Definition of Done

- [ ] 3 cenários do Critério de conclusão (`00-overview.md` §Critério, itens
      2/3/4) implementados e verdes
- [ ] Suíte inteira verde sem chave de API (dois `Executor`s com
      `create_chat` stubado; nenhuma dependência de rede — `LoopbackHttp` é
      100% in-process)
- [ ] Comportamento de `client.call`/`message_send` validado EMPIRICAMENTE
      contra a interação de reactor descrita nas Notas (não assumir "eager"
      ou "não-eager" sem rodar) — se o texto vier vazio no cenário 1 por
      causa da assimetria `message_send`×`tasks_get` (ver Notas), reportar
      e coordenar um ajuste mínimo em `Client#call` (Task 02) ou em
      `A2A::App#message_send` (P3A) antes de fechar este task
- [ ] Rubocop limpo
- [ ] Code review

## Notas

### Por que o `sleeper` pode ser no-op (`->(_seconds) {}`)

O turno inteiro (dos dois lados) roda sobre DOUBLES determinísticos —
`FakeChat`, `Harness::Stores::Memory`, `NullPolicyEngine`,
`PassthroughMiddleware`, `NullHooks` — nenhum deles bloqueia em I/O real
nem chama `sleep`/`Fiber.yield` de verdade em nenhum ponto do pipeline
(estágios 2-9 do Executor, `ToolEnvelope#call`, `Async::Task#with_timeout`
sem estourar). **Confirmado empiricamente** (não é só teoria): num
`Sync do |parent| ... end`, `parent.async { bloco_sem_yield_real }` só
devolve o controle ao chamador DEPOIS que o bloco termina — ou seja, o
fiber-filho roda **eager até completar** quando nada dentro dele cede o
reactor de verdade. Isso significa que quando `LoopbackHttp#post_json`
(chamado de dentro do `Client#send_message`, dentro do `tool.call` do
`orchestrator`) invoca `worker_app.rpc(body)` → `message_send` →
`@command_bus.dispatch(:send_message)` → `executor.spawn_in_session` →
`actor.run { execute(...) }` (que é `parent.async { ... }` por baixo), o
turno do **worker roda até o fim SÍNCRONO, dentro dessa mesma chamada** —
por isso o `sleeper` do `Client` nem chega a ser invocado no caminho feliz
(o `Client#call`, Task 02, só chama `sleeper` DEPOIS de ver que
`remote_state` não é terminal; se já vier terminal do `send_message`, o
loop de poll nunca entra no corpo).

### ⚠️ Ponto de atenção real: `message_send` não projeta `content:`/`error:`

`Harness::Server::A2A::App#message_send` (`server/a2a/app.rb`, já
mesclado na fatia A) chama `TaskProjection.call(task, at: now)` **sem**
`content:`/`error:` — só `#tasks_get` calcula `terminal_content`/
`terminal_error` e os passa adiante. Isso significa que, se o turno do
`worker` já estiver `:completed` no momento em que `message_send` responde
(o que — pela eagerness comprovada acima — é o caso ESPERADO neste
smoke, já que tudo é fake/síncrono), o Hash de Task devolvido por
`send_message` traz `status.state == "completed"` mas **sem**
`status.message` — e `Client#call` (conforme documentado na Task 02) só
faz `get_task` quando `remote_state(t)` AINDA NÃO é terminal. Resultado
possível: `remote_text(t)` lido da resposta do PRÓPRIO `send_message` (sem
`status.message`) devolve `""`, e o cenário 1 receberia `tool_result == ""`
em vez de `"42"` — mesmo com o worker tendo, de fato, respondido "42" (o
dado existe no `TaskStore`, só não foi projetado na resposta do
`send_message`).

**Isto não é um bug deste smoke — é uma lacuna entre P3A (`message_send`)
e o algoritmo de `Client#call` descrito em `task-02.md`.** Ao implementar
este task, rodar o cenário 1 primeiro e observar o valor real de
`tool_result`:
- Se vier `"42"` (por exemplo, se a implementação real de `Client#call`
  divergir do pseudocódigo do techspec e sempre fizer ≥ 1 `get_task`, ou
  se alguma etapa introduzir um yield real que atrase o `worker` o
  suficiente para `message_send` responder ainda `"working"`), o smoke
  passa como está.
- Se vier `""`, a correção mínima é em UM dos dois lugares (escolher o que
  menos reabra escopo já fechado): (a) `Client#call` sempre fazer pelo
  menos 1 `get_task` após o `send_message`, mesmo quando este já vem
  terminal (garante conteúdo sempre fresco, projetado); ou (b)
  `A2A::App#message_send` passar `content:`/`error:` como `#tasks_get`
  já faz (simetria entre os dois métodos). Qualquer uma resolve — reportar
  a escolha no PR desta task, já que toca um arquivo (`client.rb` ou
  `app.rb`) fora do escopo original do task correspondente.

### Contraste com `smoke_phase3a_spec.rb`

O smoke da fatia A tem exatamente essa mesma tensão e a resolve por
HEDGING, não por polling: `send_and_finish` aceita qualquer estado A2A
válido na resposta de `message/send` (comentário: "o turno pode rodar
eager sob Sync... qualquer estado A2A válido serve") e usa
`parent.sleep(0.005)` num loop pra aguardar o estado TERMINAL antes de
inspecionar o `tasks/get`. Este smoke (P3B) não tem esse luxo: o valor que
importa (`tool_result`) é decidido DENTRO do `Client#call`, não por uma
segunda consulta que o teste faz por fora — por isso a lacuna acima precisa
ser resolvida no PRÓPRIO `Client`, não contornada com mais um `sleep` no
teste.
