# Task 06 (P3A): Rotas A2A no `Server::App`

> **Techspec:** [P3A-02-agent-card-and-wiring.md](../P3A-02-agent-card-and-wiring.md) (§Rotas no `Server::App`, L6) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Med · **Etapa:** B

## Objetivo

Plugar o handler A2A (`Server::A2A::App`, task 5) no roteador HTTP existente
(`server/app.rb`): duas rotas novas — `POST /a2a` (JSON-RPC) e
`GET /.well-known/agent-card.json` (descoberta) — mais a injeção de `@a2a` no
construtor com **default `nil`** (paridade: deployment sem `HARNESS_A2A_AGENT`
não expõe nada, ambas as rotas caem em 404). Task 100% de integração: nenhuma
lógica A2A nova nasce aqui — `handle_a2a` só traduz `parse_body` malformado em
`-32_700` (envelope, não status HTTP) e delega o resto a `@a2a.rpc`/`@a2a.agent_card`.

## Dependências

| Task | O que fornece |
|------|----------------|
| Task 05 | `Server::A2A::App` com `#rpc(body) -> Hash` (nunca levanta, D4) e `#agent_card -> Hash`, compondo Protocol/Errors/Message/TaskProjection/AgentCard das tasks 1-4 |

## Contexto

`server/app.rb` é um roteador explícito SEM framework (doc 07 §2, L1): `route`
faz `case [req.request_method, segments]` com pattern-match Ruby, um `in` por
rota, terminando num `else` que devolve `not_found` (404). O construtor
(`initialize`) recebe todas as dependências por injeção nomeada — é assim que
`Admin::App` (Control UI, P2-04) já entra hoje, com `@admin` montado dentro do
próprio `initialize` (linhas 52-56). `@a2a`, ao contrário de `@admin`, chega
**pronto** de fora (via `config/wiring.rb`, task 7) — o `Server::App` não o
constrói; só o guarda com default `nil`, igual a `checkpoint_store:` e
`pending_action_store:` (linhas 37-38), que já seguem esse padrão de
opt-in-por-omissão.

**JSON-RPC é sempre HTTP 200** (doc 07 §Rotas, L6): ao contrário das demais
rotas do arquivo — que usam status HTTP para erro (400/404/422/500/504 no
`rescue` de `#call`) — o protocolo A2A carrega o erro **no envelope do corpo**
(`{jsonrpc:, id:, error: {code:, message:}}`), nunca no status. Isso significa
que `handle_a2a` tem que capturar o `JSON::ParserError` de `parse_body` **ali
dentro**, com um `rescue` próprio, ANTES que ele suba para o `rescue
JSON::ParserError` de `#call` (que devolveria 400 — errado para A2A). O erro
vira `A2A::Protocol.error(nil, A2A::Errors::PARSE_ERROR, "parse error")`
serializado com `json_response(200, ...)`.

`@a2a` nil é o caso de paridade: um deployment que não seta `HARNESS_A2A_AGENT`
(task 7) não expõe NADA de A2A — nem o agent-card, nem o RPC. As duas rotas
precisam testar `@a2a` e cair em `not_found` se ausente, ANTES de despachar
para `handle_a2a`/`@a2a.agent_card` (chamar um método em `nil` daria
`NoMethodError`, que o `rescue StandardError` de `#call` transformaria em 500 —
errado; o contrato aqui é 404, rota inexistente, não erro interno).

`server/a2a/*.rb` (protocol, errors, message, task_projection, agent_card, app
— tasks 1-5) precisam estar `require_relative`d para os constantes
`Harness::Server::A2A::Protocol`/`Errors` resolverem dentro de `handle_a2a`. O
próprio `server/app.rb` já tem um bloco de `require_relative` no topo
(linhas 6-8: `sse_body`, `admin_auth`, `admin/app`) — os requires do A2A entram
ao lado, na mesma convenção.

## Arquivos

| Arquivo | Ação |
|---------|------|
| `server/app.rb` | MODIFY — `require_relative` dos `server/a2a/*`; `initialize` ganha `a2a: nil` → `@a2a`; `route` ganha as 2 rotas A2A (com guarda de `@a2a` nil); `handle_a2a` novo (privado) |
| `spec/harness/server/app_spec.rb` | MODIFY — cobre as 2 rotas novas + o caso `@a2a` nil |

## Passo a passo

### Passo 1 — `require_relative` dos módulos A2A

**Padrão de referência (codebase) — bloco de requires atual (linhas 3-8):**
```ruby
require "json"
require "rack"
require "async"
require_relative "sse_body"
require_relative "admin_auth"
require_relative "admin/app"
```

Acrescentar os 5 arquivos de `server/a2a/` produzidos pelas tasks 1-5 (ordem
sem dependência circular — `app.rb` de A2A é o que compõe os outros, então
vem por último):
```ruby
require_relative "sse_body"
require_relative "admin_auth"
require_relative "admin/app"
require_relative "a2a/errors"
require_relative "a2a/protocol"
require_relative "a2a/message"
require_relative "a2a/task_projection"
require_relative "a2a/agent_card"
require_relative "a2a/app"
```
> Se as tasks 1-4 tiverem agrupado os módulos puros num único arquivo (ver
> notas de implementação da task 5) ou existir um agregador `server/a2a.rb`,
> ajustar a lista de requires de acordo — o que importa é que
> `Harness::Server::A2A::Protocol`, `Harness::Server::A2A::Errors` e
> `Harness::Server::A2A::App` estejam carregados antes de `handle_a2a` rodar.

