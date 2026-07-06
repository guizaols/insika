# Task 10: `Executor` esqueleto — fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream`

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ⬜ TODO
> **Complexity:** High

---

## Objective

Criar a infraestrutura de execução assíncrona do Runtime: `EventStream` (pub/sub in-process com fila por subscriber), `TaskActor` (fiber Async + mailbox mínima `cancel`/`user_message`, drain em fronteiras) e o esqueleto do `Executor` (spawn, registro in-process `running?`, transições de estado via `TaskStore`, eventos com `meta`/`seq`) — sem nenhum conteúdo de pipeline ainda (estágios 2-8 chegam nas tasks 11-12).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 6 | `TaskStore` (máquina de estados validada, Executions, campos de claim reservados) | ⬜ TODO |
| 9 | `Command` + `CommandBus` + handlers de controle (`CreateSession`, `CancelTask`) | ⬜ TODO |

## Context

É a Fase 1 do modelo de Actor da RFC-0002 §9: **um fiber Async por Task**, mailbox mínima, cancelamento cooperativo (RFC-0001 princípio 7 / doc 03 L2). O Command de turno responde `{task_id:}` imediatamente e o resultado flui pelo Event Stream (RFC-0002 §7) — por isso `EventStream` nasce junto: sem ele não há como observar o fiber.

Esta task entrega o **entorno** dos estágios: spawn, lifecycle de estados (via `TaskStore`, que valida a máquina — doc 02 L1), drain de mailbox nas fronteiras, registro in-process de fibers vivos (`running?`, critério do `ResumeTask` no doc 03 §3) e o helper de emissão com `meta` D5 (`task_id`/`session_id`/`seq` monotônico/`at`). O miolo (`run_pipeline`) fica como stub: a task 11 traz os estágios 6-7 (RubyLLM) e a task 12 fecha 2-9.

Estados via `TaskStore` **sempre** — o Executor nunca escreve status direto no KV (doc 02 L1: "invariantes moram onde a escrita mora").

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/event_stream.rb` | pub/sub in-process; `Subscription` com `Async::Queue` própria; filtros por `meta` |
| CREATE | `lib/harness/task_actor.rb` | fiber + mailbox `Async::Queue`; `post`/`run`/`drain!`; `:user_message` reservado |
| CREATE | `lib/harness/executor.rb` | esqueleto: construtor completo, `spawn`, `execute`, `running?`, `cancel`, emissor com `seq` |
| MODIFY | `lib/harness.rb` | requires (zero side-effects; **não** requerer `ruby_llm`) |
| CREATE | `spec/harness/event_stream_spec.rb` | fan-out, filtros, isolamento de observador, fila por subscriber |
| CREATE | `spec/harness/task_actor_spec.rb` | mailbox, enum, drain, cancel |
| CREATE | `spec/harness/executor_spec.rb` | lifecycle, `running?`, cancel cooperativo, eventos/seq |

### Step-by-Step Instructions

#### Step 1: `EventStream`

**File:** `lib/harness/event_stream.rb`

Interface do doc 03 §2, decisões L4 e §5:

```ruby
# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Pub/sub in-process (RFC-0002 §7). O stream é concorrente ao turno: um
  # observador lento NUNCA atrasa a execução (L4) — cada assinante tem fila
  # própria; emit só enfileira.
  class EventStream
    class Subscription
      CLOSED = Object.new  # sentinela interna

      def initialize(task_id: nil, session_id: nil, on_close: nil)
        @queue = Async::Queue.new
        # ...
      end

      def matches?(event)
        meta = event.meta || {}
        (@task_id.nil?    || meta[:task_id]    == @task_id) &&
          (@session_id.nil? || meta[:session_id] == @session_id)
      end

      def push(event)  = @queue.enqueue(event)

      # Bloqueia o fiber do CONSUMIDOR (nunca o do emissor) até #close.
      def each
        while (event = @queue.dequeue) != CLOSED
          yield event
        end
      end

      def close
        @queue.enqueue(CLOSED)
        @on_close&.call(self)   # remove da lista do stream
      end
    end

    def initialize
      @subscriptions = []
    end

    # NUNCA levanta: exceção de um observador é isolada (doc 03 §2).
    def emit(event)
      @subscriptions.each do |sub|
        begin
          sub.push(event) if sub.matches?(event)
        rescue StandardError
          # observador quebrado não derruba o turno; nada a propagar
        end
      end
      nil
    end

    def subscribe(task_id: nil, session_id: nil)
      # cria Subscription, registra, retorna. nil/nil = todos os eventos.
    end
  end
