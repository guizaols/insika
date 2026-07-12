# Task 01 (P3A): `A2A::Protocol` (envelope JSON-RPC) + `A2A::Errors`
> **Techspec:** [P3A-01-a2a-protocol-and-projection.md](../P3A-01-a2a-protocol-and-projection.md) (§Protocol/§Errors, D4/L1-L2) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo
Entregar a moldura JSON-RPC 2.0 do adapter A2A: `Server::A2A::Protocol` (parse
puro da request já desserializada + construtores de `result`/`error`) e
`Server::A2A::Errors` (mapa de códigos JSON-RPC/A2A + `from_exception`, que
traduz a taxonomia do núcleo em `[code, message]` sem nunca vazar stack). São os
DOIS módulos mais na base da fatia — sem eles, nada no `A2A::App` (Task 5) tem
como responder. Ambos são **puros**: nenhuma dependência de HTTP, Rack, stores
ou RubyLLM — só `Hash`/`Array` in, `Hash`/`Array` out (ou `raise` nunca, no caso
do `Protocol.parse`).

## Dependências
Nenhuma. Pode começar já — os dois arquivos são novos e exclusivos de
`server/a2a/`. As Tasks 2/3/4 (Message/TaskProjection/AgentCard) são igualmente
independentes; só a Task 5 (`A2A::App`) depende desta.

## Contexto
RFC-0002 §1 (\"todo transporte … e protocolos futuros como A2A convergem para a
MESMA pipeline\") e §8 (\"federação A2A estende estágios existentes\") fixam
que o A2A é TRANSPORTE, não caminho novo (P3A-01 D1 do overview): o
`A2A::App` vai parsear JSON-RPC, montar o `Command` certo e despachar no MESMO
`command_bus` do `Server::App` — nada de lógica de negócio aqui. Este task
entrega só a camada de tradução do ENVELOPE (a moldura JSON-RPC: `jsonrpc`,
`method`, `id`, `params`) e do MAPA DE ERROS (núcleo → código A2A) — a
serialização de conteúdo (`message/send` → texto, Task → `A2A Task`) é dos
Tasks 2/3.

`server/` é onde o adapter vive (NÃO `lib/harness/`, regra constitucional do
doc 07 §4: `server/` não importa Executor nem métodos de escrita de store) —
`Protocol`/`Errors` seguem o MESMO padrão de módulo puro sob namespace que
`Server::AdminAuth` (`server/admin_auth.rb`) já demonstra: sem `require` além
de stdlib, `module_function` ou `def self.`, testável sem `Rack::Request`. Os
dois arquivos deste task não são requeridos por ninguém ainda — `server/app.rb`
só os carrega (via `require_relative`) quando a Task 6/7 ligar o `A2A_APP`
opt-in ao `Server::App`; até lá eles só existem e são testados isoladamente.

`Errors.from_exception` reusa a MESMA taxonomia que `server/app.rb#call` já
usa no `rescue` central (`Harness::ValidationError` → 422 HTTP, hoje;
`Harness::NotFoundError` → 404 HTTP, hoje) — aqui é o espelho A2A do mesmo
mapeamento, só que para códigos JSON-RPC/A2A em vez de status HTTP. A
taxonomia inteira mora em `lib/harness/errors.rb` (Fase 1, D4): `ValidationError`
e `NotFoundError` são as duas classes relevantes para este task (as demais —
`PolicyDenied`, `ContextError`, `ProviderError`, etc. — caem todas no `else` →
`INTERNAL_ERROR`, igual ao 500 genérico do servidor HTTP).

**Cuidado ao ler `NotFoundError`:** a classe (`lib/harness/errors.rb:10`) NÃO
carrega um atributo estruturado que diga \"isso é uma task\" vs \"isso é um
agente/sessão\" — é levantada com só uma `message` livre em texto (ver
`lib/harness/task_store.rb:166` `\"task inexistente: #{id}\"`,
`lib/harness/commands/cancel_task.rb:24` `\"task '#{task_id}' não encontrada\"`
vs `lib/harness/session_store.rb:106` `\"sessão inexistente: #{id}\"`,
`lib/harness/commands/send_message.rb:24` `\"agente '#{agent}' não
configurado\"`). O único sinal disponível para distinguir \"task\" de
\"agente/sessão\" é a PRÓPRIA STRING da mensagem — daí o `from_exception` desta
task precisa inspecionar `error.message` (heurística por palavra, não por tipo)
para decidir entre `TASK_NOT_FOUND` e `INVALID_PARAMS`. Não é elegante, mas é o
que a taxonomia atual do núcleo permite sem tocar `lib/harness/errors.rb` (fora
de escopo desta fatia — ver Notas).

