# Task 08 (P3A): Smoke E2E fatia A (A2A inbound)

> **Techspec:** [00-overview.md](../00-overview.md) (§Critério) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Provar, com um teste E2E único, os 6 critérios de conclusão da fatia A
(`00-overview.md` §"Critério de conclusão da fatia"):

1. `message/send` (JSON-RPC) → despacha `send_message` no MESMO `command_bus`
   → devolve uma **A2A Task** `submitted`/`working` com `id` e `contextId`.
2. Depois que o turno completa, `tasks/get` do mesmo `id` → `status.state ==
   "completed"` + `status.message` com o conteúdo (lido do transcript da
   sessão).
3. `tasks/cancel` → transiciona e projeta `"canceled"`.
4. `GET` do AgentCard (via `#agent_card`) → `name`/`capabilities
   streaming:false`/`skills`.
5. Mapa de erros: `tasks/get` de `id` inexistente → `-32001`; método
   desconhecido → `-32601`.
6. O `A2A::App` nunca vaza exceção — sempre um error object no envelope
   JSON-RPC.

## Dependências

| # | Task | Componente | Status |
|---|------|-----------|--------|
| 6 | `Server::App` rotas: `POST /a2a` + `GET /.well-known/agent-card.json` + `handle_a2a` + `@a2a` (default nil → 404) | ⬜ TODO |
| 7 | Wiring: `A2A_APP` opt-in (`HARNESS_A2A_AGENT`) + inject no `Server::App` + require dos `server/a2a/*` | ⬜ TODO |

Transitivamente depende de 1-5 (`Protocol`/`Errors`/`Message`/`TaskProjection`/
`AgentCard`/`Server::A2A::App`) — são pré-requisitos de 6/7, mas este spec só
**consome** a interface pública de `Server::A2A::App#rpc`/`#agent_card` (não
reimplementa nada delas), exatamente como o `smoke_phase2b_spec.rb`/
`smoke_phase2c_spec.rb` consomem `Executor`/`SendMessage` sem retestar o
Estágio 3. Como a task explicitamente permite driblar 6/7 (ver Contexto), o
spec **roda e compila assim que a task 5 estiver mesclada** — não precisa
esperar as rotas HTTP nem o wiring; só o `Server::A2A::App` real. Nenhuma das
classes usadas aqui (`Harness::Server::A2A::App`, `Protocol`, `Errors`,
`Message`, `TaskProjection`, `AgentCard`) existe neste repo no momento em que
este doc foi escrito — ver Notas.

## Contexto

Herda o MESMO padrão dos smokes das fatias B/C
(`spec/e2e/smoke_phase2b_spec.rb`, `spec/e2e/smoke_phase2c_spec.rb`):
`CommandBus` real → handlers (`SendMessage`, `CancelTask`, `CreateSession`)
reais → `Executor` real, com `SessionStore`/`TaskStore`/`AgentProfile` de
PRODUÇÃO — só o `chat` (RubyLLM) é o duplo (`FakeChat` via stub de
`create_chat`). Sem dimensão de crash/reboot, in-process, sem subprocess.

**A diferença estrutural:** em vez de despachar `Command.build(:send_message,
...)` direto no bus (como os smokes 2b/2c fazem), este spec dirige um
`Harness::Server::A2A::App` real, construído com esse MESMO bus + stores, e
chama `app.rpc(jsonrpc_hash)` — um Hash JSON-RPC 2.0 já desserializado, exatamente
como `Server::A2A::App#rpc` espera (P3A-02 §"`Server::A2A::App`": "`body` já é
o Hash desserializado"). Isso prova a costura ponta a ponta (JSON-RPC → Command
→ Task real) sem precisar subir HTTP/Rack: `app.rpc(body)` é uma chamada de
método Ruby direta, determinística, sem `Rack::MockRequest`/sockets — mais
simples e mais rápido que orquestrar `Server::App` inteiro por cima (que só
adicionaria uma camada de parsing HTTP já coberta por
`spec/harness/server/app_spec.rb`/futuros specs de rota da task 6). O
`agent_card` (critério 4) é chamado do mesmo jeito: `app.agent_card` (sem
`GET` HTTP).