end
```

Pontos obrigatórios:
- `emit` é síncrono e barato (iteração + enqueue) — doc 03 §5. Buffer ilimitado por subscriber é aceitável na Fase 1 (o cap de SSE é do doc 07, task 24).
- Sem mutex: um reactor, fibers cooperativos (doc 00 §5.5). `Array` simples basta.
- Filtro usa `event.meta` (D5) — eventos sem `task_id` no meta (ex.: `:session_created`) só chegam a subscribers sem filtro de task.

**Reference pattern from codebase** (o que o EventStream substitui — na Fase 0 os eventos fluíam por um lambda `emit` passado ao Runner, `reference-implementation/lib/agent_runtime/runner.rb`):
```ruby
def run(agent_id, message, history: [], &emit)
  emit ||= ->(_event) {}
  ...
  response = chat.ask(message) do |chunk|
    emit.call(Event.new(:content, { delta: chunk.content })) if chunk.content
  end
  emit.call(Event.new(:done, { content: response.content }))
```
Na Fase 1 o mesmo fluxo vira `event_stream.emit(...)` com meta de correlação — vários consumidores, mesmo canal (RFC-0007 §4).

#### Step 2: `TaskActor`

**File:** `lib/harness/task_actor.rb`

Interface do doc 03 §2:

```ruby
# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Fase 1 do Actor (RFC-0002 §9): fiber + mailbox mínima.
  class TaskActor
    MESSAGES = %i[cancel user_message].freeze
    # :user_message é RESERVADO na Fase 1: enum e consumo existem, mas nenhum
    # Command/rota o produz ainda (doc 03 §2). Mantido para o contrato não
    # mudar na Fase 2.

    attr_reader :task_id

    def initialize(task_id:, parent: Async::Task.current)
      @task_id = task_id
      @parent  = parent
      @mailbox = Async::Queue.new
      @pending_user_messages = []
    end

    # Não-bloqueante (doc 03 §5). Mensagem fora do enum é bug do chamador.
    def post(message, data = nil)
      raise ArgumentError, "mensagem desconhecida: #{message}" unless MESSAGES.include?(message)
      @mailbox.enqueue([message, data])
      nil
    end

    # Roda o bloco num fiber Async FILHO do parent (estrutura parent→children:
    # cancelar a task cancela a subárvore, doc 03 §5). Retorna o Async::Task.
    def run(&turn_block)
      @async_task = @parent.async { turn_block.call(self) }
    end

    # Drena a mailbox SEM bloquear. Chamado pelo Executor apenas nas
    # fronteiras de estágio/turno (cancelamento cooperativo, L2).
    #   :cancel       → raise Harness::CancelledError
    #   :user_message → acumula em pending_user_messages (consumo entre
    #                   turnos, doc 03 §4.1; sem produtor na Fase 1)
    def drain!
      until @mailbox.empty?
        message, data = @mailbox.dequeue
        case message
        when :cancel       then raise CancelledError, "task #{@task_id} cancelada"
        when :user_message then @pending_user_messages << data
        end
      end
      nil
    end

    attr_reader :pending_user_messages

    def wait = @async_task&.wait   # specs/boot aguardam término
  end
end
```

- `drain!` usa `empty?` + `dequeue` — nunca bloqueia (fila vazia = retorna).
- O `:cancel` **não** transiciona estado aqui: quem captura `CancelledError` e mapeia para `:cancelled` é o topo do fiber no Executor (L3).

#### Step 3: `Executor` esqueleto

**File:** `lib/harness/executor.rb`

Construtor completo do doc 03 §2 (colaboradores das etapas D/E entram como duplos/stubs até suas tasks chegarem):

```ruby
# frozen_string_literal: true