## Arquivos
| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `server/a2a/errors.rb` | `Harness::Server::A2A::Errors` — constantes de código + `from_exception` |
| CREATE | `server/a2a/protocol.rb` | `Harness::Server::A2A::Protocol` — `parse`/`result`/`error` |
| CREATE | `spec/harness/server/a2a/errors_spec.rb` | Suíte pura (sem HTTP, sem `ruby_llm`) |
| CREATE | `spec/harness/server/a2a/protocol_spec.rb` | Suíte pura (sem HTTP, sem `ruby_llm`) |

## Passo a passo

### Passo 1: `Server::A2A::Errors` — constantes de código
**Arquivo:** `server/a2a/errors.rb`

Comece com `# frozen_string_literal: true`. Os sete códigos são fixos pelo
protocolo (JSON-RPC 2.0 padrão + extensões A2A, P3A-01 D4 do overview) — NÃO
são um `Enum` nem precisam de validação de unicidade, são só `Integer`
constantes:

```ruby
# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Códigos JSON-RPC 2.0 padrão + extensões A2A (P3A-01 §Errors, D4 do
      # overview). `Protocol` usa os quatro primeiros para erros de MOLDURA
      # (parse/validação do envelope); o `A2A::App` (Task 5) usa o restante
      # para erros de NEGÓCIO (method desconhecido, exceção do núcleo).
      module Errors
        PARSE_ERROR         = -32_700
        INVALID_REQUEST     = -32_600
        METHOD_NOT_FOUND    = -32_601
        INVALID_PARAMS      = -32_602
        INTERNAL_ERROR      = -32_603
        TASK_NOT_FOUND      = -32_001 # A2A: TaskNotFoundError
        TASK_NOT_CANCELABLE = -32_002 # A2A: TaskNotCancelableError
      end
    end
  end
end
```

`TASK_NOT_CANCELABLE` **não tem exceção correspondente na taxonomia atual**
(`lib/harness/errors.rb`) — nenhum `raise` do núcleo hoje sinaliza \"task já
terminal, não cancelável\". É reservado para o handler `tasks/cancel` (Task 5)
usar DIRETO (sem passar por `from_exception`), quando ele checar o estado da
Task antes de despachar `cancel_task`. Não implemente esse uso aqui — só a
constante.

### Passo 2: `Errors.from_exception`
**Arquivo:** `server/a2a/errors.rb`

Adicione dentro do módulo `Errors` (abaixo das constantes):

```ruby
# Mapeia uma exceção do núcleo (lib/harness/errors.rb) -> [code, message].
# NUNCA vaza mensagem de exceção não mapeada (D4: o A2A::App nunca vaza
# exceção crua) -- default cai numa mensagem genérica fixa.
def self.from_exception(error)
  case error
  when Harness::ValidationError
    [INVALID_PARAMS, error.message]
  when Harness::NotFoundError
    task_related?(error) ? [TASK_NOT_FOUND, error.message] : [INVALID_PARAMS, error.message]
  else
    [INTERNAL_ERROR, "erro interno"]
  end
end

# Heurística por mensagem (NotFoundError não carrega um atributo de tipo —
# ver Contexto): mensagens de task sempre contêm a palavra "task" (ver
# task_store.rb, cancel_task.rb, resume_task.rb, pause_task.rb). Qualquer
# outro NotFoundError (agente, sessão, workflow, pending action) -> INVALID_PARAMS.
def self.task_related?(error)
  error.message.to_s.match?(/task/i)
end
private_class_method :task_related?
```