`message/send` SEMPRE passa por uma sessão (cria uma quando `contextId`
ausente — P3A-02 L4): é assim que `tasks/get` consegue ler o conteúdo terminal
do transcript (`session_store.find(task.session_id).messages`, última
`role: "assistant"`) para o critério 2. Por isso o teste deste critério
**faz polling** do `tasks/get` até um estado terminal (`completed`/`failed`/
`canceled`), no mesmo espírito do `run_turn` dos smokes anteriores — só que
aqui o polling é via `app.rpc({"method" => "tasks/get", ...})` repetido, não
via `task_store.find` direto (é o próprio mecanismo A2A sob teste).

## Arquivos

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `spec/e2e/smoke_phase3a_spec.rb` | Suíte única cobrindo os 6 critérios (A2A inbound) |

Nenhum arquivo de produção é tocado por esta task (é só o smoke). Reusa
`spec/support/fakes.rb` (`FakeContextBuilder`, `PassthroughMiddleware`,
`NullHooks`/`NullPolicyEngine`, `SpyEventStream`) e `spec/support/fake_chat.rb`
sem alteração.

## Passo a passo

### Passo 1 — Wiring auxiliar (stores + bus + Executor reais; `Server::A2A::App` real)

**Padrão de referência (codebase — `smoke_phase2b_spec.rb:25-80`, adaptado:
troca o `run_turn` que despacha `send_message` direto por um `Server::A2A::App`
por cima do MESMO bus/stores, e acrescenta `CancelTask`/`CreateSession` ao
bus — necessários para os critérios 3 e para o `contextId` implícito do
critério 1):**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../server/a2a/app"
# O Executor os carrega lazy em create_chat; aqui create_chat é stubado, então
# requeremos explícito (mesma disciplina dos smokes 2b/2c).
require "harness/tools/load_skill"
require "harness/tools/tool_search"

