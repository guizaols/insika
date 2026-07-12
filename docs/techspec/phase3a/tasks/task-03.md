# Task 03 (P3A): `A2A::TaskProjection` (Task → A2A Task)

> **Techspec:** [P3A-01-a2a-protocol-and-projection.md](../P3A-01-a2a-protocol-and-projection.md) (§TaskProjection, D2/D3, L4-L6) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Criar `Harness::Server::A2A::TaskProjection`, a tradução PURA (sem HTTP, sem
stores, sem RubyLLM) de uma `TaskStore::Task` do núcleo para o shape **A2A
Task** (JSON-RPC). É o mapeamento de estado (D2) + a decisão de onde o
conteúdo final entra (D3) — a peça que a task 5 (`Server::A2A::App#rpc`) chama
tanto na resposta síncrona de `message/send` (Task recém-criada, `submitted`)
quanto em `tasks/get` (Task em qualquer estado, inclusive terminal).

Como as demais peças da Etapa A (Protocol, Errors, Message), esta é
função-pura testável isolada: recebe um objeto com `id`/`status`/`session_id`
e devolve um Hash. Não lê store, não teece hora (o `at:` vem injetado — L6).

## Dependências

| # | Task | Por quê |
|---|------|---------|
| 2 | `A2A::Message` (`server/a2a/message.rb`) | `TaskProjection` chama `Message.agent_message(text)` para montar `status.message` em `completed`/`failed` (D3, L5) |

Não depende de `A2A::Protocol`/`A2A::Errors` (task 1) nem de `A2A::AgentCard`
(task 4) — só de `Message.agent_message`. Pode nascer em paralelo à task 1 e à
task 4; só espera a task 2 (ou nasce em paralelo e resolve o `require` depois,
já que `server/a2a/` é um diretório novo compartilhado só por criação de
arquivo, não por edição concorrente do mesmo arquivo).

## Contexto

A P3A-01 (D2) fixa o mapa de estado Task→TaskState A2A — cada status do
núcleo (`lib/harness/task_store.rb`, `STATUSES`) casa com um estado A2A, com
uma decisão deliberada em `paused`: mapeia para `"working"` (suspensão de
*operador* ≠ `input-required`, que é INPUT_REQUIRED do *usuário* — RFC-0002
§9 já fixa `waiting` como a referência de INPUT_REQUIRED; `paused` é outra
coisa e não pode ser confundido com ela no wire A2A).

A D3 fixa duas outras decisões que este módulo materializa:

1. **`contextId` = `session_id`.** O A2A agrupa mensagens de uma conversa sob
   `contextId`; nosso equivalente é a sessão. `task.session_id` pode ser
   `nil` (task criada sem sessão, ex. legado `/agent/messages`) — o módulo
   NÃO inventa nada aqui, só repassa `nil` (edge case abaixo).
2. **Conteúdo final vira `status.message`.** Quando a Task chega a
   `completed`, o `content` (texto final do turno, ex. do evento
   `:task_completed` — quem lê o Execution/checkpoint e extrai isso é a task
   5, fora de escopo aqui) entra como `status.message` via
   `Message.agent_message(content)`. Quando `failed`, é o `error` (mensagem
   de erro, string) que entra da mesma forma. Estados não-terminais
   (`submitted`/`working`/`input-required`) não carregam `status.message`
   nesta fatia — a P3A-01 (L5) deixa em aberto uma mensagem opcional de
   pendência de aprovação em `input-required`, mas explicitamente permite
   ficar `nil` agora (evolução).

A `L6` isola este módulo do relógio: `timestamp` NUNCA é `Time.now` chamado
aqui dentro — vem sempre como o argumento `at:`, obrigatório (sem default).
Quem decide a hora real é o caller (a task 5 passa
`Time.now.utc.iso8601`, mesmo formato que `TaskStore#timestamp` já usa); os
testes deste módulo passam uma string fixa, tornando `call` 100%
determinístico e comparável por igualdade de Hash.

`artifacts`/`history` ficam sempre `[]` nesta fatia (D3: conteúdo rico vai
todo em `status.message`; artifacts incrementais são evolução, fora de
escopo — não implementar nada além do array vazio).

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| CREATE | `server/a2a/task_projection.rb` | `Harness::Server::A2A::TaskProjection` — `STATE` + `.call` |
| CREATE | `spec/harness/server/a2a/task_projection_spec.rb` | contrato do módulo (Structs fake de Task) |

Nenhum outro arquivo é tocado — `server/a2a/` é diretório novo e exclusivo
desta fatia (D6 do overview); se as tasks 1/2/4 já o criaram em paralelo, só
adicionar o arquivo novo dentro dele.

## Passo a passo

### Passo 1 — `STATE` (mapa de estado, D2)

Constante congelada, símbolo do núcleo → string do wire A2A, exatamente como
o `P3A-01` fixa:

```ruby
STATE = {
  queued: "submitted",
  running: "working",
  waiting: "input-required",
  paused: "working", # suspensão de operador != input do usuário (D2)
  completed: "completed",
  failed: "failed",
  cancelled: "canceled" # A2A usa grafia US (1 "l")
}.freeze
```

