# Techspec 03 — Command Bus + Runtime Executor (pipeline por estágios)

> Implementa RFC-0002 (fluxo canônico, correções 1 e 2, faseamento do Actor
> §9-Fase 1). Evolui o `runner.rb` da Fase 0 de loop linear para a pipeline
> por estágios — a lógica RubyLLM migra **intacta** (RubyLLM First).

## 1. Objetivo e fronteira

**Faz:** `Command` + `CommandBus` (toda interação vira Command — RFC-0001
princípio 5); handlers dos cinco Commands (D3); `Executor` com os 9 estágios
da RFC-0002 §4; Task como fiber Async com mailbox mínima (`cancel`,
`user_message` — RFC-0002 §9 Fase 1); checkpoint por turno.

**Não faz:** montar prompt (Context Builder, doc 04 — constituição princípio
8); decidir permissão (Policy Engine, doc 05); loop do modelo, streaming,
retries de provider (RubyLLM); mailbox completa/Sessions-como-Actors (Fase 2).

## 2. Interfaces públicas

```ruby
module Harness
  Command = Data.define(:type, :payload, :meta) do
    # meta: { command_id: String, tenant: String|nil,
    #         transport: Symbol, issued_at: String(ISO8601) }
    def self.build(type, payload, transport: :internal, tenant: nil)
      # command_id: SecureRandom.uuid; issued_at: Time.now.utc.iso8601
    end
  end

  class CommandBus
    def initialize(event_stream:)
    def register(type, handler)        # handler responde a #call(command) 
    def dispatch(command)              # -> resultado do handler
    # controle → resultado síncrono (Session, Task atualizada…)
    # turno    → { task_id: } imediato; execução segue no fiber (RFC-0002 §7)
  end

  # Um handler por arquivo em lib/harness/commands/:
  module Commands
    class CreateSession    # payload: { vars: {} }            -> Session
    class SendMessage      # payload: ver §3                  -> { task_id: }
    class TriggerWorkflow  # payload: { workflow:, agent:, input:, session_id: } -> { task_id: }
    class CancelTask       # payload: { task_id: }            -> Task
    class ResumeTask       # payload: { task_id: }            -> { task_id: }
  end

  # Coordena. Não monta contexto, não decide policy, não fala com o provider.
  class Executor
    def initialize(context_builder:, policy_engine:, middleware:, hooks:,
                   tool_registry:, workflow_registry:, skill_catalog:,
                   profiles:, session_store:, task_store:, checkpoint_store:,
                   event_stream:)

    # Cria o fiber da task (TaskActor) e agenda execute nele; retorna já.
    def spawn(task, profile:, resume_from: nil)     # -> task_id (usado pelos handlers de turno)
    # Estágios 2..9 para uma Task de turno. Roda DENTRO do fiber da task.
    def execute(task, profile:, resume_from: nil)   # -> void (resultado via events/stores)
    # Registro in-process de fibers vivos:
    def running?(task_id)            # -> bool; true = há fiber vivo NESTE processo (ResumeTask, §3)
    def cancel(task_id)              # -> bool; posta :cancel na mailbox do actor (CancelTask)
  end

  # Fase 1 do Actor (RFC-0002 §9): fiber + mailbox mínima.
  class TaskActor
    MESSAGES = %i[cancel user_message].freeze
    # :user_message é RESERVADO na Fase 1: o enum e o consumo (§4.1) existem,
    # mas nenhum Command/rota o produz ainda — o produtor chega na Fase 2
    # (mailbox completa). Mantido no enum para o contrato não mudar depois.
    def initialize(task_id:, parent: Async::Task.current)
    def post(message, data = nil)    # -> void; :cancel | :user_message
    def run(&turn_block)             # roda o bloco no fiber, drenando a mailbox
                                     # nas fronteiras de turno/estágio
  end

  # Event Stream do processo (RFC-0002 §7): pub/sub in-process.
  class EventStream
    def emit(event)                  # -> void; nunca levanta (observadores isolados)
    def subscribe(task_id: nil, session_id: nil)  # -> Subscription; nil/nil = todos
    # Subscription: fila própria (Async::Queue) por assinante —
    #   #each(&blk)  itera eventos até #close (bloqueia o fiber do CONSUMIDOR)
    #   #close       encerra; o filtro usa event.meta (task_id/session_id, D5)
  end
end
```

## 3. Modelos de dados / schemas

### Payloads dos Commands (validados pelo handler; violação → `ValidationError`)

