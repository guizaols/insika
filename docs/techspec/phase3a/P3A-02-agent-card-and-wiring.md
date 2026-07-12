# P3A-02 — `AgentCard` + `Server::A2A::App` + rotas + wiring

> **RFC base:** 0007 (Service Platform), 0002 §1 (transporte→Command).
> **Novo:** `server/a2a/agent_card.rb`, `server/a2a/app.rb`.
> **Evolui:** `server/app.rb` (rotas), `config/wiring.rb`, `config.ru`/`server/boot.rb`
> (nada — o App já nasce por injeção). **Overview:** D1, D5, D6.

## Objetivo

O handler A2A de borda (compõe os módulos puros de P3A-01) e sua descoberta
(AgentCard) + a rota no servidor + o wiring. Aqui mora o ÚNICO ponto que toca o
`command_bus`/stores — traduzindo, nunca executando (D1).

## `Server::A2A::AgentCard` (`server/a2a/agent_card.rb`)

```ruby
module Harness::Server::A2A
  module AgentCard
    # Monta o AgentCard (Hash) do agente exposto (D5). skills do SkillCatalog
    # (name+description, nível 1). -> Hash JSON-serializável.
    def self.build(agent:, base_url:, skills: [], version: "0.1.0")
      {
        name: agent.id, description: agent.base_prompt.to_s[0, 280],
        url: "#{base_url}/a2a", version: version,
        protocolVersion: "0.2.5",                # A2A wire (confirmar, ver 00 §aberto)
        capabilities: { streaming: false, pushNotifications: false, stateTransitionHistory: false },
        defaultInputModes: ["text/plain"], defaultOutputModes: ["text/plain"],
        skills: skills.map { |s| { id: s.name, name: s.name, description: s.description, tags: [] } }
      }
    end
  end
end
```

- **L1 — um agente (D5):** `agent` = o `AgentProfile` de `config[:a2a_agent]`.
  `skills` = `skill_catalog.effective(agent.skills)` (nível 1). `base_url` do CONFIG
  (ex.: `HARNESS_PUBLIC_URL` ou derivado do bind).
- **L2 — capabilities honestas:** `streaming:false`/`pushNotifications:false` — o
  cliente A2A NÃO tenta `message/stream` (evolução). Não mentir sobre capability.

## `Server::A2A::App` (`server/a2a/app.rb`) — o handler

Sub-app injetado, espelha o `Admin::App` (recebe bus/stores; nunca escreve store
direto — só via Command; leitura direta para `tasks/get`, D6).

```ruby
module Harness::Server::A2A
  class App
    def initialize(command_bus:, task_store:, session_store:, profiles:, skill_catalog:, config:)
      # config: { a2a_agent:, base_url:, ... }

    # POST /a2a — JSON-RPC. `body` já é o Hash desserializado (o Server::App
    # parseia o JSON cru e trata malformado como -32700 ANTES daqui).
    def rpc(body)          # -> Hash (envelope JSON-RPC result|error) ; NUNCA levanta (D4)

    # GET /.well-known/agent-card.json
    def agent_card         # -> Hash (AgentCard)
  end
end
```

### Fluxo do `rpc` (D1/D2/D4)

```
Protocol.parse(body) -> [:error,e] ? devolve Protocol.error(e...)
                     -> [:ok, {id, method, params}]:
  case method
  when "message/send":
    # contextId (A2A) = session_id (D3). Ausente -> cria sessão (o SERVIDOR
    # atribui o contextId, como o A2A espera); assim tasks/get sempre tem
    # transcript de onde ler o conteúdo terminal (L4).
    session_id = params.dig("message","contextId") || params["contextId"]
    session_id ||= @command_bus.dispatch(Command.build(:create_session, {}, transport: :a2a)).id
    text = Message.text_from(params["message"])
    cmd = Command.build(:send_message,
            { agent: @config[:a2a_agent], message: text, session_id: session_id },
            transport: :a2a)
    result = @command_bus.dispatch(cmd)          # -> { task_id: }
    task = @task_store.find(result[:task_id])
    Protocol.result(id, TaskProjection.call(task, at: now))
  when "tasks/get":
    task = @task_store.find(params["id"]) or raise NotFoundError (task)
    content = terminal_content(task)             # última msg assistant do transcript da sessão
    error   = terminal_error(task)               # error["message"] do último Execution :failed
    Protocol.result(id, TaskProjection.call(task, content:, error:, at: now))
  when "tasks/cancel":
    @command_bus.dispatch(Command.build(:cancel_task, { task_id: params["id"] }, transport: :a2a))
    task = @task_store.find(params["id"])
    Protocol.result(id, TaskProjection.call(task, at: now))
  else Protocol.error(id, METHOD_NOT_FOUND, "método '#{method}' não suportado")
  rescue StandardError => e
    code, msg = Errors.from_exception(e); Protocol.error(id, code, msg)
```