### Passo 2 — Construtor: `a2a: nil` → `@a2a`

**Padrão de referência (codebase) — `initialize` atual (linhas 36-38):**
```ruby
def initialize(command_bus:, event_stream:, session_store:, task_store:,
               catalogs:, registries:, config:, checkpoint_store: nil,
               pending_action_store: nil)
```

Acrescentar `a2a: nil` à lista de keywords (mesma posição relativa dos outros
opcionais — depois de `pending_action_store:`) e atribuir no corpo, ao lado das
demais atribuições diretas (linha 46, antes do bloco `@heartbeat`):
```ruby
def initialize(command_bus:, event_stream:, session_store:, task_store:,
               catalogs:, registries:, config:, checkpoint_store: nil,
               pending_action_store: nil, a2a: nil)
  @command_bus = command_bus
  @event_stream = event_stream
  @session_store = session_store
  @task_store = task_store
  @catalogs = catalogs
  @registries = registries
  @config = config
  @pending_action_store = pending_action_store # leitura p/ GET /v1/tasks/:id
  @a2a = a2a # federação inbound (P3A); nil = A2A não exposto (paridade, opt-in)
  @heartbeat = config.fetch(:heartbeat, 15)
  ...
```
Não construir nada aqui (ao contrário de `@admin`, que o próprio `initialize`
monta): `@a2a` já chega pronto — quem monta o `Server::A2A::App` é o
composition root (`config/wiring.rb`, task 7), fora deste arquivo.

### Passo 3 — Rotas no `route`

**Padrão de referência (codebase) — `case` atual (linhas 84-101):**
```ruby
case [req.request_method, segments]
in ["POST", ["v1", "commands", type]]
  handle_command(req, type)
in ["POST", ["v1", "sessions"]]
  handle_create_session(req)
in ["POST", ["v1", "messages"]]
  handle_send_message(req)
in ["GET", ["v1", "sessions", id]]
  handle_read_session(id)
in ["GET", ["v1", "tasks", id]]
  handle_read_task(id)
in ["GET", ["v1", "events"]]
  handle_events(req)
in ["POST", ["agent", "messages"]]
  handle_legacy(req)
else
  not_found # método/rota errados
end
```

Acrescentar as 2 rotas A2A **antes do `else`**, cada uma guardada por `@a2a`
(nil → `not_found`, não um `NoMethodError` disfarçado de 500):
```ruby
case [req.request_method, segments]
in ["POST", ["v1", "commands", type]]
  handle_command(req, type)
in ["POST", ["v1", "sessions"]]
  handle_create_session(req)
in ["POST", ["v1", "messages"]]
  handle_send_message(req)
in ["GET", ["v1", "sessions", id]]
  handle_read_session(id)
in ["GET", ["v1", "tasks", id]]
  handle_read_task(id)
in ["GET", ["v1", "events"]]
  handle_events(req)
in ["POST", ["agent", "messages"]]
  handle_legacy(req)
in ["POST", ["a2a"]]
  @a2a ? handle_a2a(req) : not_found
in ["GET", [".well-known", "agent-card.json"]]
  @a2a ? json_response(200, @a2a.agent_card) : not_found
else
  not_found # método/rota errados
end
```

### Passo 4 — `handle_a2a` (privado)

Colocar ao lado de `handle_legacy` (mesma seção "rotas de tradução direta"),
ANTES da seção "Fluxo de turno":

```ruby
# POST /a2a — JSON-RPC 2.0 (doc 07 §Rotas, L6). Ao contrário de TODAS as
# outras rotas, erro NUNCA vira status HTTP: o protocolo A2A carrega o erro
# no envelope do corpo. Por isso JSON malformado é capturado AQUI (rescue
# próprio), antes de subir para o `rescue JSON::ParserError` de #call (que
# devolveria 400 — errado para A2A). `@a2a.rpc` nunca levanta (D4 da task 5) —
# qualquer outro erro do núcleo já chega mapeado no envelope.
def handle_a2a(req)
  body =
    begin
      parse_body(req)
    rescue StandardError
      return json_response(200, A2A::Protocol.error(nil, A2A::Errors::PARSE_ERROR, "parse error"))
    end
  json_response(200, @a2a.rpc(body))
end
```
> `rescue StandardError`, não só `JSON::ParserError`: `parse_body` também pode
> levantar se o body não for um Hash serializável do jeito esperado — mesma
> disciplina "nunca vaza para o rescue genérico de `#call`" que a task 5 adota
> para `@a2a.rpc`.

## Edge cases

- **`@a2a` nil (sem `HARNESS_A2A_AGENT`, wiring task 7):** as 2 rotas A2A caem
  em `not_found` (404) — não em 500. É o comportamento default (paridade:
  deployments existentes, sem opt-in, continuam idênticos ao pré-P3A).