**Padrão de referência (codebase — taxonomia de erro, `lib/harness/errors.rb`):**
```ruby
class ValidationError < Error; end  # Command malformado -> HTTP 422, nenhuma Task criada
class NotFoundError   < Error; end  # session/task/agente inexistente -> HTTP 404
```
> Nota: no transporte HTTP (`server/app.rb#call`) as DUAS classes acima viram
> status HTTP direto (422/404) sem diferenciar \"task\" de \"agente/sessão\"
> dentro de `NotFoundError` — o A2A PRECISA diferenciar porque o protocolo A2A
> tem um código dedicado (`TaskNotFoundError`, `-32001`) que o JSON-RPC genérico
> não tem. Daí a heurística de mensagem só existir aqui, não no `server/app.rb`.

### Passo 3: `Server::A2A::Protocol` — parse da moldura
**Arquivo:** `server/a2a/protocol.rb`

```ruby
# frozen_string_literal: true

require_relative "errors"

module Harness
  module Server
    module A2A
      # Tradução PURA do envelope JSON-RPC 2.0 (P3A-01 §Protocol, L1/L2).
      # `parse` recebe o Hash já desserializado por `parse_body` (o parsing do
      # JSON cru continua no servidor -- JSON::ParserError vira 400 ANTES de
      # chegar aqui, ver server/app.rb#call). NUNCA levanta (L2): toda
      # malformação vira [:error, ...], nunca um raise.
      module Protocol
        # body: Hash (de JSON.parse symbolize_names: true) | não-Hash (Array,
        # String, Integer, true/false, nil -- outros tipos-raiz de um JSON válido).
        # -> [:ok, { id:, method:, params: }] | [:error, { id:, code:, message: }]
        def self.parse(body)
          return invalid_request(nil, "batch requests não são suportados nesta fatia") if body.is_a?(Array)
          return invalid_request(nil, "request precisa ser um objeto JSON") unless body.is_a?(Hash)

          id = body[:id] # ausente -> nil (Hash#[] já devolve nil; "id ausente = null", L1)
          return invalid_request(id, "jsonrpc deve ser \"2.0\"") unless body[:jsonrpc] == "2.0"
          return invalid_request(id, "method ausente ou não é String") unless body[:method].is_a?(String)

          [:ok, { id: id, method: body[:method], params: body[:params] || {} }]
        rescue StandardError
          # Rede de segurança (L2): mesmo um Hash "hostil" (ex.: um objeto que
          # levanta em #[]) nunca escapa como exceção crua do adapter.
          [:error, { id: nil, code: Errors::INTERNAL_ERROR, message: "erro ao parsear request" }]
        end

        def self.invalid_request(id, message)
          [:error, { id: id, code: Errors::INVALID_REQUEST, message: message }]
        end
        private_class_method :invalid_request
      end
    end
  end
end
```

**Padrão de referência (codebase — `parse_body` do servidor HTTP, `server/app.rb`):**
```ruby
# Body vazio ou sem content-type -> {} (doc 07 §4: transporte valida só
# JSON bem-formado; payload é do handler). NÃO usa req.params (consumiria
# o body como form) — lê o corpo cru.
def parse_body(req)
  raw = req.body&.read
  return {} if raw.nil? || raw.empty?

  JSON.parse(raw, symbolize_names: true)
end
```
> `Protocol.parse` NÃO faz esse parsing — recebe o resultado dele (ou o
> equivalente, no caso do `A2A::App`/Task 5) já como Ruby (`Hash`/`Array`/
> outro). `JSON::ParserError` (JSON cru malformado) é tratado ANTES, pelo
> `A2A::App`/rota (Task 5/6) — este módulo só valida a MOLDURA de um Hash já
> desserializado.

### Passo 4: `Protocol.result` / `Protocol.error`
**Arquivo:** `server/a2a/protocol.rb`