module Harness
  # Coordena. Não monta contexto, não decide policy, não fala com o provider
  # (doc 03 §1). Este arquivo NÃO requer ruby_llm em load-time (D9) — o
  # require é lazy dentro dos métodos de chat (task 11).
  class Executor
    def initialize(context_builder:, policy_engine:, middleware:, hooks:,
                   tool_registry:, skill_catalog:, profiles:,
                   session_store:, task_store:, checkpoint_store:,
                   event_stream:)
      # guardar tudo em ivars; @running = {} (task_id => TaskActor);
      # @seqs = Hash.new(0) (contador monotônico por task, D5)
    end

    # Registro in-process de fibers vivos (critério do ResumeTask, doc 03 §3).
    def running?(task_id) = @running.key?(task_id)

    # Ponto de acesso do CancelTask (task 9): posta :cancel se há fiber vivo.
    def cancel(task_id)
      actor = @running[task_id]
      actor&.post(:cancel)
      !actor.nil?
    end

    # Estágio 1 (parte assíncrona): cria o actor, registra e dispara o fiber.
    # Chamado pelos handlers de turno (SendMessage/ResumeTask/TriggerWorkflow).
    def spawn(task, profile:, resume_from: nil)
      actor = TaskActor.new(task_id: task.id)
      @running[task.id] = actor
      actor.run { execute(task, profile: profile, resume_from: resume_from, actor: actor) }
      task.id
    end

    # Estágios 2..9. Roda DENTRO do fiber da task (doc 03 §2).
    def execute(task, profile:, resume_from: nil, actor:)
      @task_store.begin_execution(task.id)
      @task_store.transition(task.id, to: :running) if @task_store.find(task.id).status == :queued
      emit(:task_started, { task_id: task.id, command: task.command[:type] || task.command["type"] }, task: task)

      actor.drain!
      run_pipeline(task, profile, actor, resume_from)   # stub nesta task

      # (caminho de sucesso completo — transition/persistência — chega na task 12)
    rescue CancelledError
      @task_store.transition(task.id, to: :cancelled)
      @task_store.finish_execution(task.id, outcome: :cancelled)
      emit(:task_cancelled, { task_id: task.id }, task: task)
    rescue StandardError => e
      # Esqueleto: rescue genérico para o fiber nunca vazar exceção.
      # O mapeamento COMPLETO erro→estado→eventos (D4/L3) chega na task 12.
      @task_store.transition(task.id, to: :failed,
                             error: { class: e.class.name, message: e.message })
      @task_store.finish_execution(task.id, outcome: :failed)
      emit(:task_failed, { task_id: task.id, error: e.class.name, message: e.message }, task: task)
    ensure
      @running.delete(task.id)
    end

    private

    # Preenchido nas tasks 11 (estágios 6-7) e 12 (2-9). Nos specs desta task
    # é stubado para simular sucesso/lentidão/erro.
    def run_pipeline(_task, _profile, _actor, _resume_from) = nil

    # Emissor único: constrói o Event com meta D5 e seq monotônico por task.
    def emit(type, data, task:)
      @event_stream.emit(Event.new(
        type: type, data: data,
        meta: { task_id: task.id, session_id: task.session_id,
                seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
      ))
    end
  end
end
```

Pontos obrigatórios:
- Ordem no início do fiber é a do doc 03 §4 estágio 1: `begin_execution` → `transition(:running)` → `:task_started`.
- `transition(:running)` só quando o status atual é `:queued` — no resume (task 13), tasks `running` órfãs não re-transicionam (`running→running` é inválido na máquina do doc 02 §2) e `paused/waiting→running` é feito pelo caminho de resume.
- `ensure` remove do registro **sempre** — `running?` falso-positivo quebraria o critério de órfã do `ResumeTask`.
- `@seqs` não é limpo ao fim da task: resume (nova Execution) continua a numeração — replay confiável (D5). Custo de memória irrelevante na Fase 1.

#### Step 4: requires

**File:** `lib/harness.rb`

```ruby
require_relative "harness/event_stream"
require_relative "harness/task_actor"
require_relative "harness/executor"
```

Confirmar que nenhum desses arquivos requer `ruby_llm` (D9 — o núcleo carrega sem a gem). A dependência `async` (~> 2.0, D9) passa a ser exigida em load-time por `event_stream`/`task_actor` — ela é do núcleo, ok.

### Edge Cases to Handle

1. `emit` para stream sem subscribers → no-op silencioso.
2. Subscriber cujo bloco `each` levanta → só o consumidor quebra; `emit` de outros eventos segue (o rescue do `emit` cobre o `push`, e o `each` roda no fiber do consumidor).
3. `subscribe(task_id: "t1")` criado **depois** de eventos já emitidos → não recebe retroativo (pub/sub ao vivo; replay é leitura de store, doc 07).
4. `close` duplo da Subscription → idempotente (segundo sentinela é inofensivo; documentar).
5. `post(:cancel)` antes de o fiber chegar ao primeiro `drain!` → cancel é visto na primeira fronteira (fila preserva).
6. `post` de mensagem fora do enum → `ArgumentError` imediato (bug do chamador, não do runtime).
7. Dois `spawn` para o mesmo `task_id` → sobrescreveria o registro; guardar: se `running?(task.id)`, `raise ValidationError, "task já em execução"` (mesma regra do resume, doc 03 §3).
8. Exceção dentro do próprio rescue (ex.: `transition` inválida) → deixar propagar para o log do reactor, mas o `ensure` ainda desregistra (fiber morre limpo o suficiente; refinado na task 12).

## Testing

Todos os specs rodam dentro de `Sync { ... }` (reactor Async de teste) e **sem `ruby_llm`**. Stores de domínio reais sobre `Stores::Memory`; `context_builder`/`policy_engine`/`middleware`/`hooks`/`tool_registry`/`skill_catalog` são duplos inertes (não usados pelo esqueleto).

### Unit Tests

**File:** `spec/harness/event_stream_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| fan-out | 2 subscriptions sem filtro, 1 emit | ambos recebem o evento |
| filtro task_id | subscribe(task_id: "a"); eventos meta a/b | só o de "a" chega |
| filtro session_id | idem por sessão | só o da sessão chega |
| evento sem task no meta | `:session_created` p/ subscriber com filtro de task | não chega; subscriber sem filtro recebe |
| each até close | consumidor em fiber; produtor emite 3 + close | itera exatamente 3 e retorna |
| observador quebrado | subscription cujo push levanta (duplo) | `emit` não levanta; demais recebem |
| consumidor lento | subscriber que nunca consome; 100 emits | `emit` retorna imediato (fila bufferiza — L4) |

**File:** `spec/harness/task_actor_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| enum | `post(:heartbeat)` | `ArgumentError` |
| cancel no drain | `post(:cancel)`; `drain!` | `Harness::CancelledError` |
| user_message reservado | `post(:user_message, "oi")`; `drain!` | sem exceção; `pending_user_messages == ["oi"]` |
| drain vazio | `drain!` sem posts | retorna sem bloquear |
| ordem | `post(:user_message, ...)` + `post(:cancel)` | drain acumula a mensagem E levanta o cancel |
| run roda no fiber | `run { marca }` + `wait` | bloco executou; retorno é `Async::Task` |

**File:** `spec/harness/executor_spec.rb` (stubando `run_pipeline` via `allow(executor).to receive(:run_pipeline)`)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| lifecycle feliz | pipeline stub retorna | Execution aberta (attempt 1), status passou por `:running`, `:task_started` emitido com `meta.seq == 1` |
| running? durante | pipeline stub que cede o fiber (ex.: espera uma `Async::Condition`) | `running?` true durante, false após |
| cancel cooperativo | pipeline stub chama `actor.drain!` após sinal; `executor.cancel(id)` antes | task `:cancelled`, Execution fechada `outcome: :cancelled`, `:task_cancelled` emitido |
| cancel sem fiber | `cancel("ghost")` | retorna false, nada emitido |
| erro genérico | pipeline stub levanta `RuntimeError` | task `:failed` com `error.class/message`, `:task_failed` emitido, fiber não vaza exceção |
| desregistro no ensure | pipeline levanta | `running?` false após |
| spawn duplicado | dois `spawn` da mesma task | `ValidationError` |
| seq monotônico | pipeline emite via helper 3x (stub chama `emit`) | `meta.seq` 1,2,3… crescente por task |
| CancelTask e2e de controle | handler da task 9 + executor real | `cancel` postado; task termina `:cancelled` |

### Integration Tests (if applicable)

Não nesta task (a integração Command→Response com chat mockado é a task 12).

## Definition of Done

- [ ] `EventStream` com fila por subscriber, filtros por `meta`, `emit` que nunca levanta (L4)
- [ ] `TaskActor` com enum `%i[cancel user_message]`, `post` não-bloqueante, `drain!` só em fronteiras, `:user_message` reservado
- [ ] `Executor#spawn/execute/running?/cancel` com estados **sempre** via `TaskStore` e eventos com `meta` D5 + `seq` monotônico
- [ ] Cancelamento cooperativo funciona: `CancelledError` no drain → `:cancelled` + `:task_cancelled`
- [ ] Nenhum `sleep`/`Timeout.timeout`/thread — só primitivas Async (doc 03 §5)
- [ ] Suíte roda **sem `ruby_llm` instalado** e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Lacuna de layout:** o doc 00 §3 não lista `lib/harness/event_stream.rb` nem `task_actor.rb`, mas o doc 03 §2 define as duas classes públicas. Um arquivo por classe segue a convenção do restante do layout — registrado aqui, não é decisão nova.
- `#spawn` e `#cancel` não constam na superfície do doc 03 §2 (que lista `execute`/`running?`), mas são exigidos pelo estágio 1 do §4 ("spawn TaskActor") e pelo §4.1 ("posta `:cancel` na mailbox"); ver Notes da task 9.
- O rescue genérico do `execute` é **provisório de esqueleto**: a task 12 o substitui pela captura única completa do doc 03 §6/L3 (mapa por classe de erro, `stage` no error da Execution, evento `:error` compat, ordem checkpoint→session→task).
- `:done`/`:task_completed` (caminho de sucesso) não são emitidos nesta task — pertencem ao estágio 9 (task 12). Não simule.
- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
