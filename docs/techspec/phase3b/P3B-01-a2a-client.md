# P3B-01 — `A2A::Client` (outbound) + `A2A::Http` adapter

> **RFC base:** 0002 §1 (A2A é transporte). **Novo:** `server/a2a/client.rb`,
> `server/a2a/http.rb`. **Reusa:** `server/a2a/{protocol,message}.rb` (P3A).
> **Overview:** D2, D3, D4.

## Objetivo

Chamar um agente A2A remoto: montar `message/send`/`tasks/get` (JSON-RPC), parsear
a resposta, ler a Task remota, e o helper `call` = send + poll até terminal. O
`Client` é PURO (http injetado) — testável com fake e usável em loopback.

## `A2A::Client` (`server/a2a/client.rb`)

```ruby
module Harness::Server::A2A
  class RemoteError < StandardError
    attr_reader :code
    def initialize(code, message) ; @code = code ; super(message) ; end
  end

  class Client
    TERMINAL = %w[completed failed canceled rejected input-required].freeze

    def initialize(http:, poll_max: 30, sleeper: nil)
      # http: duck-type post_json(url, body_hash) -> Hash (envelope JSON-RPC).
      # sleeper: callable(seconds) -> nil (default: Async task sleep; testes: no-op).

    # -> remote A2A Task (Hash) | raise RemoteError. Monta message/send.
    def send_message(url, text, context_id: nil)

    # -> remote A2A Task (Hash) | raise RemoteError.
    def get_task(url, task_id)

    # Alto nível (D3): send + poll get_task até terminal. -> { text:, state:, id: }
    # (completed/input-required trazem text) OU { error:, state:, id: } (falha).
    def call(url, text, context_id: nil)
  end
end
```

### Decisões

- **L1 — request via `Protocol`, parts via `Message`:** `send_message` monta
  `params = { message: { role: "user", parts: [{ kind: "text", text: }],
  contextId? } }` e o envelope JSON-RPC (`jsonrpc/id/method/params`). `id`
  incremental interno.
- **L2 — parse do envelope:** resposta com `"error"` → `raise RemoteError(code,
  message)`; com `"result"` → a Task remota (Hash). Chaves STRING (JSON do wire).
- **L3 — leitura da Task remota (inverso da projeção):** `remote_state(task) =
  task.dig("status","state")`; `remote_text(task) = Message.text_from(task.dig(
  "status","message"))`; `remote_id(task) = task["id"]`.
- **L4 — `call` faz poll (D3):** `t = send_message(...)`; enquanto
  `remote_state(t)` não estiver em `TERMINAL` e `tentativas < poll_max`: `sleeper.
  (delay)`; `t = get_task(url, remote_id(t))`. No fim: `completed`/`input-required`
  → `{ text: remote_text(t), state:, id: }`; `failed`/`canceled`/`rejected` →
  `{ error: remote_text(t) || state, state:, id: }`; poll estourou →
  `{ error: "remote task não concluiu", state:, id: }`.
- **L5 — `RemoteError` (envelope error) em `call`** vira `{ error: message,
  state: "failed" }` (o `Tools::A2ARemote` já devolve isso ao modelo, D4) — o
  `call` NÃO levanta; encapsula. `send_message`/`get_task` levantam (uso direto).

## `A2A::Http` (`server/a2a/http.rb`) — adapter de produção

```ruby
require "json"

module Harness::Server::A2A
  # Adapter HTTP sobre async-http (roda no reactor do turno). Boundary — require
  # lazy de async-http; injetado no Client, nunca no core. post_json(url, body)
  # -> Hash (JSON-RPC parseado, chaves string).
  class Http
    def initialize(internet: nil)   # internet lazy: Async::HTTP::Internet.new
    def post_json(url, body)        # POST JSON; JSON.parse(resposta)
    def close                        # fecha o internet (best-effort)
  end
end
```

- **L6 — boundary:** `Http` toca `async-http` (require dentro do arquivo, não em
  `lib/harness.rb`/wiring-load — D9/D5 do overview). Coberto por teste leve
  (monta o request/parseia) OU marcado como linha de fábrica; o `Client` (a
  lógica) é 100% testado com http fake. O smoke usa loopback (não `Http`).

## Testes

- **`Client`** (http fake): `send_message` monta o envelope certo (method,
  message.parts, contextId); `get_task`; `call` faz poll até completed → text;
  remoto `failed` → `{ error: }`; envelope `error` → `{ error: }` (não levanta);
  poll estoura (`poll_max`) → `{ error: }`; `input-required` → `{ text: }`.
- **`Http`** (leve): `post_json` serializa o body e parseia a resposta (com um
  internet fake/stub que devolve JSON).

## Fora de escopo (evolução)

`message/stream` do lado cliente; descoberta via AgentCard remoto; auth; retry/
circuit-breaker; FilePart/DataPart.