Adicione dentro do módulo `Protocol` (acima do `private_class_method`, ou em
qualquer ordem — são independentes do `parse`):

```ruby
# -> { jsonrpc: "2.0", id:, result: } (sucesso JSON-RPC).
def self.result(id, result)
  { jsonrpc: "2.0", id: id, result: result }
end

# -> { jsonrpc: "2.0", id:, error: { code:, message:, data?: } }. `data`
# só entra na resposta quando presente (omitido quando nil -- JSON-RPC trata
# `data` como opcional; um `data: nil` explícito na resposta seria ruído).
def self.error(id, code, message, data: nil)
  err = { code: code, message: message }
  err[:data] = data unless data.nil?
  { jsonrpc: "2.0", id: id, error: err }
end
```

## Edge cases
1. **Batch (Array na raiz)** → `[:error, { id: nil, code: INVALID_REQUEST, ... }]`
   — não suportado nesta fatia (documentado no overview, "Fora de escopo").
   `id` sempre `nil` no batch: não existe UM id para um Array de requests.
2. **Body não-Hash, não-Array** (`String`, `Integer`, `true`/`false`, `nil` na
   raiz do JSON) → mesmo caminho do batch, `INVALID_REQUEST`, `id: nil`.
3. **`jsonrpc` ausente ou != "2.0"** → `INVALID_REQUEST`, `id:` o que vier no
   Hash (mesmo que o resto da request esteja ok — a moldura já falhou).
4. **`method` ausente, `nil`, ou não-String** (`Integer`, `Hash`, etc.) →
   `INVALID_REQUEST`. Método **vazio** (`""`) passa na validação de moldura
   (é uma `String` válida) — decidir se `""` é um método CONHECIDO é do
   `A2A::App` (Task 5, `METHOD_NOT_FOUND`), não deste módulo (separação D1:
   `Protocol` só valida forma, não semântica de roteamento).
5. **`id` ausente do Hash** → tratado como `null`/`nil` (L1), NÃO é erro de
   moldura por si só — só `jsonrpc`/`method` inválidos disparam
   `INVALID_REQUEST`. `Hash#[]` já devolve `nil` tanto para chave ausente
   quanto para `id: null` explícito — nenhum código extra necessário para
   diferenciar os dois casos (são o mesmo, por design do protocolo).
6. **`params` ausente** → normalizado para `{}` no `:ok` (JSON-RPC trata
   `params` como opcional).
7. **`parse` nunca levanta** — mesmo um objeto que quebra em `#[]`/`#is_a?`
   cai no `rescue StandardError` do Passo 3 e devolve `[:error, ...]` com
   `INTERNAL_ERROR` (rede de segurança, não é o caminho esperado de uso).
8. **`Errors.from_exception` com exceção não mapeada** (`PolicyDenied`,
   `ContextError`, `ProviderError`, `StoreError`, `CancelledError`,
   `TimeoutError`, `CapabilityError` e subclasses, ou qualquer `StandardError`
   solto) → `INTERNAL_ERROR`, mensagem GENÉRICA fixa (`"erro interno"`), NUNCA
   `error.message` da exceção original (D4: não vaza stack/detalhe interno).
9. **`NotFoundError` de task** (mensagem contém "task", case-insensitive) →
   `TASK_NOT_FOUND`. **`NotFoundError` de agente/sessão/workflow/pending
   action** (mensagem sem "task") → `INVALID_PARAMS`.
10. **`error(id, code, message)` sem `data:`** → chave `:data` OMITIDA do Hash
    de erro (não aparece como `data: nil`).

## Testes
**Arquivos:** `spec/harness/server/a2a/protocol_spec.rb` + `spec/harness/server/a2a/errors_spec.rb`

Seguem o padrão de `spec/harness/server/admin_auth_spec.rb` (spec puro,
`require "spec_helper"` + `require_relative` direto do arquivo sob teste — os
módulos de `server/a2a/` ainda não são carregados por `lib/harness.rb` nem por
nenhum boot, então cada spec requer o arquivo explicitamente):