```ruby
# send_message — D2: session_id XOR history
{ agent:      String,             # obrigatório; deve existir em profiles
  message:    String,             # obrigatório, não-vazio
  session_id: String | nil,       # exclusivo com history; handler valida
                                  # existência da sessão → NotFoundError
                                  # síncrono (ANTES do fiber; o provider
                                  # Session, doc 04, já recebe a sessão achada)
  history:    [{role:, content:}] | nil }

# trigger_workflow
{ workflow: String,               # deve existir no Workflow Registry (doc 06)
                                  # E constar em profile.workflows_allow
                                  # (WorkflowAllowlist, doc 05 §2)
  agent: String, input: Hash, session_id: String | nil }

# cancel_task / resume_task
{ task_id: String }               # deve existir; resume exige checkpoint E:
                                  #   status paused|waiting → sempre retomável
                                  #   status running → só se NÃO houver fiber
                                  #     vivo (executor.running?(task_id) ==
                                  #     false ⇒ órfã de crash); fiber vivo →
                                  #     ValidationError "task em execução".
                                  #   (single-node na Fase 1, D7 — o registro
                                  #    in-process é critério suficiente)
```

### Estados internos do turno

```ruby
# MUTÁVEL de propósito (única exceção aos Data deste techspec): Middleware
# MODIFICA a execução (princípio 9) — os elos escrevem nestes campos.
class TurnState
  attr_reader   :task, :profile, :turn         # identidade do turno (1-based)
  attr_accessor :message,                      # entrada (Middleware pode reescrever)
                :context,                      # ContextPackage do Builder (doc 04)
                :allowed_tools, :allowed_skills, # Resolution do Policy Engine (doc 05)
                :chat,                         # instância RubyLLM::Chat do turno
                :halt_reason                   # setado por Middleware ao curto-circuitar
end
```

## 4. Fluxo de controle — os 9 estágios (RFC-0002 §4)

`SendMessage` (o caminho canônico completo; `TriggerWorkflow` difere só no
estágio 6-7, ver §4.1):

```
1. Command      handler valida payload; task_store.create(status: queued);
                spawn TaskActor (fiber Async); responde { task_id: }
   ─── daqui pra baixo, dentro do fiber da task ───
                task_store.begin_execution; transition(:running); emite :task_started

2. Context      hooks.around(:prompt, request) { context_builder.call(request) }
                → ContextPackage (system/history/tool_context) [doc 04]

3. Policy       policy_engine.decide(PolicyRequest[profile:, command:, context:,
                  candidate_tools:  tool_registry.entries,
                  candidate_skills: skill_catalog.effective(profile.skills)])
                → Resolution { allowed_tools:, allowed_skills: } ou PolicyDenied [doc 05]
                (candidate_skills vem do CATÁLOGO, não do ContextPackage — o
                 pacote carrega o texto formatado, não a lista estruturada)

4. Middleware   middleware.call(turn_state) — cadeia Rack-like; pode modificar
                o TurnState (rewrite de prompt, rate limit, tracing) [doc 05]

5. Executor     coordena o turno: monta o chat (RubyLLM) com o contexto do
                estágio 2 e as tools do estágio 3; checa mailbox (cancel?).
                No PRIMEIRO turno da task, grava aqui o checkpoint do turno 1
                (estado inicial — consistente com doc 02 §3: "checkpoint do
                turno n = estado no início do turno n"). Sem ele, kill -9
                durante o turno 1 seria irrecuperável (Recovery marcaria
                :failed por falta de checkpoint) e o critério da fase
                (doc 00 §6) não se cumpriria.

6. RubyLLM      hooks.around(:agent) { chat.ask(message) { |chunk| emit :content } }
                ← ÚNICA interação com o modelo; loop/streaming/retry são do RubyLLM

7. Tools        dentro do loop RubyLLM: before_tool_call/after_tool_result →
                eventos :tool_call/:tool_result/:skill_activated;
                hooks.around(:tool); side-effects não-idempotentes registrados
                no checkpoint corrente (doc 02 §3)

8. Persistence  checkpoint_store.save(turno n+1) → session_store.append →
                task_store.finish_execution + transition(:completed);
                emite :checkpoint_created

9. Response     emite :done + :task_completed. Para SSE a Response foi a
                projeção contínua dos eventos desde o estágio 1 (RFC-0002 §7);
                para não-streaming, o transporte agrega até :done (doc 07)
```

Wrappers de hook (RFC-0002 §6 — correção 1): `before/after_task` envolvem
1→9; `before/after_prompt` o estágio 2; `before/after_agent` cada chamada de
agente (estágio 6); `before/after_tool` cada tool (estágio 7).