- **JSON malformado em `POST /a2a`:** vira `{jsonrpc:"2.0", id: null, error:
  {code: -32700, ...}}` com **status HTTP 200** — nunca 400 (isso é o
  `rescue JSON::ParserError` genérico de `#call`, que NÃO deve ser alcançado
  por esta rota).
- **Erro de negócio dentro de `@a2a.rpc`** (ex.: `tasks/get` de task
  inexistente, método RPC desconhecido): também vira envelope de erro com
  status 200 — resolvido inteiramente dentro de `Server::A2A::App#rpc` (task
  5); esta task não faz mapeamento de erro nenhum, só entrega o body parseado.
- **`GET /.well-known/agent-card.json`:** sempre 200 quando `@a2a` presente —
  não há "erro" de agent-card (é leitura estática de config, task 4).
- **Método HTTP errado nas mesmas rotas** (ex.: `GET /a2a` ou
  `POST /.well-known/agent-card.json`): não casa em nenhum `in` → cai no
  `else` existente → 404 (`not_found`), igual a qualquer outra rota mal
  chamada hoje.
- **Ordem dos `in`:** as rotas A2A entram DEPOIS de `["POST", ["agent",
  "messages"]]` (legado) e ANTES do `else` — pattern-match de `case/in` é
  sequencial e exclusivo por shape (`["POST", ["a2a"]]` não colide com
  nenhuma outra tupla existente), então a posição exata entre as demais rotas
  não importa; só precisa vir antes do `else`.

## Testes

**Arquivo:** `spec/harness/server/app_spec.rb`

Estender o helper `build_app` (linhas 15-24) para aceitar um `a2a:` opcional
(default `nil`, preservando os testes existentes sem alteração):
```ruby
def build_app(bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
              session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
              config: {}, a2a: nil)
  described_class.new(
    command_bus: bus, event_stream: event_stream,
    session_store: session_store, task_store: task_store,
    catalogs: {}, registries: {}, a2a: a2a,
    config: { sync_timeout: 0.05 }.merge(config)
  )
end
```

| Cenário | Verificação |
|---|---|
| `POST /a2a` com `@a2a` presente | um double de `a2a` (`rpc` retornando um Hash fixo) recebe o body parseado (símbolos) e o resultado volta serializado em JSON, status **200** |
| `POST /a2a` com body JSON malformado | status **200** (nunca 400); body é `{"jsonrpc"=>"2.0","id"=>nil,"error"=>{"code"=>-32700,...}}`; o double de `a2a.rpc` **não é chamado** |
| `POST /a2a` sem `@a2a` (default nil) | status **404** |
| `GET /.well-known/agent-card.json` com `@a2a` presente | double `agent_card` retorna um Hash fixo; status 200; body é o Hash serializado |
| `GET /.well-known/agent-card.json` sem `@a2a` | status 404 |
| `GET /a2a` (método errado) | status 404 (cai no `else` existente) |

Double simples inline (não precisa entrar em `spec/support/`, escopo local a
este spec):
```ruby
class A2ADouble
  def initialize(rpc_result: {}, agent_card_result: {})
    @rpc_result = rpc_result
    @agent_card_result = agent_card_result
    @rpc_calls = []
  end

  def rpc(body)
    @rpc_calls << body
    @rpc_result
  end

  def agent_card = @agent_card_result

  attr_reader :rpc_calls
end
```

## Definition of Done

- [ ] `server/app.rb`: `require_relative` dos `server/a2a/*` (ou agregador) no topo
- [ ] `initialize` aceita `a2a: nil` → `@a2a`
- [ ] `route` tem as 2 rotas A2A (`POST /a2a`, `GET /.well-known/agent-card.json`) antes do `else`, cada uma guardada por `@a2a` presente/nil
- [ ] `handle_a2a` implementado: `parse_body` com rescue próprio → `-32700` no envelope (200); sucesso → `@a2a.rpc(body)` serializado (200)
- [ ] `spec/harness/server/app_spec.rb` cobre: RPC ok, JSON malformado (200 + -32700, `rpc` não chamado), `@a2a` nil (404 nas 2 rotas), agent-card servido (200), método HTTP errado (404)
- [ ] Testes existentes do arquivo (rotas pré-existentes) continuam passando sem alteração de comportamento
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task NÃO decide o que `@a2a.rpc` faz com métodos RPC desconhecidos,
  `tasks/get`/`tasks/cancel`, ou o mapa de erro — isso é 100% da task 5
  (`Server::A2A::App`). Aqui só se garante que o transporte HTTP delega
  corretamente e preserva o invariante "JSON-RPC = sempre 200".
- A task 7 (wiring) é quem de fato CONSTRÓI `Server::A2A::App` e o passa como
  `a2a:` no `Server::App.new` de produção — coordenar apenas por dependência
  (`@a2a` precisa existir no construtor antes de a task 7 poder injetá-lo),
  sem tocar no mesmo arquivo (`config/wiring.rb` é exclusivo da task 7).
