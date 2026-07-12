# Task 01 (P3B): A2A::Client — send_message/get_task

> **Techspec:** [P3B-01-a2a-client.md](../P3B-01-a2a-client.md) (§Client, L1-L3) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo
Criar `Harness::Server::A2A::Client` — cliente A2A de borda que monta a request
JSON-RPC `message/send`/`tasks/get`, parseia o envelope de resposta, e lê a Task
remota (inverso da projeção da fatia A). Este task entrega só `send_message` e
`get_task` (PARTIAL): o `#call` (send + poll até terminal) fica para a Task 2.
O `Client` é PURO — `http` é injetado (duck-type `post_json(url, body) -> Hash`),
sem tocar rede nem `async-http` diretamente, testável 100% com fake.

## Dependências
Nenhuma — reusa `A2A::Protocol`/`A2A::Message` da fatia A (P3A), já mergeados em
`main`. Pode começar já.

## Contexto
A fatia A (P3A) fez o harness SER um agente A2A inbound: `A2A::Protocol` monta/
parseia o envelope JSON-RPC do lado de quem RESPONDE (`Protocol.result`/
`Protocol.error`), e `A2A::Message` traduz `parts` A2A ↔ texto. Esta fatia (P3B)
fecha a federação do outro lado: o harness passa a CHAMAR agentes A2A remotos.
O `Client` é quem monta a request (o inverso de `Protocol.parse` do lado
servidor) e quem lê a Task remota devolvida (o inverso da projeção que o
`TaskProjection` faz do lado inbound). Este task habilita diretamente:
- **Task 2** (`Client#call`): vai chamar `send_message`/`get_task` em loop até
  estado terminal, usando exatamente os três métodos privados de leitura
  (`remote_state`/`remote_text`/`remote_id`) definidos aqui.
- **Task 4** (`Tools::A2ARemote`): vai chamar `client.call` (Task 2), que por
  sua vez depende deste task.

## Arquivos
| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `server/a2a/client.rb` | `RemoteError` + `Client` (`initialize`/`send_message`/`get_task` + leitores privados) |
| CREATE | `spec/harness/server/a2a/client_spec.rb` | Suíte com http fake (envelopes canned), sem `ruby_llm`/rede |

## Passo a passo

### Passo 1: `RemoteError`
**Arquivo:** `server/a2a/client.rb`

Comece com `# frozen_string_literal: true`, os dois `require_relative` de
`protocol` e `message` (mesmo padrão de `server/a2a/errors.rb`), e o módulo
aninhado `Harness::Server::A2A`. `RemoteError` é um `StandardError` simples com
`code` (o `code` JSON-RPC do envelope remoto, inteiro) e a mensagem herdada de
`StandardError`:

```ruby
class RemoteError < StandardError
  attr_reader :code

  def initialize(code, message)
    @code = code
    super(message)
  end
end
```

**Padrão de referência (codebase — atributo além da mensagem em erro de
domínio, `lib/harness/errors.rb`):**
```ruby
class ContextError < Error
  attr_reader :provider

  def initialize(message = nil, provider: nil)
    @provider = provider
    super(message || "provider #{provider} falhou")
  end
end
```
> Nota: `RemoteError` NÃO herda de `Harness::Error` — é um erro do adapter A2A
> (transporte), não da taxonomia do núcleo (`ValidationError`/`PolicyDenied`/
> etc. em `lib/harness/errors.rb`), então herda direto de `StandardError`, como
> os erros dos outros adapters do repo.

### Passo 2: `initialize`
**Arquivo:** `server/a2a/client.rb`

```ruby
class Client
  def initialize(http:, poll_max: 30, sleeper: nil)
    @http = http
    @poll_max = poll_max
    @sleeper = sleeper
    @next_id = 0
  end
```

`http`: duck-type `post_json(url, body_hash) -> Hash` (envelope JSON-RPC já
desserializado, chaves STRING). `poll_max`/`sleeper` não são usados por
`send_message`/`get_task` (são do `#call` da Task 2) — apenas armazenados aqui
para a assinatura já ficar estável e a Task 2 não precisar tocar o
`initialize`. `@next_id` é o contador interno do `id` incremental da request
(privado, começa em 0; cada chamada usa `next_id` e incrementa).

### Passo 3: montagem da request + `send_message`
**Arquivo:** `server/a2a/client.rb`

`send_message` monta os `parts` via o MESMO formato que `A2A::Message.text_from`
lê de volta (`kind`/`text`), e o envelope JSON-RPC com as MESMAS chaves que
`A2A::Protocol.result`/`.error` produzem do lado servidor (aqui, do lado
cliente, é o `Client` quem monta `jsonrpc`/`id`/`method`/`params` — o inverso de
`Protocol.parse`, que os DESMONTA):