### 4.1 Variações

- **TriggerWorkflow:** estágios 1-5 idênticos; no 6, em vez de `chat.ask`, o
  Executor resolve o workflow no Workflow Registry (doc 06) e o invoca com
  `#call(input, context:, tools:)`, onde `context:` é o ContextPackage e
  `tools:` são as **instâncias** já filtradas pela Resolution (o workflow
  nunca enxerga tool negada, como o modelo). O workflow usa RubyLLM
  Agents/Workflows por dentro — o Harness não orquestra passos de LLM
  (RubyLLM First). **Semântica de turno:** a execução inteira do workflow é
  **um turno lógico** — um checkpoint ao final (estágio 8), side-effects
  registrados ao longo (doc 02 §2); na retomada, o workflow reexecuta do
  início com os side-effects pulados. Checkpoint intermediário por passo de
  workflow é Fase 2 (exigiria contrato de passo). Mesma pipeline, mesmos
  eventos (regra RFC-0002 §8: estende estágio, não cria fluxo).
- **ResumeTask:** carrega `checkpoint_store.latest`; reconstrói o TurnState
  com `messages` do checkpoint; abre nova Execution; entra no estágio 2 do
  turno checkpointado. Tool calls em `completed_side_effects` são respondidas
  com `{"skipped":"already_executed"}` (doc 02 L5).
- **CancelTask:** posta `:cancel` na mailbox. O TaskActor drena a mailbox nas
  fronteiras de estágio e de turno; ao ver `:cancel`, levanta
  `CancelledError` → transition(:cancelled) + `:task_cancelled`. Nunca
  interrompe no meio do estágio 8 (D4).
- **user_message** (mailbox): na Fase 1 só é aceita entre turnos — anexa a
  mensagem ao próximo turno do loop `max_turns`. (Injeção mid-turn é Fase 2.)

### 4.2 O que migra do `runner.rb` (intacto)

| Fase 0 (`Runner`) | Destino |
|---|---|
| `build_chat` (RubyLLM.chat + with_instructions + with_tools) | Executor estágio 5-6 — `with_instructions` agora recebe o pacote do Builder |
| `seed_history` | Executor estágio 5 (histórico vem do contexto/checkpoint) |
| `wire_callbacks` (before_tool_call/after_tool_result → eventos) | Executor estágio 7, inalterado + `meta` (D5) |
| injeção do `LoadSkill` fora da allowlist | mantida: tool de sistema, adicionada após a decisão de policy |

## 5. Concorrência

- **Um fiber por Task** (`Async do ... end` a partir do reactor do servidor).
  O CommandBus responde `{task_id:}` sem esperar o turno (RFC-0002 §7).
- Mailbox = `Async::Queue`; `post` é não-bloqueante; o drain acontece só nas
  fronteiras (cancelamento **cooperativo** — RFC-0001 princípio 7).
- Fan-out interno: providers no Builder (doc 04) e tools concorrentes são
  `Async` filhos do fiber da task — cancelar a task cancela a subárvore
  (estrutura do async: parent → children).
- Timeouts com `Async::Task#with_timeout` (D4): turno inteiro (300s default,
  `profile.limits.turn_timeout`) envolvendo estágios 2-8; por-tool (60s)
  envolvendo o estágio 7 de cada call.
- **Nunca bloqueia o reactor:** nenhum `sleep`, `Timeout.timeout`, ou IO
  síncrono longo; a exceção controlada é o SQLite (doc 01 §5).
- `EventStream.emit` é síncrono e barato (iteração de callbacks); observadores
  lentos (SSE de cliente lento) fazem buffer no próprio subscription
  (`Async::Queue` por subscriber) — um cliente lento nunca atrasa o turno.

## 6. Erros e timeouts

Aplicação direta do D4 (tabela por estágio no `00-overview §D4`). Regras
específicas do Executor:

- Toda exceção que escapa dos estágios 2-8 é capturada **uma vez** no topo do
  fiber: mapeia para o estado terminal (`PolicyDenied`/`ContextError`/
  `ProviderError`/`StoreError`/`TimeoutError` → `:failed`; `CancelledError` →
  `:cancelled`), fecha a Execution com `{class:, message:, stage:}`, emite
  `:task_failed`/`:task_cancelled` **e** `:error` (compat), e nunca re-raise
  (fiber morre limpo).
- `ValidationError`/`NotFoundError` acontecem **antes** do fiber (handler
  síncrono) → resposta HTTP direta (doc 07), nenhuma Task criada.