- **L3 — `message/send` devolve a Task (D2):** dispatch assíncrono; lê a Task
  recém-criada e projeta o estado corrente (`submitted`/`working`). O cliente faz
  `tasks/get` até terminal. Sem bloquear.
- **L4 — conteúdo terminal em `tasks/get`** (resolvido): o conteúdo final vive no
  **transcript da sessão** (o `persist_turn` faz `session_store.append_messages`
  com `{role:"assistant", content:}`). `terminal_content(task)` = última mensagem
  `assistant` de `session_store.find(task.session_id).messages` (nil se sem
  sessão/mensagem). Por isso `message/send` SEMPRE usa sessão (cria quando
  ausente) — garante o transcript. `terminal_error(task)` = `error["message"]` do
  último `Execution` quando `outcome == :failed`. Sem acoplar checkpoint.
- **L5 — `rescue` de topo (D4):** qualquer exceção → `Errors.from_exception` →
  error object. O `A2A::App` nunca deixa vazar 500 sem envelope.

## Rotas no `Server::App` (`server/app.rb`)

No `route` (pattern match já existente), antes do `else`:

```ruby
in ["POST", ["a2a"]]
  handle_a2a(req)
in ["GET", [".well-known", "agent-card.json"]]
  json_response(200, @a2a.agent_card)
```

```ruby
# POST /a2a — JSON malformado -> -32700 (envelope A2A, NÃO o error HTTP genérico).
def handle_a2a(req)
  body = begin
           parse_body(req)
         rescue StandardError
           return json_response(200, A2A::Protocol.error(nil, A2A::Errors::PARSE_ERROR, "parse error"))
         end
  json_response(200, @a2a.rpc(body))   # JSON-RPC: sempre 200; erro vai no envelope
end
```

- **L6 — HTTP 200 sempre** (JSON-RPC transporta o erro no corpo, não no status) —
  exceto o AgentCard (200 normal) e 404 para rota A2A errada. O `Server::App` ganha
  `@a2a` no construtor (default `nil` → rota A2A responde 404, paridade: deployments
  sem A2A não expõem nada).
- **CORS/OPTIONS:** o A2A entrada é server-to-server (sem browser) — reusa o CORS
  estrito existente; sem tratamento especial nesta fatia.

## Wiring (`config/wiring.rb`)

```ruby
# --- A2A edge (P3A, RFC-0002 §1) — inbound federation -----------------------
A2A_APP =
  if (a2a_agent = ENV["HARNESS_A2A_AGENT"]) && PROFILES[a2a_agent]
    Harness::Server::A2A::App.new(
      command_bus: BUS, task_store: TASK_STORE, session_store: SESSION_STORE,
      profiles: PROFILES, skill_catalog: CATALOG,
      config: { a2a_agent: a2a_agent, base_url: CONFIG[:public_url] || "http://localhost:#{CONFIG[:port]}" }
    )
  end
# Server::App.new(..., a2a: A2A_APP)
```

- **L7 — opt-in por config:** sem `HARNESS_A2A_AGENT` (ou agente inexistente) →
  `A2A_APP = nil` → o servidor não expõe A2A (paridade). Exige `require`s dos
  arquivos `server/a2a/*` no boot (`server/app.rb` já é carregado pelo `config.ru`;
  os `server/a2a/*.rb` entram via `require_relative` no `server/app.rb` ou no boot).

## Testes

- **AgentCard**: shape com name/url/capabilities(streaming:false)/skills/modes.
- **`A2A::App#rpc`** (com bus/stores reais ou fakes, sem HTTP): `message/send` →
  `send_message` no bus + Task projetada; `tasks/get` → projeção do estado;
  `tasks/cancel` → `cancel_task` + `canceled`; método desconhecido → `-32601`;
  task inexistente → `-32001`; exceção interna → `-32603` (nunca vaza).
- **`Server::App` roteamento**: `POST /a2a` → `@a2a.rpc`; JSON malformado →
  `-32700`; `GET /.well-known/agent-card.json` → card; sem `@a2a` → 404.
- **Smoke E2E** (P3A-02, task de smoke): via `Server::App` real + bus/Executor +
  RubyLLM mockado — os 6 critérios do 00-overview.

## Fora de escopo (evolução)

Cliente A2A outbound (tool/capability que chama outros agentes); multi-agente no
AgentCard/registry; auth (`securitySchemes`); streaming/push.