```ruby
# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/protocol"
```
(idem para `errors_spec.rb`, trocando `protocol` por `errors`.)

### `protocol_spec.rb`
| Caso | Input | Esperado |
|------|-------|----------|
| request válida completa | `{ jsonrpc: "2.0", method: "message/send", id: 1, params: { a: 1 } }` | `[:ok, { id: 1, method: "message/send", params: { a: 1 } }]` |
| `params` ausente | `{ jsonrpc: "2.0", method: "tasks/get", id: "x" }` | `[:ok, { id: "x", method: "tasks/get", params: {} }]` |
| `id` ausente | `{ jsonrpc: "2.0", method: "tasks/get" }` | `[:ok, { id: nil, ... }]` |
| `id: null` explícito | `{ jsonrpc: "2.0", method: "tasks/get", id: nil }` | igual ao caso anterior (mesmo resultado) |
| `jsonrpc` ausente | `{ method: "x", id: 1 }` | `[:error, { id: 1, code: -32600, message: String }]` |
| `jsonrpc` errado (`"1.0"`) | `{ jsonrpc: "1.0", method: "x", id: 1 }` | `[:error, { code: -32600, ... }]` |
| `method` ausente | `{ jsonrpc: "2.0", id: 1 }` | `[:error, { id: 1, code: -32600, ... }]` |
| `method` não-String | `{ jsonrpc: "2.0", method: 123, id: 1 }` | `[:error, { code: -32600, ... }]` |
| `method` vazio (`""`) | `{ jsonrpc: "2.0", method: "", id: 1 }` | `[:ok, ...]` (moldura válida — edge case 4) |
| batch (Array) | `[{ jsonrpc: "2.0", method: "x" }]` | `[:error, { id: nil, code: -32600, ... }]` |
| body não-Hash (String) | `"oi"` | `[:error, { id: nil, code: -32600, ... }]` |
| body não-Hash (`nil`) | `nil` | `[:error, { id: nil, code: -32600, ... }]` |
| `parse` nunca levanta | objeto duble que raise em `#[]`/`#is_a?` (se viável simular) ou input hostil equivalente | não levanta — devolve `[:error, ...]` |
| `Protocol.result` | `result(1, { foo: "bar" })` | `{ jsonrpc: "2.0", id: 1, result: { foo: "bar" } }` |
| `Protocol.error` sem `data` | `error(1, -32600, "msg")` | `{ jsonrpc: "2.0", id: 1, error: { code: -32600, message: "msg" } }` (sem chave `:data`) |
| `Protocol.error` com `data` | `error(1, -32602, "msg", data: { field: "x" })` | `error: { code:, message:, data: { field: "x" } }` |

### `errors_spec.rb`
| Caso | Input | Esperado |
|------|-------|----------|
| constantes | `Errors::PARSE_ERROR` etc. | valores exatos (`-32700`, `-32600`, `-32601`, `-32602`, `-32603`, `-32001`, `-32002`) |
| `ValidationError` | `Harness::ValidationError.new("campo obrigatório")` | `[Errors::INVALID_PARAMS, "campo obrigatório"]` |
| `NotFoundError` de task | `Harness::NotFoundError.new("task inexistente: t1")` | `[Errors::TASK_NOT_FOUND, "task inexistente: t1"]` |
| `NotFoundError` de task (outra mensagem) | `Harness::NotFoundError.new("task 't1' não encontrada")` | `[Errors::TASK_NOT_FOUND, ...]` |
| `NotFoundError` de sessão | `Harness::NotFoundError.new("sessão inexistente: s1")` | `[Errors::INVALID_PARAMS, "sessão inexistente: s1"]` |
| `NotFoundError` de agente | `Harness::NotFoundError.new("agente 'x' não configurado")` | `[Errors::INVALID_PARAMS, ...]` |
| exceção não mapeada | `Harness::PolicyDenied.new("negado")` | `[Errors::INTERNAL_ERROR, "erro interno"]` (mensagem GENÉRICA, não "negado") |
| `StandardError` solto | `StandardError.new("boom com stack sensível")` | `[Errors::INTERNAL_ERROR, "erro interno"]` (não vaza `"boom..."`) |

