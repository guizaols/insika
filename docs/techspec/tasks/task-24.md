# Task 24: Rotas formais — `POST /v1/commands/:type` + açúcar, reads GET, `/v1/events` SSE, rota legada

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [07-service-platform.md](../07-service-platform.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Evoluir o `app/server.rb` da Fase 0 para `Harness::Server::App` com a tabela de
rotas formal do doc 07 §2 (Command genérica + açúcar + leituras + SSE),
`SSEBody` drenando o `EventStream`, mapeamento erro→status completo e a rota
legada `POST /agent/messages` byte-compatível com a Fase 0.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 9 | `Command` + `CommandBus` + handlers de controle (`CreateSession`, `CancelTask`) | ⬜ TODO |
| 12 | Handler `SendMessage` end-to-end (providers stub) + checkpoint no estágio 8 + timeouts D4 | ⬜ TODO |

## Context

Esta é a primeira task da Etapa G (Service Platform, doc 07). A RFC-0001 §4
manda: **transportes só traduzem requisições em Commands** — o servidor não
contém lógica de negócio; ele parseia JSON, monta `Command.build(...)`,
despacha no `CommandBus` (task 9) e projeta o Event Stream em SSE. As leituras
(`GET /v1/sessions/:id`, `GET /v1/tasks/:id`) **não** são Commands — são reads
diretos dos stores (D3, Emenda 1 da RFC-0001 §10).

A rota genérica `POST /v1/commands/:type` (L2 do doc 07) garante que todo
Command novo já nasce com transporte; as rotas de açúcar dão ergonomia aos dois
fluxos quentes (`create_session`, `send_message`). A rota legada
`POST /agent/messages` é mantida por toda a Fase 1 (L5) porque o Agent.Shop a
consome hoje.

Esta task habilita a task 25 (o `/admin` monta em cima do `App`) e a task 26
(o `Boot` serve este app; o smoke E2E bate nestas rotas).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `server/app.rb` | `Harness::Server::App` — Rack app com roteamento explícito (L1) |
| CREATE | `server/sse_body.rb` | `Harness::Server::SSEBody` — evolui a `SSEStream` da Fase 0 |
| MODIFY | `lib/harness/event_stream.rb` (arquivo criado na task 10 — confirme o path no código real) | cap de 1000 eventos por `Subscription` (doc 07 §5) |
| MODIFY | `config/wiring.rb` | construir a `APP` com dependências injetadas (doc 07 §8) |
| CREATE | `spec/harness/server/app_spec.rb` | contrato de rotas com `Rack::MockRequest` + duplos |
| CREATE | `spec/harness/server/sse_body_spec.rb` | heartbeat, cap, fechamento, desconexão |
| CREATE | `spec/harness/server/legacy_contract_spec.rb` | regressão Fase 0 do `/agent/messages` (doc 07 §7) |

> Layout conforme 00-overview §3: `server/app.rb, server/admin/*` — o servidor
> vive fora de `lib/` (é o pacote `harness-server`; `lib/` é o núcleo).

### Step-by-Step Instructions

#### Step 1: Esqueleto do `Server::App` + roteamento explícito + mapeamento de erro

**File:** `server/app.rb`

Criar a classe com a assinatura exata do doc 07 §2:

```ruby
# frozen_string_literal: true

module Harness
  module Server
    class App                       # Rack app (evolui app/server.rb)
      def initialize(command_bus:, event_stream:, session_store:, task_store:,
                     catalogs:, registries:, config:)
      def call(env)                 # roteamento explícito; sem framework (L1)
    end
  end
end
```

- **Sem framework** (L1): `#call` roteia com `case` sobre
  `[request_method, path]` (use `Rack::Request` e/ou pattern matching sobre
  `path.split("/")`). São ~10 rotas; Sinatra/Roda não entram.
- Requires: apenas `json`, `rack`, os stores/tipos do núcleo. **Regra
  constitucional auditável** (doc 07 §4): `server/` **não** importa Executor,
  stores de escrita além de leitura, nem RubyLLM.
- `catalogs:`/`registries:` são recebidos e guardados mas só serão usados pelo
  `/admin` (task 25). Rotas `/admin*` respondem 404 até a task 25 plugar.
- Rota desconhecida → `404` `text/plain` `"not found"` (mesmo shape da Fase 0).

Tabela de rotas COMPLETA (doc 07 §2) — implementada nos Steps 2–7:

| Rota | Command/leitura | Resposta |
|------|-----------------|----------|
| `POST /v1/commands/:type` | genérica: body → `Command.build(type, payload, transport: :http)` → bus | controle: 200 JSON; turno: 202 `{task_id}` |
| `POST /v1/sessions` | açúcar p/ `create_session` | 201 `{session}` |
| `POST /v1/messages` | açúcar p/ `send_message`; `?stream=true` (default) | SSE de eventos da task; `stream=false` → 200 JSON agregado no `:done` |
| `GET  /v1/sessions/:id` | leitura direta SessionStore (não é Command — D3) | 200 `{session}` |
| `GET  /v1/tasks/:id` | leitura TaskStore | 200 `{task}` |
| `GET  /v1/events?task_id=&session_id=` | `EventStream.subscribe` | SSE contínuo |
| `POST /agent/messages` | **legado Fase 0** → traduz p/ `send_message` | SSE idêntico à Fase 0 |

Mapeamento erro→status (doc 07 §3/§6), centralizado num `rescue` único em
`#call` (em torno do roteamento):

- JSON malformado (`JSON::ParserError`) → **400**, antes de qualquer dispatch.
- `Harness::ValidationError` → **422**.
- `Harness::NotFoundError` → **404**.
- `Async::TimeoutError` do dispatch síncrono (ver Step 2) → **504**.
- Demais `StandardError` → **500**.
- Corpo de erro sempre:
  `{"error": {"class": "Harness::ValidationError", "message": "..."}}`.
- **`PolicyDenied` nunca vira 403** (doc 07 §3): ele acontece **dentro do
  fiber**, depois do 202/SSE aberto, e viaja como evento
  `:policy_denied`/`:task_failed` no stream (e fica em `GET /v1/tasks/:id`).
  O 403 fica **reservado** para um eventual dispatch síncrono futuro — não
  mapeie nada para 403 nesta fase.

Só erros **síncronos** (antes do fiber — doc 03 §6: `ValidationError`/
`NotFoundError` acontecem no handler, antes da Task existir) viram status HTTP.

#### Step 2: Rotas de Command — genérica + açúcar

**File:** `server/app.rb`

`POST /v1/commands/:type` (L2):

1. `payload = JSON.parse(req.body.read, symbolize_names: true)` (body vazio →
   `{}`).
2. `command = Harness::Command.build(type.to_sym, payload, transport: :http)`
   (`Command.build` é da task 9, doc 03 §2).
3. `result = dispatch_with_timeout(command)` — envolver em
   `Async::Task.current.with_timeout(10)` (doc 07 §6: request síncrono de
   controle estourando 10s → 504; para Commands de turno o dispatch retorna
   imediato — o timeout é inócuo). Nunca `Timeout.timeout` (D4).
4. Distinção controle vs turno **pelo shape do resultado** (o transporte não
   conhece semântica — D3/L2): Commands de turno retornam `{ task_id: }`
   (doc 03 §2) → **202** com esse hash; qualquer outro resultado → **200**
   com `result.respond_to?(:to_h) ? result.to_h : result` serializado em JSON
   (handlers de controle retornam `Session`/`Task`, que são `Data`).

`POST /v1/sessions` (açúcar): mesmo caminho com `type = :create_session`,
payload `{ vars: body[:vars] || {} }`, resposta **201** `{"session": {...}}`.

`POST /v1/messages` (açúcar p/ `send_message`): lê `?stream` da query string —
ausente ou `"true"` → SSE (Step 6); `"false"` → modo agregado (Step 6).

#### Step 3: Rotas de leitura (nunca viram Command — D3)

**File:** `server/app.rb`

- `GET /v1/sessions/:id` → `session_store.find(id)`; `nil` → 404 (mesmo corpo
  de erro do Step 1, `class: "Harness::NotFoundError"`); achado → 200
  `{"session": session.to_h}`.
- `GET /v1/tasks/:id` → `task_store.find(id)`; idem, 200 `{"task": task.to_h}`.
  É por aqui que o consumidor observa `PolicyDenied`/falhas pós-202 (doc 07 §6
  — o estado terminal fica no Task Store; nada se perde se o cliente
  desconectou).

Leitura **não passa pelo bus** — o teste de contrato (§ Testing) verifica com
um bus-espião que nenhum dispatch acontece nessas rotas.

#### Step 4: `SSEBody` — evolução da `SSEStream` da Fase 0

**File:** `server/sse_body.rb`

Assinatura do doc 07 §2:

```ruby
class SSEBody                   # evolui SSEStream
  def initialize(subscription:, heartbeat: 15)
  def each(&blk)                # "data: {json}\n\n"; heartbeat ": ping\n\n"
end
```

**Delta em relação à Fase 0** — a `SSEStream` recebia um bloco produtor (o
Runner escrevia nela); a `SSEBody` **drena uma `Subscription` do
`EventStream`** (doc 03 §2: fila `Async::Queue` própria por assinante,
`#each` bloqueia o fiber do consumidor até `#close`):

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/app/server.rb`):

```ruby
class SSEStream
  def initialize(&producer)
    @producer = producer
  end

  def each
    write = ->(event) { yield "data: #{JSON.generate(event.to_h)}\n\n" }
    @producer.call(write)
  end
end
```

Comportamento da `SSEBody`:

- Para cada evento da subscription: `yield "data: #{JSON.generate(event.to_h)}\n\n"`
  — o wire é **exatamente `Event#to_h`** (D5, doc 07 §3).
- **Heartbeat de 15s** (L6 — menor valor que atravessa idle timeouts de
  ALB/nginx de 60s com folga): se nenhum evento chega em `heartbeat` segundos,
  yield do comentário SSE `": ping\n\n"` (comentário não polui o consumidor).
  Implementação sugerida sem tocar no núcleo: fiber filho
  (`Async { subscription.each { |e| fila_interna << e } }`) + loop principal
  fazendo `with_timeout(heartbeat) { fila_interna.dequeue }` e, no
  `Async::TimeoutError`, emitindo o ping. (Se a `Subscription` real da task 10
  expuser dequeue com timeout, use-a direto e dispense a fila interna.)
- **Cliente desconectado**: sob Falcon, o `yield` levanta quando o socket
  fecha. Capturar em `ensure`/rescue e **fechar a subscription**
  (`subscription.close`) — senão a fila do subscriber vaza (doc 03 L4). A
  task **continua** (L4: a execução pertence ao runtime, não à conexão; o
  cliente reconecta em `/v1/events?task_id=`). A `SSEBody` **nunca** cancela
  ou sinaliza nada ao Executor.
- `#each` termina quando a subscription é fechada (pelo chamador, no evento
  terminal — Step 6 — ou pelo cap do Step 5).

#### Step 5: Cap de 1000 eventos por subscription

**File:** `lib/harness/event_stream.rb` (path real da task 10)

Doc 07 §5: um cliente lento acumula na **própria** fila; ao exceder **1000
eventos** enfileirados numa `Subscription`, a subscription **fecha** com um
evento `:error` local (enfileira `Event` de tipo `:error` com
`{ message: "subscription overflow" }` e fecha). O turno da task **nunca**
espera transporte — o `emit` continua O(subscribers), nunca bloqueia.

Se a task 10 já tiver implementado o cap, apenas confirme e cubra com teste
aqui; se não, adicione na `Subscription` (contagem no push; é o único ponto
que conhece o tamanho da fila). Não mude a assinatura pública do doc 03 §2.

#### Step 6: Rotas SSE — `/v1/messages` (stream e agregado) e `/v1/events`

**File:** `server/app.rb`

Fluxo do doc 07 §4 para `POST /v1/messages` (default `stream=true`):

```
subscription = event_stream.subscribe(...)   # ANTES do dispatch
bus.dispatch(command)                        # fiber da task começa
SSEBody drena a subscription até evento terminal
```

- **Assine antes de despachar.** Sob Async, o fiber da task pode rodar
  eagerly até o primeiro ponto de yield e emitir `:task_started` antes de o
  dispatch retornar — assinar depois perderia eventos. Como o `task_id` só
  existe **depois** do dispatch, assine **sem filtro**
  (`event_stream.subscribe`) e filtre no transporte: um wrapper privado do
  App (decorator fino de `Subscription`, só `#each`/`#close` delegados) que
  descarta eventos com `meta[:task_id] != task_id` e **fecha a subscription
  após repassar o evento terminal** da task (`:done`, `:task_failed`,
  `:task_cancelled` — mais `:error` de compat). Ver Notes.
- Resposta: `200` com headers SSE (idênticos à Fase 0:
  `content-type: text/event-stream`, `cache-control: no-cache`,
  `connection: keep-alive`) e body = `SSEBody.new(subscription: filtrada)`.
- **`stream=false`** (doc 07 §3): o transporte assina do mesmo jeito, despacha,
  e **agrega** iterando a subscription filtrada no próprio fiber da request:
  acumula os `delta` dos eventos `:content` e a lista de eventos; ao ver
  `:done` responde `200` JSON
  `{content:, task_id:, events: [...opcional...]}`; ao ver `:task_failed`
  responde `200` com `{task_id:, error: {class:, message:}, events: [...]}`
  (o Command foi aceito; a falha é da task e também está em
  `GET /v1/tasks/:id` — ver Notes sobre o shape).

`GET /v1/events?task_id=&session_id=`: aqui os filtros **são conhecidos** —
use `event_stream.subscribe(task_id: params["task_id"], session_id:
params["session_id"])` (ambos `nil` = todos, doc 03 §2) e `SSEBody` direto.
Stream **contínuo** (doc 07 §2): não fecha em evento terminal — encerra por
desconexão do cliente ou cap. É a rota de reconexão pós-queda (doc 07 §6).

#### Step 7: Rota legada `POST /agent/messages` — byte-compatível

**File:** `server/app.rb`

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/app/server.rb` — o contrato a preservar):

```ruby
# POST /agent/messages
#   { "message": "...", "history": [{"role":"user","content":"..."}], "context": {} }
# -> text/event-stream de Events
APP = lambda do |env|
  req = Rack::Request.new(env)
  # ...
  payload = JSON.parse(req.body.read, symbolize_names: true)
  agent_id = payload[:agent] || "sales"
  message = payload.fetch(:message)
  history = payload[:history] || []
  # ... SSEStream + RUNNER.run(agent_id, message, history: history, &write)
  headers = {
    "content-type" => "text/event-stream",
    "cache-control" => "no-cache",
    "connection" => "keep-alive"
  }
  [200, headers, body]
end
```

Na Fase 1 a rota **traduz para `send_message`** (doc 07 §2) em vez de chamar
o Runner (que não existe mais — doc 03 §8):

1. Parse do body; `agent = payload[:agent] || "sales"`;
   `message = payload[:message]`; `history = payload[:history] || []`
   (comportamento D2: `history` presente → nada é persistido, paridade
   Fase 0).
2. `Command.build(:send_message, { agent:, message:, history: }, transport: :http)`.
3. Mesmo mecanismo do Step 6 stream=true: subscribe → dispatch → `SSEBody`
   filtrada pela task, fechando no terminal.
4. Headers **idênticos** aos da Fase 0 (snippet acima); status 200; wire
   `data: {json}\n\n`. O `meta` novo do `Event#to_h` é **aditivo** — o
   consumidor Fase 0 ignora chaves novas (doc 07 §3); `:done` e `:error`
   continuam existindo (D5: mantidos pelo contrato com o consumidor atual).

#### Step 8: Wiring — `APP` construída com injeção

**File:** `config/wiring.rb`

Doc 07 §8: `config/wiring.rb` continua o **único composition root**; a `APP`
passa a ser construída com as dependências injetadas (as constantes globais da
Fase 0 — `REGISTRY`, `CATALOG`, `PROFILES` etc. — são mantidas como atalho,
mas a classe aceita injeção para teste):

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/config/wiring.rb`, trecho final — o que o `RUNNER` era, o `App` injetado vira):

```ruby
RUNNER = AgentRuntime::Runner.new(
  registry: REGISTRY,
  catalog: CATALOG,
  system_prompt: SYSTEM_PROMPT,
  profiles: PROFILES
)
```

Na Fase 1 (usando bus/stores/event_stream construídos nas tasks 5–13):

```ruby
APP = Harness::Server::App.new(
  command_bus: BUS, event_stream: EVENT_STREAM,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
  registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
  config: { bind: ..., port: ..., admin_token: ENV["HARNESS_ADMIN_TOKEN"], allowed_origins: [] }
)
```

(O shape de `config` é o do doc 07 §3; `admin_token`/`allowed_origins` só são
consumidos na task 25; `bind`/`port` na task 26.)

### Edge Cases to Handle

1. **Body vazio ou sem content-type** em POST → tratar como `{}`; a validação
   de payload é do handler (doc 07 §4: transporte valida só JSON bem-formado).
2. **JSON malformado** → 400 **antes** de qualquer dispatch (doc 07 §6).
3. **`:type` desconhecido** na rota genérica → o bus levanta (handler não
   registrado). Se a task 9 mapear isso para `ValidationError`/`NotFoundError`,
   o rescue do Step 1 já resolve (422/404); confirme no código real.
4. **Cliente desconecta no meio do SSE** → subscription fechada, task segue
   (L4); nenhum estado do turno depende da conexão.
5. **Task falha depois do 202/SSE aberto** → erro viaja como
   `:task_failed`/`:error` no stream; nunca vira status HTTP (doc 07 §6).
6. **`PolicyDenied`** → jamais 403 (reservado); é evento no stream + estado em
   `GET /v1/tasks/:id`.
7. **Cliente lento** → fila da subscription cresce até 1000 → fecha com
   `:error` local; o turno nunca espera transporte.
8. **`stream=false` com task que nunca termina** — o turno tem
   `turn_timeout` de 300s (D4) que garante evento terminal; o transporte não
   adiciona timeout próprio nesse modo.
9. **Rota/método errado** (`GET /v1/commands/x`, `PUT` etc.) → 404 "not found".

## Testing

### Unit Tests

**File:** `spec/harness/server/app_spec.rb` (com `Rack::MockRequest` + bus/stores **duplos** — doc 07 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| genérica traduz | `POST /v1/commands/cancel_task` body `{task_id}` | bus recebe `Command(type: :cancel_task, payload: {task_id:}, meta.transport: :http)` |
| controle → 200 | dispatch duplo retorna um `Data` (Task) | 200, JSON do `to_h` |
| turno → 202 | dispatch duplo retorna `{task_id: "t-1"}` | 202 `{"task_id":"t-1"}` |
| açúcar sessions | `POST /v1/sessions` `{vars:{a:1}}` | Command `:create_session`; 201 `{"session":{...}}` |
| açúcar messages | `POST /v1/messages?stream=false` | Command `:send_message` com payload traduzido |
| leitura não é Command | `GET /v1/sessions/:id` e `GET /v1/tasks/:id` | store `.find` chamado; **zero** dispatch no bus-espião |
| leitura 404 | `find` → nil | 404 com corpo de erro padrão |
| JSON malformado | `POST /v1/commands/x` body `"{oops"` | 400, **zero** dispatch |
| ValidationError → 422 | bus duplo levanta `Harness::ValidationError` | 422 `{"error":{"class":"Harness::ValidationError",...}}` |
| NotFoundError → 404 | bus duplo levanta `Harness::NotFoundError` | 404 |
| erro genérico → 500 | bus duplo levanta `RuntimeError` | 500 |
| timeout síncrono → 504 | bus duplo dorme > 10s (fake com `Async` sleep) | 504 |
| nunca 403 | nenhum caminho do App produz 403 | grep do código de status no App / caso PolicyDenied assíncrono chega como evento |
| stream=false agrega | eventos roteirizados `:content`×2 + `:done` na subscription | 200 `{content: "ab", task_id:, events:[...]}` |
| stream=false com falha | `:task_failed` roteirizado | 200 com `error: {class:, message:}` |
| rota desconhecida | `GET /nada` | 404 "not found" |

**File:** `spec/harness/server/sse_body_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| formato do wire | evento na subscription | chunk `data: {Event#to_h em JSON}\n\n` |
| ordem | 3 eventos com `seq` 1..3 | chunks na mesma ordem |
| heartbeat | subscription sem eventos por > heartbeat (usar `heartbeat: 0.05` no teste) | chunk `": ping\n\n"` emitido |
| fechamento terminal | chamador fecha a subscription | `#each` retorna |
| cliente desconecta | bloco do `each` levanta (socket fechado simulado) | `subscription.close` chamado; nenhuma exceção escapa |
| task segue após desconexão | executor duplo com spy | nenhum cancel/stop é invocado (L4) |
| cap de fila | 1001 eventos emitidos sem consumo | subscription fecha com evento `:error` local; `emit` nunca bloqueia |

### Integration Tests (if applicable)

**File:** `spec/harness/server/legacy_contract_spec.rb` (regressão Fase 0 — doc 07 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| contrato legado | `POST /agent/messages` `{agent, message, history}` com executor duplo emitindo `:content`* + `:done` | mesma sequência de tipos de evento da Fase 0 (`:content`* → `:done`); shape compatível (chaves da Fase 0 no topo; `meta` aditivo ignorável) |
| default de agente | body sem `agent` | Command com `agent: "sales"` |
| headers | resposta SSE | `content-type: text/event-stream`, `cache-control: no-cache`, `connection: keep-alive`, status 200 |
| history-only | `history` presente | payload traduzido com `history`, sem `session_id` (D2) |

## Definition of Done

- [ ] Tabela de rotas do doc 07 §2 completa (genérica + 2 açúcares + 2 reads + `/v1/events` + legado)
- [ ] Mapeamento erro→status completo (400/404/422/500/504); nenhum caminho produz 403 (reservado)
- [ ] `stream=false` agrega no `:done`/`:task_failed`
- [ ] `SSEBody` com heartbeat 15s default, wire `Event#to_h`, fecho limpo
- [ ] Cap de 1000 eventos por subscription; cliente desconecta → subscription fechada e task segue (L4)
- [ ] Teste de regressão do `/agent/messages` verde (contrato Fase 0)
- [ ] `server/` não referencia Executor, RubyLLM nem métodos de escrita de store (auditável — doc 07 §4)
- [ ] `config/wiring.rb` constrói a `APP` por injeção (globals mantidos como atalho)
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já
  estiverem implementadas quando você pegar esta task, leia o código real —
  ele prevalece sobre o estado planejado aqui.
- **Lacuna do doc 07 §4 (ordem subscribe/dispatch):** o pseudocódigo mostra
  `subscription = event_stream.subscribe(task_id:)` **antes** do dispatch,
  mas o `task_id` só existe depois. O Step 6 resolve com subscribe-sem-filtro
  antes do dispatch + filtro por `task_id` no transporte (decorator fino) —
  não perde `:task_started` mesmo com execução eager do fiber e não toca na
  assinatura da `Subscription` (doc 03 §2). Se a task 10 tiver entregue outra
  solução (ex.: filtro tardio na Subscription), use-a.
- **Shape do `stream=false` em falha:** o doc 07 §3 diz que a resposta sai no
  `:done`/`:task_failed` mas só especifica `{content:, task_id:, events:}`.
  O corpo com `error:` espelhando o data do `:task_failed` é a menor extensão
  coerente (o estado também está no Task Store). Registrado aqui como escolha,
  não re-decisão de arquitetura.
- Erros de validação no legado agora retornam 422 (mapeamento formal §3); a
  Fase 0 devolvia 500 genérico do Rack nesses casos. O teste de contrato do
  doc 07 §7 cobre a sequência de eventos do caminho feliz — a mudança em erro
  é melhoria compatível.
- Convenções: `# frozen_string_literal: true`, comentários em português,
  classes pequenas; JSON da stdlib.

---

## Conclusão

- **Concluído em:** 2026-07-10
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 36 novos + 4 de regressão do review, 0 falhas (581 total)
- **Arquivos criados:** `server/app.rb`, `server/sse_body.rb`, `config/wiring.rb`,
  `spec/harness/server/app_spec.rb`, `spec/harness/server/sse_body_spec.rb`,
  `spec/harness/server/legacy_contract_spec.rb`, `spec/support/server_doubles.rb`
- **Arquivos modificados:** `lib/harness/event_stream.rb` (cap de 1000 + close
  idempotente), `Gemfile` + `Gemfile.lock` (rack ~> 3.0)
- **Observações / desvios do plano:**
  - **Timeout síncrono configurável.** O doc/Step 2 fixa `with_timeout(10)`;
    implementado como `config[:sync_timeout]` com default 10 para permitir o
    teste de 504 rodar rápido (injeta 0.05). Default honra o doc 07 §6.
  - **`config/wiring.rb` mínimo por design.** Constrói `APP` por injeção com
    backend Memory, `PROFILES`/catálogos vazios e os 5 handlers registrados. O
    grafo completo (backend por config, perfis de disco, plugins, recovery,
    `Server::Boot`) é explicitamente da task 26, que **refatora** este arquivo.
    Não se criou `config.ru` (arquivo da task 26).
  - **Shape do `stream=false` em falha:** corpo `{task_id:, error:{class:,
    message:}, events:}` espelhando o data do `:task_failed` (menor extensão
    coerente — registrado no doc como escolha, não re-decisão de arquitetura).
  - **Regra constitucional (doc 07 §4):** `server/` importa só `json`, `rack`,
    `async` e tipos do núcleo — nenhum require de Executor/RubyLLM/escrita de
    store. Teste dedicado garante que nenhum caminho do App produz status 403.

### Code review (high effort, fan-out 3 finders + verificação)

Confirmados e **corrigidos** nesta task:
1. `event_stream#emit` iterava o array de subscriptions enquanto `close`
   (disparado pelo overflow do cap) o mutava via `on_close` → o próximo
   assinante era pulado. Fix: iterar `@subscriptions.dup`. Regressão dedicada.
2. Cap contava eventos de **todas** as tasks (subscription sem filtro) e o
   `:error` de overflow saía com `task_id: nil` (filtrado fora → stream trunca
   em silêncio). Fix: `Subscription#bind(task_id:)` chamado após o dispatch.
   Simplificação: cap por `@queue.size` (sem contador paralelo).
3. `stream=false` reportava `:task_cancelled`/`:error` como 200 de sucesso.
   Fix: ambos viram `error:` no corpo agregado.
4. `GET /v1/tasks/:id` serializava `executions` como string opaca (`Data#to_h`
   raso). Fix: `task_to_h` desce a serialização das Executions.
5. Endurecido `turn_result?` para exigir `task_id` não-nil.

**Diferido para a task 26 (fix de altitude — posse do reactor):** o fiber do
turno nasce como **filho do fiber da request** (`TaskActor(parent:
Async::Task.current)`); em disconnect/após-202 o runtime pode cancelar o turno,
contrariando a garantia L4. O fix correto é o `Server::Boot` dar ao Executor um
escopo de vida-longa — registrado nas Notes da task 26 (é pré-condição do smoke
E2E dela). Não se aplicou bandaid no transporte.
