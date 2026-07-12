# Task 05 (P3A): `Server::A2A::App` (handler JSON-RPC)

> **Techspec:** [P3A-02-agent-card-and-wiring.md](../P3A-02-agent-card-and-wiring.md) (§`Server::A2A::App`, §Fluxo do `rpc`, D1/D2/D4, L3-L5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** High · **Etapa:** A

## Objetivo

Escrever `server/a2a/app.rb` (`Harness::Server::A2A::App`): o handler A2A de
borda que COMPÕE os quatro módulos puros da Etapa A (`Protocol`/`Errors` —
task 1, `Message` — task 2, `TaskProjection` — task 3, `AgentCard` — task 4)
com o `command_bus`/`task_store`/`session_store` reais. É o ÚNICO ponto de
P3A que toca stores/bus — tudo o mais (tasks 1-4) é puro, sem IO. O `App`
recebe tudo por injeção (mesmo padrão do `Admin::App`, doc 07), nunca
instancia dependência própria, e o método público `rpc(body)` **nunca
levanta** — qualquer falha vira um error object JSON-RPC (D4).

## Dependências

| Task | Componente | Motivo |
|---|---|---|
| Task 01 | `A2A::Protocol` + `A2A::Errors` | `Protocol.parse`/`Protocol.result`/`Protocol.error` montam o envelope; `Errors.from_exception` traduz qualquer exceção do núcleo para `[code, message]` no `rescue` de topo do `rpc` (D4). |
| Task 02 | `A2A::Message` | `Message.text_from(params["message"])` extrai o texto do `message/send` recebido; `Message.agent_message` é usado indiretamente pela `TaskProjection` para montar `status.message`. |
| Task 03 | `A2A::TaskProjection` | `TaskProjection.call(task, content:, error:, at:)` projeta a `Task` do núcleo para o Hash A2A devolvido em todo caminho de sucesso do `rpc`. |
| Task 04 | `A2A::AgentCard` | `AgentCard.build(agent:, base_url:, skills:)` é chamado por `#agent_card`. |

Sem as quatro, `App` não tem o que compor — é estritamente depois delas
(Dependency Graph do `tasks.md`, Etapa A). Não depende das tasks 6/7 (rotas no
`Server::App`/wiring): o `App` é testado isoladamente, sem HTTP (o brief e o
P3A-02 são explícitos: "sem HTTP" nos testes desta task).

## Contexto

### Sub-app injetado, espelha `Admin::App`

`server/admin/app.rb` já estabelece o padrão que este `App` replica: um
construtor com kwargs nomeados para cada dependência (bus, stores, catálogos),
sem singletons, sem `require` de infraestrutura própria — quem monta é o
composition root (`config/wiring.rb`, task 7). Diferença de forma (não de
princípio): o `Admin::App` tem `#call(req)` porque fala Rack/HTML; o `A2A::App`
tem `#rpc(body)`/`#agent_card` porque fala JSON-RPC puro — quem faz a ponte com
Rack é o `Server::App` (task 6), que passa o `body` já desserializado e
devolve o Hash de volta como JSON.

### A2A é transporte, não lógica de negócio (D1)

RFC-0002 §1: o `A2A::App` TRADUZ (JSON-RPC → `Command`, `Task` → A2A Task) e
nunca decide nada por conta própria. Toda mutação passa pelo `command_bus` —
o `App` nunca escreve em `task_store`/`session_store` diretamente (só lê, para
`tasks/get` e para montar o `content` terminal). Mesmo `command_bus` que os
outros transportes (`transport:` no `Command.build` é `:a2a`, análogo a
`:admin`/`:http`) — nenhum código de domínio é duplicado ou bypassado aqui.

### `message/send` devolve a Task, não bloqueia (D2)

O dispatch de `:send_message` é assíncrono (mesmo modelo do `Admin::App#act`):
o handler no bus enfileira o turno e devolve `{ task_id: }` na hora. O `rpc`
busca essa `Task` recém-criada (`@task_store.find(result[:task_id])`) e projeta
o estado CORRENTE (tipicamente `submitted`/`working` — a `Task` acabou de ser
criada, ainda não terminou). O cliente A2A é quem faz polling via `tasks/get`
até um estado terminal. Não existe streaming nem espera síncrona nesta fatia.

### L4 — conteúdo terminal em `tasks/get`, a decisão resolvida do techspec

Este é o ponto mais delicado da task. A `Task` (`lib/harness/task_store.rb`)
NÃO carrega o texto final da resposta do assistente em nenhum campo seu — ela
só tem `status`/`executions`/`session_id`. O conteúdo de verdade foi
persistido pelo `persist_turn` do Executor no **transcript da sessão**
(`session_store.append_messages` grava `{"role"=>"assistant", "content"=>...}`).
Por isso:

- `terminal_content(task)` = a última mensagem com `"role" == "assistant"` do
  array `session_store.find(task.session_id).messages` — `nil` se a sessão não
  existe ou não tem mensagem assistant (edge case).
- `terminal_error(task)` = o `error["message"]` (ou `error` inteiro, ver Passo 4)
  da última `Execution` de `task.executions` cujo `outcome == "failed"` — só
  quando `task.status == :failed`.
- É EXATAMENTE por isso que `message/send` **sempre** garante uma sessão (cria
  via `:create_session` quando `contextId` ausente, ver Passo 2): sem sessão
  não há transcript de onde `tasks/get` ler o `content` terminal depois.

### D4 — o `App` nunca deixa vazar exceção

Todo o corpo de `rpc` (o `case method` inteiro, incluindo os dispatches ao
bus e as leituras de store) fica dentro de um `begin/rescue StandardError`
único. Qualquer exceção — `ValidationError`/`NotFoundError` do núcleo, ou algo
totalmente inesperado (`StoreError`, `NoMethodError` de um bug) — vira
`Errors.from_exception(e)` → `Protocol.error(id, code, msg)`. O chamador
(`Server::App`, task 6) sempre recebe um Hash de envelope, nunca uma exceção
subindo — coerente com "HTTP 200 sempre" do techspec (o erro trafega no
corpo JSON-RPC, não no status).

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `server/a2a/app.rb` | CREATE | `Harness::Server::A2A::App` — `#initialize`, `#rpc`, `#agent_card` + helpers privados |
| `spec/harness/server/a2a/app_spec.rb` | CREATE | specs com bus/stores reais (ou fakes mínimos) — sem HTTP; cobre os 3 métodos JSON-RPC + `agent_card` + mapeamento de erro |

## Passo a passo

### Passo 1 — esqueleto e injeção de dependências

**Padrão de referência (codebase) — construtor do `Admin::App`**
(`server/admin/app.rb:37-47`, o MESMO estilo de injeção — kwargs nomeados,
zero lógica no construtor, `attr` de instância só):

```ruby
def initialize(command_bus:, session_store:, task_store:, checkpoint_store:,
               pending_action_store:, catalogs:, registries:, event_stream:)
  @command_bus = command_bus
  @session_store = session_store
  @task_store = task_store
  @checkpoint_store = checkpoint_store
  @pending_action_store = pending_action_store
  @catalogs = catalogs
  @registries = registries
  @event_stream = event_stream
end
```

`A2A::App` replica a forma, com a lista de dependências do brief/techspec:

```ruby
# server/a2a/app.rb
# frozen_string_literal: true

require "time"
require_relative "protocol"
require_relative "errors"
require_relative "message"
require_relative "task_projection"
require_relative "agent_card"

module Harness
  module Server
    module A2A
      # Handler JSON-RPC de borda do A2A (RFC-0002 §1, P3A-02). Único ponto de
      # P3A que toca command_bus/stores — traduz, nunca decide (D1). Espelha o
      # Admin::App na forma da injeção (server/admin/app.rb); difere na
      # superfície pública porque fala JSON-RPC puro, não Rack (a ponte HTTP é
      # do Server::App, task 6).
      class App
        def initialize(command_bus:, task_store:, session_store:, profiles:,
                       skill_catalog:, config:)
          @command_bus = command_bus
          @task_store = task_store
          @session_store = session_store
          @profiles = profiles
          @skill_catalog = skill_catalog
          @config = config # { a2a_agent:, base_url:, ... }
        end
      end
    end
  end
end
```

### Passo 2 — `rpc(body)`: parse + roteamento + rescue de topo

**Padrão de referência (codebase) — o fluxo já desenhado no techspec**
(P3A-02-agent-card-and-wiring.md §"Fluxo do `rpc`"), implementado literalmente:

```ruby
def rpc(body)
  outcome, payload = Protocol.parse(body)
  return Protocol.error(payload[:id], payload[:code], payload[:message]) if outcome == :error

  id, method, params = payload.values_at(:id, :method, :params)
  case method
  when "message/send"  then handle_message_send(id, params)
  when "tasks/get"      then handle_tasks_get(id, params)
  when "tasks/cancel"   then handle_tasks_cancel(id, params)
  else
    Protocol.error(id, Errors::METHOD_NOT_FOUND, "método '#{method}' não suportado")
  end
rescue StandardError => e
  code, message = Errors.from_exception(e)
  Protocol.error(id, code, message)
end
```

Note que `id` precisa estar disponível no escopo do `rescue` — se
`Protocol.parse` já falhar antes de extrair `id`, ele vem do `payload[:id]`
do próprio erro de parse (a task 1 garante que `[:error, {id:, code:, message:}]`
sempre carrega o `id` — `null` quando nem isso deu para extrair do body cru).
Ajustar a extração de `id` para funcionar em AMBOS os ramos (padrão local:
extrair `id = body.is_a?(Hash) ? body["id"] : nil` antes do `Protocol.parse`,
como uma segunda fonte para o `rescue`, já que uma exceção pode ocorrer depois
do `case` ter avançado mas antes de qualquer `id` local ficar setado — usar
`id ||= (body["id"] rescue nil)` no `rescue` é a forma mais simples de nunca
deixar o `rescue` estourar por `id` indefinido).

### Passo 3 — `message/send`: cria sessão se preciso, dispatcha, projeta

```ruby
def handle_message_send(id, params)
  message = params["message"] || {}
  session_id = message["contextId"] || params["contextId"]
  session_id ||= @command_bus.dispatch(Command.build(:create_session, {}, transport: :a2a)).id

  text = Message.text_from(message)
  cmd = Command.build(:send_message,
                       { agent: @config[:a2a_agent], message: text, session_id: session_id },
                       transport: :a2a)
  result = @command_bus.dispatch(cmd)
  task = @task_store.find(result[:task_id])
  Protocol.result(id, TaskProjection.call(task, at: now))
end
```

**Padrão de referência (codebase) — `Command.build`** (`lib/harness/command.rb:21-32`):
`Command.build(type, payload = {}, transport: :internal, tenant: nil)` — aqui
sempre `transport: :a2a` (paridade com `:admin` no `Admin::App#act`, análogo
ao audit trail que a Fase 2 já estabeleceu para outros transportes). O
resultado de `dispatch(:create_session, ...)` — confirmar contra o handler
real de `:create_session` registrado no bus (`config/wiring.rb`): se ele
devolver a `Session` (com `.id`) em vez de um Hash `{session_id:}`, ajustar a
extração aqui (`.id` vs `[:session_id]`) — sinalizar como Nota se o shape
divergir do assumido.

### Passo 4 — `tasks/get`: leitura direta + conteúdo/erro terminal (L4)

**Padrão de referência (codebase) — `SessionStore#find` e o shape do transcript**
(`lib/harness/session_store.rb:53-56,111-120`): `find(id)` devolve `Session|nil`
com `.messages` (Array de Hash de chaves STRING — `"role"`/`"content"`/`"at"`,
nunca symbolizado de volta, doc 02 §1). E `TaskStore::Task#executions`
(`lib/harness/task_store.rb:38,206-214`): Array de `Execution` (`Data.define`)
com `.outcome` (String, ex. `"failed"`) e `.error` (Hash de chaves string).

```ruby
def handle_tasks_get(id, params)
  task = @task_store.find(params["id"])
  raise Harness::NotFoundError, "task inexistente: #{params["id"]}" if task.nil?

  content = terminal_content(task)
  error = terminal_error(task)
  Protocol.result(id, TaskProjection.call(task, content: content, error: error, at: now))
end

private

# Última mensagem assistant do transcript da sessão (L4) — nil se não houver
# sessão ou nenhuma mensagem assistant ainda (task não terminou, ou terminou
# sem gerar resposta visível).
def terminal_content(task)
  return nil if task.session_id.nil?

  session = @session_store.find(task.session_id)
  return nil if session.nil?

  session.messages.reverse.find { |m| m["role"] == "assistant" }&.fetch("content", nil)
end

# error["message"] da última Execution :failed — nil se a task não falhou ou
# não há Execution com outcome failed registrada (edge case defensivo).
def terminal_error(task)
  return nil unless task.status == :failed

  failed = task.executions.reverse.find { |e| e.outcome == "failed" }
  failed&.error&.fetch("message", nil) || failed&.error
end
```

`@task_store.find` (`lib/harness/task_store.rb:69-72`) devolve `nil` para id
inexistente (NÃO levanta) — por isso o `raise Harness::NotFoundError` explícito
aqui, capturado pelo `rescue` de topo do `rpc` e mapeado por
`Errors.from_exception` para `TASK_NOT_FOUND` (-32001, task 1).

### Passo 5 — `tasks/cancel`

```ruby
def handle_tasks_cancel(id, params)
  @command_bus.dispatch(Command.build(:cancel_task, { task_id: params["id"] }, transport: :a2a))
  task = @task_store.find(params["id"])
  raise Harness::NotFoundError, "task inexistente: #{params["id"]}" if task.nil?

  Protocol.result(id, TaskProjection.call(task, at: now))
end
```

Cancelar uma task já terminal (idempotência) é responsabilidade do HANDLER de
`:cancel_task` no bus (fora do escopo desta task — a máquina de estados do
`TaskStore#transition`, `lib/harness/task_store.rb:78-93`, já trata terminais
como sem transições válidas de saída); o `App` só propaga o que o handler
decidir (se o handler levantar por transição inválida, o `rescue` de topo cobre).

### Passo 6 — `agent_card`

```ruby
def agent_card
  agent = @profiles[@config[:a2a_agent]]
  AgentCard.build(
    agent: agent,
    base_url: @config[:base_url],
    skills: @skill_catalog.effective(agent.skills)
  )
end
```

**Padrão de referência (codebase) — `SkillCatalog#effective`**
(`lib/harness/skill_catalog.rb:34-40`): `nil` → todas as skills, `[]` →
nenhuma, `[names]` → subconjunto — mesma semântica de allowlist usada em todo
o resto do sistema (doc 06). `agent.skills` vem do `AgentProfile`
(`lib/harness/agent_profile.rb:17`).

### Passo 7 — `now` (timestamp injetável, L6 da task 3)

```ruby
def now
  Time.now.utc.iso8601
end
```

`TaskProjection.call` recebe `at:` já pronto (task 3, L6) — o `App` é quem
decide QUANDO chamar `Time.now` (facilita fixar nos specos desta task; a task
3 já testa a projeção com `at:` fixo, isolado do relógio).

## Edge cases

- **`contextId` ausente em `message/send`:** cria sessão nova via
  `:create_session` ANTES do `:send_message` — garante que `tasks/get` sempre
  tem transcript de onde ler o `content` terminal (L4). Sem isso, uma task de
  `message/send` sem sessão jamais teria `content` em `tasks/get`.
- **`tasks/get`/`tasks/cancel` com `id` de task inexistente:** `@task_store.find`
  devolve `nil` (não levanta) → o `App` levanta `Harness::NotFoundError`
  explicitamente → `rescue` de topo → `Errors.from_exception` → `-32001`
  (`TASK_NOT_FOUND`, task 1).
- **Método JSON-RPC desconhecido:** nunca chega ao `rescue` — tratado no
  próprio `case` com `Protocol.error(id, METHOD_NOT_FOUND, ...)` (-32601), sem
  levantar exceção.
- **Qualquer exceção interna** (bug, `StoreError`, handler não registrado no
  bus — `CommandBus#dispatch` levanta `ValidationError` para tipo desconhecido,
  `lib/harness/command_bus.rb:28-33`): capturada pelo `rescue StandardError`
  único do `rpc`; NUNCA vaza — sempre volta um envelope de erro (D4).
- **Task `completed`:** `terminal_content` traz a última mensagem assistant;
  `TaskProjection.call` (task 3, L5) só usa `content` quando o estado
  projetado é `completed`.
- **Task `failed`:** `terminal_error` traz a mensagem de erro da última
  `Execution` fechada com `outcome: "failed"`; se por algum motivo não houver
  nenhuma (edge case defensivo — não deveria acontecer dado o invariante do
  `TaskStore`), `terminal_error` devolve `nil` e `TaskProjection` simplesmente
  não popula `status.message`.
- **Cancelamento de task já terminal (idempotência):** delegado ao handler de
  `:cancel_task` no bus — o `App` não decide isso; só repassa o resultado (ou
  a exceção, via `rescue`) do dispatch.
- **`session_store.find(task.session_id)` devolve `nil`** (sessão apagada ou
  `session_id` nil): `terminal_content` devolve `nil` sem levantar — `tasks/get`
  ainda projeta a `Task` normalmente, só sem `content`.

## Testes

**Arquivo:** `spec/harness/server/a2a/app_spec.rb`

Sem HTTP — usar `CommandBus`/`TaskStore`/`SessionStore` reais sobre um
`Harness::Store::Memory` (ou fakes mínimos equivalentes), com handlers de
`:create_session`/`:send_message`/`:cancel_task` registrados no bus (reais ou
doubles que criam a `Task`/`Session` esperada — o que já existe em specs
similares da Fase 2, ex. `spec/harness/server/admin/app_spec.rb`, se houver
um padrão pronto para reaproveitar).

| Cenário | Expectativa |
|---|---|
| `message/send` sem `contextId` | dispatcha `:create_session` (transport `:a2a`) ANTES de `:send_message`; `:send_message` recebe `session_id` da sessão recém-criada, `agent: config[:a2a_agent]`, `message:` = texto extraído via `Message.text_from`; retorno é `Protocol.result` com a `Task` projetada |
| `message/send` com `contextId` presente | NÃO dispatcha `:create_session`; `:send_message` usa o `session_id` recebido |
| `tasks/get` de task existente, estado não-terminal | `Protocol.result` com `TaskProjection.call` sem `content`/`error` |
| `tasks/get` de task `completed` com mensagem assistant na sessão | `content` = a última mensagem assistant do transcript |
| `tasks/get` de task `failed` | `error` = a mensagem da última `Execution` `outcome: failed` |
| `tasks/get` de task inexistente | `Protocol.error` com `code == Errors::TASK_NOT_FOUND` (-32001) |
| `tasks/cancel` | dispatcha `:cancel_task` com `{task_id:}`; retorno é a `Task` reprojetada pós-cancelamento |
| método desconhecido (ex. `"tasks/list"`) | `Protocol.error` com `code == Errors::METHOD_NOT_FOUND` (-32601); NENHUM dispatch ao bus |
| exceção interna (ex. stub do `command_bus`/`task_store` levantando `RuntimeError`) | `rpc` NÃO propaga a exceção; devolve `Protocol.error` com `code == Errors::INTERNAL_ERROR` (-32603) |
| `agent_card` | `AgentCard.build` chamado com `agent: profiles[config[:a2a_agent]]`, `base_url: config[:base_url]`, `skills: skill_catalog.effective(agent.skills)`; shape do Hash retornado |

## Definition of Done

- [ ] `rpc` NUNCA levanta exceção — todo caminho (incluindo erro interno
      inesperado) devolve um Hash de envelope JSON-RPC (D4)
- [ ] `message/send` sem `contextId` cria sessão via `:create_session` antes
      de `:send_message`, garantindo transcript para `tasks/get` (L4)
- [ ] `tasks/get` lê `content`/`error` terminal do transcript da sessão /
      última `Execution failed`, nunca de um campo próprio da `Task`
- [ ] Task inexistente em `tasks/get`/`tasks/cancel` → `-32001`
      (`TASK_NOT_FOUND`), método desconhecido → `-32601` (`METHOD_NOT_FOUND`)
- [ ] `agent_card` compõe `AgentCard.build` com `profiles[config[:a2a_agent]]`
      e `skill_catalog.effective(agent.skills)`
- [ ] Nenhuma lógica de negócio duplicada — toda mutação passa por
      `@command_bus.dispatch` (D1), leitura direta só para `tasks/get`/`agent_card`
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Shape do retorno de `:create_session`/`:send_message` no bus real:** o
  Passo 3 assume `@command_bus.dispatch(Command.build(:create_session, ...)).id`
  (a `Session` inteira) e `result[:task_id]` para `:send_message` (um Hash) —
  confirmar contra os handlers REGISTRADOS de fato em `config/wiring.rb`
  (fora do escopo desta task, que só COMPÕE a interface já assumida pelo
  techspec/P2). Se o shape divergir, é um ajuste local nesta task, não uma
  reabertura de design — documentar no PR se aparecer.
- **Sem require de RubyLLM/infra pesada:** `server/a2a/app.rb` só depende dos
  quatro módulos puros (tasks 1-4) e de `time` da stdlib — nenhum
  `require "ruby_llm"` aqui (diferente de tools como `Tools::LoadSkill`), então
  entra tranquilamente na malha de `require`s do `Server::App`/boot sem
  disciplina de lazy-load especial.
- **Coordenação com task 6:** o `Server::App` (task 6) só precisa saber de
  `#rpc(body)` (Hash → Hash) e `#agent_card` (→ Hash) — nenhuma dependência
  reversa. `handle_a2a`/parse do JSON cru malformado (`-32700` antes de chegar
  aqui) é responsabilidade do `Server::App`, não desta task.
