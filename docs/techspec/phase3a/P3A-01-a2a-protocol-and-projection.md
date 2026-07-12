# P3A-01 — Protocolo A2A: envelope JSON-RPC + projeção Task→A2A

> **RFC base:** 0002 §1/§8 (transporte→Command; A2A estende estágios).
> **Novo:** `server/a2a/protocol.rb`, `server/a2a/task_projection.rb`,
> `server/a2a/message.rb`, `server/a2a/errors.rb`.
> **Overview:** D2, D3, D4.

## Objetivo

As traduções PURAS entre o wire A2A (JSON-RPC 2.0) e o núcleo — sem tocar servidor
nem stores. Módulos/funções determinísticas, testáveis isoladas (sem HTTP, sem
RubyLLM). O `A2A::App` (P3A-02) as compõe.

## `Server::A2A::Protocol` (`server/a2a/protocol.rb`) — envelope JSON-RPC 2.0

```ruby
module Harness
  module Server
    module A2A
      module Protocol
        # Parse de uma request JSON-RPC já desserializada (Hash). Valida a moldura
        # (jsonrpc "2.0", method String, id presente). -> [:ok, {id, method, params}]
        # | [:error, {id, code, message}] (nunca levanta).
        def self.parse(body)          # body: Hash (do JSON.parse) | não-Hash

        # Envelopes de resposta.
        def self.result(id, result)   # -> { jsonrpc: "2.0", id:, result: }
        def self.error(id, code, message, data: nil)  # -> { jsonrpc: "2.0", id:, error: {...} }
      end
    end
  end
end
```

- **L1 — JSON-RPC estrito:** falta `jsonrpc: "2.0"` ou `method` → error `-32600`
  (Invalid Request). `id` ausente → tratado como `null` (o A2A entrada não faz
  notifications; sempre respondemos). Batch (Array) → **não suportado** nesta
  fatia (error `-32600`); documentado.
- **L2 — nunca levanta:** `parse` de body não-Hash (JSON malformado já virou nada
  no App, ver P3A-02) devolve `[:error, ...]`. O parsing do JSON cru é do servidor
  (reusa `parse_body`); `Protocol.parse` recebe o Hash.

## `Server::A2A::Errors` (`server/a2a/errors.rb`) — mapa de erros

```ruby
module Harness::Server::A2A::Errors
  # JSON-RPC padrão + extensões A2A (D4).
  PARSE_ERROR      = -32_700
  INVALID_REQUEST  = -32_600
  METHOD_NOT_FOUND = -32_601
  INVALID_PARAMS   = -32_602
  INTERNAL_ERROR   = -32_603
  TASK_NOT_FOUND   = -32_001   # A2A: TaskNotFoundError
  TASK_NOT_CANCELABLE = -32_002 # A2A: TaskNotCancelableError

  # Mapeia uma exceção do núcleo -> [code, message]. Default -> INTERNAL_ERROR
  # (o App nunca vaza exceção, D4).
  def self.from_exception(error)     # Harness::NotFoundError/ValidationError/... -> [code, msg]
end
```

- `ValidationError` → `INVALID_PARAMS`; `NotFoundError` de task → `TASK_NOT_FOUND`;
  `NotFoundError` de agente/sessão → `INVALID_PARAMS`; qualquer outro →
  `INTERNAL_ERROR` (mensagem genérica, não vaza stack).

## `Server::A2A::Message` (`server/a2a/message.rb`) — parts ↔ texto

```ruby
module Harness::Server::A2A::Message
  # A2A Message (Hash) -> String (concatena os TextPart). Ignora parts não-text
  # nesta fatia (só TextPart, D4). -> String ("" se nenhum texto).
  def self.text_from(a2a_message)

  # String -> A2A Message { role:, parts: [{ kind: "text", text: }] }.
  def self.agent_message(text)       # role: "agent"
end
```

- **L3 — só `TextPart`** (`{ kind: "text", text: "..." }`, o `kind` do A2A ~v0.2+).
  `FilePart`/`DataPart` ignorados na leitura (evolução). Emissão sempre `TextPart`.
- Tolera a chave `type` (spec mais antigo) além de `kind` — normaliza na borda.

## `Server::A2A::TaskProjection` (`server/a2a/task_projection.rb`) — Task→A2A Task

```ruby
module Harness::Server::A2A::TaskProjection
  # Mapeamento de estado (D2). Task desconhecida/estado novo -> "unknown".
  STATE = {
    queued: "submitted", running: "working", waiting: "input-required",
    paused: "working", completed: "completed", failed: "failed", cancelled: "canceled"
  }.freeze

  # task (TaskStore::Task) + content(String|nil) -> A2A Task (Hash):
  #   { id:, contextId:, kind: "task", status: { state:, message?, timestamp: },
  #     artifacts: [], history: [] }
  # `content` (conteúdo final da Task) só entra em status.message quando
  # completed; num failed, a mensagem de erro entra em status.message (D3).
  def self.call(task, content: nil, error: nil, at:)
end
```

- **L4 — `contextId` = `session_id`** (D3). `id` = `task.id`. `kind: "task"`
  (discriminador A2A).
- **L5 — `status.message`:** `completed` → `agent_message(content)`; `failed` →
  `agent_message(error)`; `input-required` → mensagem opcional (pendência de
  aprovação, se houver — pode ficar `nil` nesta fatia). Estados não-terminais sem
  message.
- **L6 — `timestamp` injetado** (`at:`) — `Time` não é chamável determinístico em
  alguns contextos; o App passa `Time.now.utc.iso8601`, os testes passam fixo.
- `artifacts`/`history` vazios nesta fatia (conteúdo vai em `status.message`;
  artifacts ricos = evolução).

## Testes (fazem parte de cada task)

- **Protocol** (puro): parse válido → `[:ok, ...]`; falta jsonrpc/method →
  `INVALID_REQUEST`; batch (Array) → error; `result`/`error` shapes.
- **Errors**: cada exceção do núcleo → o código certo; default → INTERNAL_ERROR.
- **Message**: `text_from` concatena TextParts, ignora não-text, tolera `type`/
  `kind`; `agent_message` shape com role agent.
- **TaskProjection**: cada estado → o TaskState certo; `completed` traz
  `status.message` com o content; `failed` traz o erro; `contextId`=session_id;
  timestamp injetado; estado desconhecido → "unknown".

## Fora de escopo (evolução)

`message/stream` (deltas SSE como eventos JSON-RPC), artifacts incrementais,
FilePart/DataPart, push notifications, batch JSON-RPC.