- Erro dentro de tool: não escapa — RubyLLM devolve ao modelo (Fase 0 já se
  comporta assim); o Executor apenas emite `:tool_result` com o erro.
- **Definição: 1 turno = 1 `chat.ask` completo** (o loop de tool-use é
  interno ao RubyLLM — o Executor NUNCA dirige roundtrips modelo→tool, isso
  violaria RubyLLM First). `max_turns` (default 25) limita **turnos de
  conversa** da task (`user_message` na mailbox, multi-turno de workflow) →
  excedido, `TimeoutError(stage: :turn_limit)`, task `:failed`.
- Proteção contra loop infinito de **tool-use** (que acontece dentro de um
  turno): contador no hook `before_tool`; ao exceder
  `profile.limits.max_tool_calls` (default 50), o hook levanta → o turno
  falha com `TimeoutError(stage: :tool_limit)`. Nenhum loop é reimplementado
  — o hook só conta e aborta.

## 7. Estratégia de testes

- **CommandBus:** registro/dispatch; payloads inválidos de cada Command →
  `ValidationError` com mensagem específica; XOR session/history (D2).
- **Executor por estágio isolado** (handoff §6): cada colaborador
  (builder/engine/middleware/stores) é um duplo; verifica ordem dos estágios,
  wrappers de hook na ordem correta (before na ida, after na volta), eventos
  emitidos com `seq` monotônico.
- **Integração Command→Response** com provider RubyLLM **mockado** (handoff
  §6): stub de `RubyLLM.chat` devolvendo chunks + tool calls roteirizados;
  verifica o fluxo completo: `:task_started` → `:content`* → `:tool_call` →
  `:checkpoint_created` → `:done`.
- **Cancelamento:** postar `:cancel` durante estágio 6 (mock que cede o fiber)
  → `:cancelled`, checkpoint anterior intacto, nenhum evento após
  `:task_cancelled`.
- **Resume:** turno com side-effect registrado → na retomada a tool não
  reexecuta e a call recebe `skipped`.
- **Timeout:** mock lento + `turn_timeout` curto → `:failed` com
  `stage: :turn`.
- Núcleo sem RubyLLM instalado: tudo exceto o teste de integração roda sem a
  gem (o require de `ruby_llm` fica confinado ao Executor e é lazy).

## 8. Evolução a partir da Fase 0

- `runner.rb` → **substituído** por `executor.rb` + `commands/send_message.rb`;
  §4.2 mapeia cada método. O comportamento observável da Fase 0 (eventos SSE,
  semântica de allowlist, LoadSkill de sistema) é preservado — os testes de
  contrato do endpoint (doc 07 §7) garantem.
- `event.rb` → estendido com `meta` (D5); `to_h` mantém as chaves atuais no
  topo (consumidor não quebra).
- `config/wiring.rb` → constrói bus/executor/actors; `RUNNER` deixa de
  existir; o server passa a despachar Commands (doc 07).
- Caminho de migração em dois passos: (1) Executor novo atrás do endpoint
  antigo com history-only (paridade Fase 0, sem stores); (2) ligar
  session_id/checkpoint/recovery. Cada passo é entregável e testável.

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Commands de controle síncronos (sem Task) | criar Task para `CreateSession` só adicionaria latência e linhas no Task Store; Task é para trabalho com lifecycle (RFC-0001 §5: Task = unidade de trabalho) |
| L2 | Drain de mailbox só em fronteiras de estágio/turno | cancelamento cooperativo da constituição (princípio 7); interromper mid-stage arriscaria checkpoint inconsistente |
| L3 | Captura única de exceção no topo do fiber | um só lugar mapeia erro→estado terminal→eventos; estágios não fazem rescue próprio (exceto tool, semântica RubyLLM) |
| L4 | `EventStream` pub/sub in-process com fila por subscriber | Event Stream é concorrente ao turno (RFC-0002 §7) e um observador lento não pode ter backpressure sobre a execução |
| L5 | `TurnState` é classe mutável (única exceção aos Data) | Middleware **modifica** (princípio 9); um objeto de estado com accessors explícitos é mais simples e honesto que reconstruir Data a cada elo — e `halt_reason` precisa ser escrito pelo elo que curto-circuita |
| L6 | `max_turns` (turnos de conversa) + `max_tool_calls` (calls por turno via hook) | dois guard-rails distintos porque são loops distintos: o de conversa é do Executor, o de tool-use é do RubyLLM (só contamos de fora, nunca dirigimos) |