```ruby
def send_message(url, text, context_id: nil)
  message = { "role" => "user", "parts" => [{ "kind" => "text", "text" => text }] }
  message["contextId"] = context_id if context_id
  request = {
    "jsonrpc" => "2.0",
    "id" => next_id,
    "method" => "message/send",
    "params" => { "message" => message }
  }
  parse_envelope(@http.post_json(url, request))
end
```

**Padrão de referência (codebase — envelope JSON-RPC do lado servidor,
`server/a2a/protocol.rb`, L27-L36 — aqui o `Client` monta o espelho da
REQUEST, não da resposta):**
```ruby
def self.result(id, result)
  { jsonrpc: VERSION, id: id, result: result }
end

def self.error(id, code, message, data: nil)
  err = { code: code, message: message }
  err[:data] = data unless data.nil?
  { jsonrpc: VERSION, id: id, error: err }
end
```
> Nota: `Protocol.result`/`.error` usam chaves SÍMBOLO (é o harness serializando
> pra fora); a REQUEST que o `Client` monta aqui também usa chaves STRING
> (`"jsonrpc"`, `"id"`, ...) porque é o formato de wire — vira JSON puro em
> `http.post_json`, sem diferença prática símbolo/string na serialização, mas
> string aqui casa com o que `parse_envelope`/`Message.text_from` leem de volta
> (a resposta SEMPRE chega com chave string, vinda de `JSON.parse`).

### Passo 4: `get_task`
**Arquivo:** `server/a2a/client.rb`

```ruby
def get_task(url, task_id)
  request = {
    "jsonrpc" => "2.0",
    "id" => next_id,
    "method" => "tasks/get",
    "params" => { "id" => task_id }
  }
  parse_envelope(@http.post_json(url, request))
end
```

### Passo 5: `parse_envelope` (privado) — L2 da tech spec
**Arquivo:** `server/a2a/client.rb`

```ruby
private

def next_id
  @next_id += 1
end

def parse_envelope(envelope)
  raise RemoteError.new(nil, "resposta remota inválida (não é objeto)") unless envelope.is_a?(Hash)

  if envelope["error"]
    error = envelope["error"]
    raise RemoteError.new(error["code"], error["message"])
  end

  envelope["result"]
end
```

`envelope["result"]` é a Task remota crua (Hash, chaves string) — não projetada
nem validada aqui; os leitores do Passo 6 é que sabem navegar essa forma.

### Passo 6: leitores da Task remota (privados) — L3 da tech spec
**Arquivo:** `server/a2a/client.rb`

```ruby
def remote_state(task) = task.dig("status", "state")

def remote_text(task) = Message.text_from(task.dig("status", "message"))

def remote_id(task) = task["id"]
```

**Padrão de referência (codebase — `Message.text_from` já tolera `kind`/`type`
e `parts` ausentes, `server/a2a/message.rb` L10-L18):**
```ruby
def self.text_from(a2a_message)
  parts = a2a_message.is_a?(Hash) ? Array(a2a_message["parts"] || a2a_message[:parts]) : []
  parts.filter_map do |part|
    next unless part.is_a?(Hash)

    kind = part["kind"] || part["type"] || part[:kind] || part[:type]
    (part["text"] || part[:text]).to_s if kind.to_s == "text"
  end.join
end
```
> Nota: `remote_text` passa `task.dig("status","message")` (pode ser `nil` se a
> Task remota ainda não tem `status.message`) — `Message.text_from(nil)` já
> devolve `""` sem levantar, então `remote_text` nunca precisa de guarda extra
> aqui.

## Edge cases
1. Envelope com `"error"` presente (mesmo com `"result"` também presente, que
   não deveria acontecer, mas se acontecer) → `error` tem prioridade, sempre
   `raise RemoteError(code, message)`; `send_message`/`get_task` NÃO fazem
   `rescue` — quem chama direto (uso avulso, fora do `#call` da Task 2) recebe
   a exceção.
2. Envelope com `"result"` → devolve o Hash da Task remota como está (sem
   normalizar/projetar) — quem consome usa `remote_state`/`remote_text`/
   `remote_id` por cima.
3. `context_id: nil` (default) → chave `"contextId"` OMITIDA de `message` (não
   `"contextId" => nil`) — espelha o `if data.nil?` de `Protocol.error` (chave
   ausente, não `nil` explícito, quando o dado opcional não veio).