**Padrão de referência (codebase, `lib/harness/task_store.rb:22`):**
```ruby
STATUSES = %i[queued running waiting paused completed failed cancelled].freeze
```

`STATE` é deliberadamente um Hash separado de `STATUSES` — não reaproveitar
`STATUSES` para iterar/validar aqui: `TaskProjection` não valida o status de
entrada contra o enum do núcleo (isso é papel do `TaskStore#transition`); ele
só faz um lookup e cai em `"unknown"` se não achar (L bônus, comportamento
defensivo do template — cobre tanto uma Task real com status inesperado
quanto um double de teste deliberadamente malformado).

### Passo 2 — `.call(task, content: nil, error: nil, at:)`

```ruby
require_relative "message"

module Harness
  module Server
    module A2A
      module TaskProjection
        STATE = { ... }.freeze # Passo 1

        # task: qualquer objeto que responda a #id/#status/#session_id (na
        # prática, TaskStore::Task). content/error: String|nil (conteúdo final
        # ou mensagem de erro). at: String (timestamp já formatado, L6 —
        # OBRIGATÓRIO, sem default: o caller decide a hora, este módulo não).
        # -> Hash (A2A Task).
        def self.call(task, content: nil, error: nil, at:)
          status = { state: STATE.fetch(task.status, "unknown") }
          message = status_message(task.status, content: content, error: error)
          status[:message] = message if message

          {
            id: task.id,
            contextId: task.session_id,
            kind: "task",
            status: status.merge(timestamp: at),
            artifacts: [],
            history: []
          }
        end

        # -> Hash (A2A Message) | nil. Só completed/failed carregam
        # status.message nesta fatia (D3/L5); os demais estados devolvem nil
        # (chave `message` fica ausente do Hash, não `nil` explícito — D
        # "message?" no shape do template é opcional, não nullable).
        def self.status_message(status, content:, error:)
          case status
          when :completed then Message.agent_message(content)
          when :failed then Message.agent_message(error)
          end
        end
        private_class_method :status_message
      end
    end
  end
end
```

**Padrão de referência (codebase, `lib/harness/task_store.rb:191-204`,
shape do objeto Task que este módulo consome):**
```ruby
Task = Data.define(:id, :status, :command, :session_id, :executions,
                    :mailbox_state, :claimed_by, :claim_expires_at,
                    :created_at, :updated_at)
# status: já normalizado p/ Symbol na leitura (to_task) — comparável direto
# contra STATE.keys sem to_sym extra aqui.
```

`TaskProjection` só lê 3 campos (`id`, `status`, `session_id`) de um objeto
potencialmente muito maior — não duck-type mais que isso, não tentar ler
`executions`/`command`/etc. aqui (fora de escopo; conteúdo final não vem da
Task, vem do `content:` que o CALLER extrai em outro lugar, ver Contexto).

**Padrão de referência (`server/a2a/message.rb`, task 2, P3A-01 linhas
73-76 — a peça que este módulo consome):**
```ruby
module Harness::Server::A2A::Message
  def self.agent_message(text) # -> { role: "agent", parts: [{ kind: "text", text: }] }
end
```

### Passo 3 — ordem das chaves do Hash de status

`status.merge(timestamp: at)` (em vez de literal com `timestamp:` no meio)
garante a ordem `state` → `message?` → `timestamp` estável nos testes de
igualdade de Hash (Ruby preserva ordem de inserção; `Hash#==` não depende de
ordem, mas manter a ordem do template ajuda debug/inspect e evita depender
disso silenciosamente em specs futuras que façam snapshot/`to_json`).

## Edge cases

- **Estado desconhecido → `"unknown"`.** Task/double com `status: :bogus`
  (fora de `STATE.keys`) → `STATE.fetch(:bogus, "unknown")` devolve
  `"unknown"`, nunca levanta `KeyError`. Cobre tanto uma migração futura do
  núcleo que adicione um status novo antes deste mapa ser atualizado, quanto
  um teste que force o caminho defensivo.
- **`completed` traz `status.message` com o `content`.** `content: "receita
  pronta"` + `status: :completed` → `status.message ==
  Message.agent_message("receita pronta")`. Se `content` vier `nil` num
  `completed` (bug do caller — task nunca deveria completar sem conteúdo),
  `Message.agent_message(nil)` propaga o comportamento que a task 2 definir
  para texto `nil`; `TaskProjection` não faz guard adicional aqui (não é
  seu papel validar o caller).
- **`failed` traz `status.message` com o `error`**, mesma mecânica, trocando
  `content` por `error`. Se ambos vierem preenchidos num `failed` (chamada
  incorreta do caller passando os dois), `error` vence — o `case` só olha
  `status`, nunca os dois parâmetros ao mesmo tempo.