## Definition of Done
- [ ] `Harness::Server::A2A::Protocol.parse` implementado exatamente com a
      interface de `P3A-01-a2a-protocol-and-projection.md` (`parse`/`result`/`error`)
- [ ] `parse` nunca levanta (L2) — validado por teste com input hostil
- [ ] Batch (`Array`) e body não-Hash tratados como `INVALID_REQUEST` (L1)
- [ ] `Harness::Server::A2A::Errors` com as 7 constantes de código exatas
- [ ] `from_exception` mapeia `ValidationError`→`INVALID_PARAMS`,
      `NotFoundError` de task→`TASK_NOT_FOUND`, `NotFoundError` de
      agente/sessão→`INVALID_PARAMS`, qualquer outra exceção→`INTERNAL_ERROR`
      com mensagem genérica (nunca `error.message` da exceção não mapeada)
- [ ] Nenhum dos dois arquivos tem `require` além de stdlib/`require_relative`
      entre si (`protocol.rb` requer só `errors.rb`) — zero dependência de
      Rack, stores, Executor ou RubyLLM
- [ ] Suíte verde sem chave de API (módulos puros, sem `ruby_llm`)
- [ ] Rubocop limpo
- [ ] Code review

## Notas
- **Por que a heurística de mensagem em `NotFoundError`:** a taxonomia atual
  (`lib/harness/errors.rb`) não carrega um atributo estruturado (`kind:`/
  `resource:`) em `NotFoundError` — só uma `message` livre. Estruturar isso
  direito (ex.: `NotFoundError.new(resource: :task, id: ...)`) tocaria TODOS os
  `raise Harness::NotFoundError` espalhados pelo núcleo (`task_store.rb`,
  `session_store.rb`, `commands/*.rb`, `registry.rb`, `pending_action_store.rb`)
  — fora de escopo desta fatia (o adapter A2A não deve motivar mudança na
  taxonomia do núcleo). A heurística por `/task/i` na mensagem é suficiente
  porque toda mensagem de task hoje contém literalmente a palavra "task"
  (conferido nos 4 pontos de `raise` citados no Contexto); se um `raise
  Harness::NotFoundError` novo no núcleo não seguir essa convenção de
  mensagem, ele vai cair silenciosamente em `INVALID_PARAMS` em vez de
  `TASK_NOT_FOUND` — um risco aceito, documentado aqui para quem for adicionar
  um novo `raise` de task no futuro (mantenha "task" na mensagem).
- **`TASK_NOT_CANCELABLE` é só a constante nesta task** — nenhum `raise` do
  núcleo a alimenta via `from_exception` hoje. O handler `tasks/cancel` (Task
  5) é quem vai decidir, ao ler o estado da Task ANTES de despachar
  `cancel_task`, se deve responder com esse código diretamente (chamando
  `Protocol.error(id, Errors::TASK_NOT_CANCELABLE, ...)` sem passar por
  `from_exception`) — não implementar esse fluxo aqui.
- **Ordem dos dois arquivos importa para o `require_relative`:**
  `protocol.rb` requer `errors.rb` (usa `Errors::INVALID_REQUEST`/
  `Errors::INTERNAL_ERROR` no `parse`) — crie `errors.rb` primeiro (Passo 1/2)
  para que o `require_relative "errors"` do Passo 3 resolva ao rodar os specs
  isoladamente.
- **Nada em `lib/harness.rb`/`config/wiring.rb` muda neste task** — os dois
  arquivos ficam sem consumidor até a Task 5 (`A2A::App`, que os
  `require_relative`) e a Task 6/7 (rota + wiring opt-in no `Server::App`).
  Rodar `spec/harness/server/a2a/*_spec.rb` isoladamente já valida 100% do
  comportamento deste task, sem precisar do restante da fatia.