4. `text` vira sempre 1 `TextPart` (`{"kind"=>"text","text"=>text}`) — nesta
   fatia não há `FilePart`/`DataPart` (fora de escopo, ver P3B-01 "Fora de
   escopo").
5. `id` da request é incremental por INSTÂNCIA do `Client` (`@next_id`,
   privado) — duas chamadas seguidas (`send_message` + `get_task`) no mesmo
   `Client` usam ids diferentes; dois `Client`s distintos reiniciam a contagem
   cada um do zero (não há id global compartilhado).
6. `envelope["error"]["code"]` pode ser `nil` (envelope malformado do remoto) —
   `RemoteError.new(nil, message)` ainda funciona (`code` fica `nil`, `message`
   vira a mensagem da exceção); não é validado/normalizado aqui.
7. Chaves da Task remota são sempre STRING (vêm de `JSON.parse` do lado do
   `http` real) — os leitores (`remote_state`/`remote_text`/`remote_id`) usam
   só `dig`/`[]` com string, nunca símbolo.
8. `remote_text`/`remote_state` chamados sobre uma Task sem `"status"` (Hash
   vazio) → `dig` devolve `nil` em cascata sem levantar; `Message.text_from(nil)`
   devolve `""`.

## Testes
**Arquivo:** `spec/harness/server/a2a/client_spec.rb`

Fake http (duplo simples, não `RSpec::Mocks::Double` estrito — só precisa
responder `post_json(url, body)`): guarda o último `body` recebido (para
inspeção das asserções de request) e devolve um envelope canned configurado
pelo teste.

| Caso | O que testa | Esperado |
|------|--------------|----------|
| `send_message` monta a request | `method`, `params.message.role/parts/kind/text` | `http.post_json` chamado com `"method"=>"message/send"`, `params["message"]["parts"]` = `[{"kind"=>"text","text"=>...}]` |
| `send_message` com `context_id:` | chave `contextId` presente | `params["message"]["contextId"] == context_id` |
| `send_message` sem `context_id:` | chave `contextId` OMITIDA | `params["message"].key?("contextId") == false` |
| `send_message` com envelope `"result"` | devolve a Task remota crua | Hash igual ao `"result"` do canned |
| `send_message` com envelope `"error"` | levanta `RemoteError` | `code`/`message` do erro batem com o envelope |
| `get_task` monta a request | `method`, `params.id` | `"method"=>"tasks/get"`, `params["id"] == task_id` |
| `get_task` com envelope `"error"` | levanta `RemoteError` | idem `send_message` |
| `id` incremental | duas chamadas no mesmo `Client` | ids diferentes (segunda > primeira) na request enviada |
| `remote_state`/`remote_text`/`remote_id` (via `send`, métodos privados) | leitura de uma Task remota canned | `state`/`text` (via `Message.text_from`)/`id` batem com o fixture |
| `remote_text` com `status.message` ausente | Task sem `"message"` em `status` | `""`, sem levantar |

## Definition of Done
- [ ] `Harness::Server::A2A::Client#send_message`/`#get_task` implementados
      exatamente com a interface de `P3B-01-a2a-client.md` (§Client, L1-L3)
- [ ] `RemoteError` com `code` + mensagem, levantado em todo envelope com
      `"error"` (nunca engolido silenciosamente)
- [ ] `Client` 100% puro — nenhum `require` de `async-http`/rede neste arquivo;
      só `http.post_json` (duck-type)
- [ ] `initialize(http:, poll_max: 30, sleeper: nil)` já com a assinatura final
      (mesmo sem uso de `poll_max`/`sleeper` neste task — Task 2 os consome)
- [ ] Suíte verde sem chave de API (http fake, sem `ruby_llm`)
- [ ] Rubocop limpo
- [ ] Code review

## Notas
- **`#call` fica para a Task 2:** este task é explicitamente PARTIAL — não
  implementa poll nem encapsulamento de erro em `{ error:, state:, id: }`. A
  Task 2 adiciona `#call` chamando `send_message`/`get_task`/
  `remote_state`/`remote_text`/`remote_id` já prontos aqui, sem tocar neste
  arquivo além de acrescentar o método público.
- **`poll_max`/`sleeper` no `initialize` já agora:** aceitos e guardados (mesmo
  sem uso) para a assinatura pública do `Client` não mudar entre Task 1 e
  Task 2 — quem instancia o `Client` (wiring, Task 6) já usa a forma final.
- **Chaves string vs símbolo:** por ser o lado que MONTA a request de wire (ao
  contrário de `Protocol.result`/`.error`, que montam a RESPOSTA do harness
  como servidor, em símbolo), este `Client` usa string em tudo que sai
  (`post_json`) e em tudo que lê de volta (`parse_envelope`/leitores) — não há
  necessidade de normalizar símbolo↔string em nenhum ponto deste task.