# Smoke E2E da fatia A (P3A): CommandBus + SendMessage/CancelTask/CreateSession
# + Executor REAIS, RubyLLM mockado (FakeChat via stub de create_chat). O
# adapter A2A (Server::A2A::App) é dirigido DIRETO via #rpc(Hash)/#agent_card —
# sem HTTP/Rack (ver Contexto). Prova a pipeline JSON-RPC -> Command -> Task ->
# projeção A2A ponta a ponta.
RSpec.describe "smoke E2E: A2A inbound (fatia A)", :smoke do
  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }

  let(:agent_id) { "a2a_agent" }
  let(:profiles) do
    { agent_id => Harness::AgentProfile.build(id: agent_id, model: "fake", base_prompt: "SOUL") }
  end

  let(:executor) do
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:bus) do
    Harness::CommandBus.new(event_stream: event_stream).tap do |b|
      b.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
      b.register(:cancel_task,
                 Harness::Commands::CancelTask.new(task_store: task_store, executor: executor))
      b.register(:create_session,
                 Harness::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
    end
  end

  let(:skill_catalog) { Harness::SkillCatalog.new([]) }

  # O App real da fatia (P3A-02): recebe o MESMO bus/stores, nunca escreve
  # store direto (D1/D6) — só traduz.
  let(:app) do
    Harness::Server::A2A::App.new(
      command_bus: bus, task_store: task_store, session_store: session_store,
      profiles: profiles, skill_catalog: skill_catalog,
      config: { a2a_agent: agent_id, base_url: "http://localhost:9292" }
    )
  end
```

### Passo 2 — Helpers: chamar `chat` real (stub) + polling via `tasks/get`

**Padrão de referência (codebase — `smoke_phase2b_spec.rb:98-114`, adaptado:
o polling terminal usa `app.rpc("tasks/get")` em vez de `task_store.find`
direto — é o próprio mecanismo A2A sob teste, critério 2):**

```ruby
  TERMINAL_A2A = %w[completed failed canceled].freeze

  def rpc(method, params = {}, id: SecureRandom.uuid)
    app.rpc({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  def text_message(text)
    { "role" => "user", "parts" => [{ "kind" => "text", "text" => text }] }
  end

  # Roda um turno real (chat stubado) e faz polling de tasks/get até terminal —
  # devolve a última resposta JSON-RPC de tasks/get (shape A2A Task completo).
  def send_and_await(text: "oi", chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    sent = nil
    final = nil
    Sync do |parent|
      sent = rpc("message/send", { "message" => text_message(text) })
      100.times do
        final = rpc("tasks/get", { "id" => sent["result"]["id"] })
        break if TERMINAL_A2A.include?(final.dig("result", "status", "state"))

        parent.sleep(0.005)
      end
    end
    [sent, final, chat]
  end
```

### Passo 3 — Critério 1: `message/send` devolve Task `submitted`/`working` com `id`+`contextId`

```ruby
  it "message/send despacha send_message no bus e devolve A2A Task submitted/working" do
    chat = FakeChat.new
    chat.script = proc { "ok" }
    allow(executor).to receive(:create_chat).and_return(chat)

    resp = rpc("message/send", { "message" => text_message("oi") })

    expect(resp["jsonrpc"]).to eq("2.0")
    task_a2a = resp["result"]
    expect(task_a2a["kind"]).to eq("task")
    expect(task_a2a["id"]).not_to be_nil
    expect(task_a2a["contextId"]).not_to be_nil # = session_id criado pelo App (D3/L4)
    expect(%w[submitted working]).to include(task_a2a["status"]["state"])

    # Prova que o dispatch caiu no MESMO bus: a Task existe no task_store real.
    expect(task_store.find(task_a2a["id"])).not_to be_nil
    # E que uma sessão foi criada (contextId), com o transcript pronto p/ tasks/get.
    expect(session_store.find(task_a2a["contextId"])).not_to be_nil
  end
```

### Passo 4 — Critério 2: `tasks/get` após completar traz `completed` + `status.message` com o conteúdo

```ruby
  it "tasks/get, após o turno completar, projeta completed com status.message = conteúdo do transcript" do
    chat = FakeChat.new
    chat.script = proc { "resposta do agente" }

    sent, final, = send_and_await(chat: chat)
    task_id = sent["result"]["id"]

    expect(final["result"]["status"]["state"]).to eq("completed")
    expect(final["result"]["id"]).to eq(task_id)
    message = final["result"]["status"]["message"]
    expect(message["role"]).to eq("agent")
    text = message["parts"].map { |p| p["text"] }.join
    expect(text).to include("resposta do agente")

    # Confirma a origem do conteúdo (L4): é a última mensagem assistant do
    # transcript da sessão criada pelo message/send.
    session = session_store.find(final["result"]["contextId"])
    assistant_msgs = session.messages.select { |m| (m["role"] || m[:role]) == "assistant" }
    expect(assistant_msgs.last["content"] || assistant_msgs.last[:content]).to include("resposta do agente")
  end
```

### Passo 5 — Critério 3: `tasks/cancel` transiciona e projeta `canceled`

```ruby
  it "tasks/cancel transiciona a Task e projeta canceled" do
    sent = rpc("message/send", { "message" => text_message("oi") })
    task_id = sent["result"]["id"]

    resp = rpc("tasks/cancel", { "id" => task_id })

    expect(resp["result"]["id"]).to eq(task_id)
    expect(resp["result"]["status"]["state"]).to eq("canceled")
  end
```

### Passo 6 — Critério 4: `agent_card` traz name/capabilities streaming:false/skills

```ruby
  it "agent_card devolve name/capabilities(streaming:false)/skills do agente configurado" do
    card = app.agent_card

    expect(card[:name] || card["name"]).to eq(agent_id)
    caps = card[:capabilities] || card["capabilities"]
    expect(caps[:streaming] || caps["streaming"]).to eq(false)
    expect(card.key?(:skills) || card.key?("skills")).to be(true)
  end
```

### Passo 7 — Critério 5/6: mapa de erros + nunca vaza exceção

```ruby
  it "tasks/get de id inexistente -> -32001; método desconhecido -> -32601; nunca vaza exceção" do
    unknown = rpc("tasks/get", { "id" => "nao-existe" })
    expect(unknown["error"]["code"]).to eq(-32_001)
    expect(unknown["result"]).to be_nil

    bad_method = rpc("metodo/inexistente", {})
    expect(bad_method["error"]["code"]).to eq(-32_601)
    expect(bad_method["result"]).to be_nil
  end
```

## Edge cases

1. **`message/send` sempre cria sessão** (P3A-02 L4): sem `contextId` na
   request, o App despacha `:create_session` antes de `:send_message` — é
   assim que `tasks/get` tem transcript de onde ler o conteúdo terminal
   (critério 2). O teste do critério 1 confirma isso lendo
   `session_store.find(task_a2a["contextId"])`.
2. **Polling via `tasks/get`, não via `task_store` direto** — o critério 2
   testa literalmente o mecanismo A2A (`app.rpc("tasks/get", ...)` repetido),
   não um atalho pelo `task_store`. Só o `sleep`/timeout do laço usa
   `Async`/`parent.sleep`, igual aos smokes 2b/2c.
3. **`FakeContextBuilder` basta aqui** — nenhum critério da fatia A depende do
   CONTEÚDO do `system` (diferente da fatia C); o que importa é o texto de
   RESPOSTA do "modelo" (`chat.script`), que vira `content` da Task e cai em
   `status.message`. Ver `smoke_phase2c_spec.rb` para o caso oposto (quando
   o fake NÃO basta).
4. **`tasks/cancel` é cooperativo** (mesma ressalva do `CancelTask` real,
   doc `lib/harness/commands/cancel_task.rb`): o teste do critério 3 não
   assume que o turno já rodou — cancela logo após `message/send`, antes do
   `chat.script` sequer requisitar. O `Executor#cancel` real decide como o
   fiber observa o cancel; este smoke só prova que o `status.state` projetado
   é `"canceled"` depois do `tasks/cancel`, não a mecânica interna de
   cooperação (já coberta noutro nível pelos specs de `Executor`/`CancelTask`).
5. **Chaves string vs símbolo no shape do AgentCard/Task A2A** — como
   `AgentCard.build`/`TaskProjection.call` devolvem Hash Ruby (não passam por
   JSON round-trip nesta chamada direta a `#agent_card`/`#rpc`), as asserções
   toleram `Hash` com chave símbolo OU string (`card[:name] || card["name"]"`)
   para não acoplar o teste a uma escolha de serialização que P3A-01/02 não
   fixam explicitamente — ajustar se a implementação real de `TaskProjection`/
   `AgentCard`/`Protocol` fixar um dos dois formatos (ver Notas).
6. **Erro do critério 5 não interrompe a suíte** — cada chamada `app.rpc(...)`
   com erro devolve o envelope `{jsonrpc:, id:, error: {code:, message:}}`
   normalmente (D4); o teste do critério 6 é essa MESMA asserção — não há um
   `it` separado "não vaza exceção", porque toda a suíte já prova isso
   implicitamente (nenhum `it` usa `expect { ... }.to raise_error`; todos leem
   `resp["error"]`/`resp["result"]`).

## Testes

Este arquivo **é** o teste (task só de integração/smoke, sem código de
produção novo). Cenários:

| # | Caso | Exercita | Esperado |
|---|------|----------|----------|
| 1 | `message/send` (sem `contextId`) | `App#rpc` → `:send_message` no bus real | Task A2A `submitted`/`working` com `id`+`contextId`; Task existe no `task_store`; sessão existe no `session_store` |
| 2 | `tasks/get` após o turno completar (polling) | `App#rpc("tasks/get")` + leitura do transcript da sessão | `status.state == "completed"`; `status.message` (role `agent`) contém o texto do `chat.script` |
| 3 | `tasks/cancel` | `App#rpc("tasks/cancel")` → `:cancel_task` no bus | `status.state == "canceled"` |
| 4 | `app.agent_card` | `AgentCard.build` do agente configurado | `name` = agent_id; `capabilities.streaming == false`; chave `skills` presente |
| 5 | `tasks/get` de `id` inexistente | `Errors.from_exception(NotFoundError)` | `error.code == -32001`; `result` nil |
| 5 | método JSON-RPC desconhecido | `Protocol`/`App#rpc` (branch `else`) | `error.code == -32601`; `result` nil |
| 6 | (implícito nos cenários 5) | `App#rpc` nunca levanta | toda chamada devolve Hash com `result` XOR `error`, nunca uma exceção Ruby |

## Definition of Done

- [ ] Os 6 critérios de conclusão da fatia A verdes (00-overview.md
      §"Critério de conclusão da fatia"), cada um coberto por ≥1 exemplo
      deste arquivo
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Nenhuma das classes usadas por este spec existe no repo no momento em
  que este doc foi escrito** (`Harness::Server::A2A::App`, `::Protocol`,
  `::Errors`, `::Message`, `::TaskProjection`, `::AgentCard`) — só
  `P3A-01`/`P3A-02` as especificam. As assinaturas usadas aqui
  (`Server::A2A::App.new(command_bus:, task_store:, session_store:,
  profiles:, skill_catalog:, config:)`, `#rpc(Hash)`, `#agent_card`) seguem
  EXATAMENTE o que `P3A-02-agent-card-and-wiring.md` documenta — confirmar
  contra a implementação real das tasks 1-7 ao escrever o código; ajustar
  este spec se algum nome/shape divergir (mesmo aviso que o task-08 da fatia
  C fez para `MemoryStore`/`Context::Providers::Memory`).
- **Conteúdo terminal depende do turno de fato completar** — não há atalho:
  o critério 2 exige um laço de polling (via `Async`/`parent.sleep`, mesmo
  padrão dos smokes 2b/2c) até `tasks/get` reportar um `status.state`
  terminal (`completed`/`failed`/`canceled`). `message/send` SEMPRE cria (ou
  reusa) uma sessão — é essa sessão que carrega o transcript de onde
  `terminal_content(task)` (P3A-02 L4) lê a última mensagem `assistant`. Sem
  sessão, não haveria de onde ler o `content` — por isso o App nunca deixa
  `message/send` rodar one-shot (diferente do `/v1/messages` HTTP, que
  aceita ambos).
- **Este smoke dirige o `Server::A2A::App` direto, NÃO o `Server::App`
  completo** — a task descreve isso como aceitável ("Drive via `app.rpc(body)`
  directly... not necessarily full HTTP — simpler and deterministic"), e as
  deps 6/7 (rotas HTTP + wiring opt-in) não são exercitadas aqui. Um smoke
  HTTP fim-a-fim (`POST /a2a` via `Rack::MockRequest`, JSON malformado →
  `-32700`, `@a2a` ausente → 404) fica coberto por specs de rota da própria
  task 6 (`spec/harness/server/app_spec.rb`, no padrão do describe
  "POST /v1/commands/:type"), não duplicado aqui.
- **`-32700` (parse error) e `-32602` (invalid params) não entram neste
  smoke** — o critério de conclusão da fatia (00-overview §5) só exige
  `-32001`/`-32601` como amostra do mapa de erros; `-32700` é responsabilidade
  do `Server::App#handle_a2a` (parse do JSON cru ANTES de chegar em
  `App#rpc`, P3A-02 §"Rotas") — fora do alcance de uma chamada direta a
  `#rpc(Hash)` já desserializado. `-32602` (ValidationError) é coberto pelos
  specs unitários de `Errors`/`App` (P3A-01/02 §Testes), não precisa de
  duplicação aqui.
- **Shape de chaves (símbolo vs string) do AgentCard/Task A2A** — ver Edge
  case 6: as asserções toleram ambos porque `#rpc`/`#agent_card` são chamados
  Ruby diretos (sem round-trip JSON) e P3A-01/02 não fixam explicitamente o
  tipo das chaves do Hash retornado. Se a implementação real fixar um
  formato, simplificar as asserções para esse formato único (remover o `||`).