- **Estado não-terminal sem `message`.** `queued`/`running`/`waiting` →
  `status_message` cai no `else` implícito do `case` (sem `when`) e devolve
  `nil` → a chave `:message` fica **ausente** do Hash `status` (não
  `status[:message] = nil`) — importante para quem comparar contra um Hash
  literal `{ state: "submitted", timestamp: "..." }` sem a chave `message`.
- **`contextId` nil (task sem sessão).** `task.session_id` nil (ex.: task do
  legado `/agent/messages`, que não persiste sessão) → `contextId: nil` no
  Hash de saída, sem levantar nem substituir por string vazia — o
  `TaskProjection` não decide política de sessão, só repassa o dado.
- **`at:` sem default, obrigatório.** Chamar `.call(task, at: nil)` é
  permitido pela assinatura (não há validação de not-nil) — mas
  `.call(task)` sem `at:` levanta `ArgumentError` do próprio Ruby (kwarg
  obrigatório), o que é o comportamento desejado: força todo caller a decidir
  explicitamente a hora (L6), nunca cair num `Time.now` implícito.
- **`paused` → `"working"`, não confundir com `waiting`.** Teste dedicado
  (ver tabela) para não deixar essa decisão de D2 regredir silenciosamente
  (ex. alguém "corrigindo" para `"input-required"` por engano, achando que
  toda suspensão é input do usuário).

## Testes

**Arquivo:** `spec/harness/server/a2a/task_projection_spec.rb`

Fake Task (Struct mínimo — só os 3 campos que `TaskProjection` lê; não
precisa do `Data.define` completo de `TaskStore::Task`, mesmo espírito dos
outros doubles de `spec/harness/server/*_spec.rb`, ex. `AdminStore =
Struct.new(:records)` em `admin_app_spec.rb`):

```ruby
FakeTask = Struct.new(:id, :status, :session_id)
```

| # | Cenário | Asserção |
|---|---|---|
| 1 | cada status de `STATE` (`queued`/`running`/`waiting`/`paused`/`completed`/`failed`/`cancelled`) via `FakeTask` | `.call(task, at: "t").dig(:status, :state)` == valor esperado da tabela D2 |
| 2 | `status: :paused` | `state == "working"` (não `"input-required"`) — não confundir com `:waiting` |
| 3 | `status: :bogus` (fora do mapa) | `state == "unknown"` |
| 4 | `status: :completed, content: "receita pronta"` | `status[:message] == Message.agent_message("receita pronta")` |
| 5 | `status: :failed, error: "timeout no llm"` | `status[:message] == Message.agent_message("timeout no llm")` |
| 6 | `status: :queued` (não-terminal), sem `content:`/`error:` | `status.key?(:message)` é `false` (chave ausente, não `nil`) |
| 7 | `FakeTask.new("t-1", :running, "sess-9")` | `id == "t-1"`; `contextId == "sess-9"`; `kind == "task"` |
| 8 | `session_id: nil` | `contextId == nil` (sem levantar, sem string vazia) |
| 9 | `at: "2026-01-01T00:00:00Z"` | `status[:timestamp] == "2026-01-01T00:00:00Z"` (nenhuma chamada a `Time.now` — sem stub de relógio, prova que é 100% injetado) |
| 10 | qualquer chamada | `artifacts == []`; `history == []` |
| 11 | `.call(task)` sem `at:` | levanta `ArgumentError` (kwarg obrigatório) |

## Definition of Done

- [ ] `Harness::Server::A2A::TaskProjection` criado em
      `server/a2a/task_projection.rb`, com `STATE` (mapa D2) e `.call`
      seguindo a assinatura `(task, content: nil, error: nil, at:)`
- [ ] `require_relative "message"` no topo do arquivo (dependência da task 2)
- [ ] `spec/harness/server/a2a/task_projection_spec.rb` cobrindo a tabela de
      testes acima
- [ ] Suíte verde sem chave de API (módulo 100% puro, sem I/O)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Este módulo **não é requerido** em `lib/harness.rb` (composition root do
  NÚCLEO) — `server/a2a/*` é requerido pelo wiring do servidor (task 7),
  igual `server/admin/app.rb` hoje não é requerido por `lib/harness.rb`, só
  por `server/app.rb`. Não adicionar require cruzado aqui.
- Este módulo não decide QUEM chama `.call` com qual `content`/`error` — essa
  extração (ex. ler o Execution/checkpoint terminal para achar o texto
  final) é uma lacuna explícita deixada para a task 5 (ver `tasks.md`,
  "Concerns": *"Conteúdo terminal em tasks/get… pode exigir ler o
  Execution/checkpoint terminal; edge a resolver na task 5"*). Aqui o
  contrato é só: se te derem `content`/`error`, eu boto no lugar certo.
- Não usar `TaskStore::STATUSES` como fonte de verdade de `STATE.keys` (nem
  validar que batem 1:1) — são dois vocabulários deliberadamente
  desacoplados (núcleo vs. wire A2A); um teste de paridade entre os dois
  enums é tentador mas fora de escopo desta task (e amarraria este módulo
  puro a um require de `TaskStore` que ele não precisa).
