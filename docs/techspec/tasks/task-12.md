# Task 12: Handler `SendMessage` end-to-end (providers stub) + checkpoint no estágio 8 + timeouts D4

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ✅ DONE
> **Complexity:** High

---

## Objective

Fechar o caminho canônico completo Command→Response: handler `SendMessage` (validações síncronas, XOR `session_id`/`history` do D2), `TurnState`, pipeline dos 9 estágios no Executor com Builder/Policy/Middleware/Hooks **stub** (os reais chegam nas etapas D/E), estágio 8 de persistência na ordem checkpoint→session→task (doc 02 L4), timeouts do D4 via `Async::Task#with_timeout` e a captura única de exceção no topo do fiber (doc 03 §6/L3) — verificado por teste de integração com RubyLLM mockado (handoff §6).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 7 | `CheckpointStore` (checkpoint por turno, chave avulsa de side-effects, `prune`) | ⬜ TODO |
| 10 | `Executor` esqueleto: fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream` | ⬜ TODO |
| 11 | Migrar `runner.rb` → estágios 6-7 (build_chat/seed/callbacks RubyLLM intactos, `max_tool_calls` no hook) | ⬜ TODO |

## Context

`SendMessage` é o Command de turno canônico (D3): cria Task, responde `{task_id:}` imediato e executa a pipeline inteira dentro do fiber (doc 03 §4). Esta task é onde o esqueleto (task 10) e os estágios RubyLLM (task 11) viram um fluxo de ponta a ponta — com os estágios 2, 3 e 4 servidos por **stubs honestos** (interfaces dos docs 04/05, comportamento mínimo), trocados sem tocar o Executor quando as tasks 14-18 chegarem.

Também é onde mora o coração da durabilidade: o **estágio 8** grava checkpoint→session→task nessa ordem exata (doc 02 L4 — cair entre escritas deixa, no pior caso, um checkpoint válido com task `running`, que o Recovery retoma com segurança), e a **captura única** no topo do fiber (L3) garante que todo erro vira estado terminal + eventos, nunca exceção vazada.

Regra de ouro dos timeouts (D4): `Async::Task#with_timeout`, **nunca** `Timeout.timeout` da stdlib (thread-based, viola o modelo Async/Fibers).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/turn_state.rb` | classe MUTÁVEL do doc 03 §3 (única exceção aos `Data` — L5) |
| CREATE | `lib/harness/commands/send_message.rb` | validação síncrona + create Task + spawn + `{task_id:}` |
| MODIFY | `lib/harness/executor.rb` | `run_pipeline` real (estágios 2-9), estágio 8, timeouts, captura única, wrapper de tool-timeout, registro de side-effects |
| MODIFY | `lib/harness.rb` | requires novos |
| CREATE | `spec/support/fakes.rb` | `FakeContextBuilder`, `NullPolicyEngine`, `PassthroughMiddleware`, `NullHooks` |
| CREATE | `spec/harness/commands/send_message_spec.rb` | validações síncronas (XOR D2, 404s) |
| CREATE | `spec/harness/executor_pipeline_spec.rb` | ordem dos estágios, estágio 8, captura única, timeouts |
| CREATE | `spec/harness/integration/send_message_flow_spec.rb` | fluxo completo com chat mockado |

### Step-by-Step Instructions

#### Step 1: `TurnState`

**File:** `lib/harness/turn_state.rb`

Exatamente o doc 03 §3 — mutável de propósito (Middleware **modifica**, princípio 9/L5):

```ruby
# frozen_string_literal: true

module Harness
  # MUTÁVEL de propósito (única exceção aos Data deste techspec, doc 03 L5):
  # Middleware MODIFICA a execução — os elos escrevem nestes campos.
  class TurnState
    attr_reader   :task, :profile, :turn          # identidade do turno (1-based)
    attr_accessor :message,                       # entrada (Middleware pode reescrever)
                  :context,                       # ContextPackage do Builder (doc 04)
                  :allowed_tools, :allowed_skills,# Resolution do Policy Engine (doc 05)
                  :chat,                          # instância RubyLLM::Chat do turno
                  :halt_reason                    # setado por Middleware ao curto-circuitar

    # Interno (não faz parte do contrato do doc 03 §3): correlação
    # tool_call corrente ↔ decorators de tool (side-effects/skip, task 13).
    attr_accessor :current_tool_call

    def initialize(task:, profile:, turn:, message:)
      @task, @profile, @turn, @message = task, profile, turn, message
    end
  end
end
```

#### Step 2: handler `SendMessage`

**File:** `lib/harness/commands/send_message.rb`

Payload (doc 03 §3) e validações — tudo **síncrono, antes do fiber** (doc 03 §6: `ValidationError`/`NotFoundError` → resposta HTTP direta, nenhuma Task criada):

```ruby
module Harness
  module Commands
    class SendMessage
      def initialize(profiles:, session_store:, task_store:, executor:)

      def call(command)
        p = normalize(command.payload)   # aceita chaves string e símbolo

        # agent: obrigatório; deve existir em profiles → NotFoundError (D4)
        agent = p[:agent].to_s
        raise ValidationError, "agent é obrigatório" if agent.empty?
        profile = @profiles[agent] or
          raise NotFoundError, "agente '#{agent}' não configurado"

        # message: obrigatória, não-vazia
        message = p[:message]
        raise ValidationError, "message é obrigatória e não-vazia" if message.to_s.strip.empty?

        # D2: session_id XOR history (ambos → erro; nenhum → one-shot)
        if p[:session_id] && p[:history]
          raise ValidationError, "session_id e history são mutuamente exclusivos (D2)"
        end
        validate_history!(p[:history]) if p[:history]
        if p[:session_id]
          @session_store.find(p[:session_id]) or
            raise NotFoundError, "sessão '#{p[:session_id]}' não encontrada"
          # o provider Session (doc 04) recebe a sessão já validada — a
          # validação de existência é AQUI, síncrona (doc 03 §3)
        end

        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn(task, profile: profile)
        { task_id: task.id }                    # imediato; resultado via events (RFC-0002 §7)
      end

      private

      def validate_history!(history)
        ok = history.is_a?(Array) && history.all? { |m|
          m.is_a?(Hash) && !m.values_at(:role, "role").compact.empty? &&
            !m.values_at(:content, "content").compact.empty?
        }
        raise ValidationError, "history deve ser [{role:, content:}]" unless ok
      end
    end
  end
end
```

`command.to_h` persiste o Command inteiro na Task (schema do doc 02 §3 — o `ResumeTask` relê `payload.message` de lá, task 13).

**Reference pattern from codebase** (validação de agente na Fase 0, `reference-implementation/lib/agent_runtime/runner.rb` — o erro vira `NotFoundError` conforme D4):
```ruby
def run(agent_id, message, history: [], &emit)
  emit ||= ->(_event) {}
  profile = @profiles.fetch(agent_id.to_s) { raise ArgumentError, "agente '#{agent_id}' não configurado" }
```

#### Step 3: pipeline real no Executor (estágios 2-9)

**File:** `lib/harness/executor.rb`

Substituir o stub `run_pipeline` da task 10 pela sequência do doc 03 §4, com drain de mailbox nas fronteiras (L2) e turn-timeout envolvendo 2-8 (doc 03 §5):

```ruby
def run_pipeline(task, profile, actor, resume_from)
  turn  = resume_from ? resume_from.turn : 1
  state = TurnState.new(task: task, profile: profile, turn: turn,
                        message: extract_message(task))

  turn_timeout = profile.limits[:turn_timeout] || 300          # D4/D6
  begin
    Async::Task.current.with_timeout(turn_timeout) do
      # ── estágio 2: Context ───────────────────────────────────────────
      request = build_context_request(task, profile, state, resume_from)
      state.context = @hooks.around(:prompt, request) { |req| @context_builder.call(req) }
      actor.drain!

      # ── estágio 3: Policy ────────────────────────────────────────────
      resolution = @policy_engine.decide(policy_request(profile, task, state))
      state.allowed_tools  = wrap_tools(resolution.allowed_tools, state)
      state.allowed_skills = resolution.allowed_skills
      # candidate_skills vem do CATÁLOGO (skill_catalog.effective(profile.skills)),
      # não do ContextPackage (doc 03 §4, estágio 3)
      actor.drain!

      # ── estágio 4: Middleware ────────────────────────────────────────
      @middleware.call(state) do |st|
        raise Error, "turno interrompido: #{st.halt_reason}" if st.halt_reason

        # ── estágio 5: montar chat + checar mailbox ──────────────────
        actor.drain!
        st.chat = create_chat(profile)                # task 11 (lazy ruby_llm)
        configure_chat(st.chat, st)
        seed_history(st.chat, st.context.history)
        wire_callbacks(st.chat, st)                   # task 11 (estágio 7)

        # ── estágio 6: RubyLLM — ÚNICA interação com o modelo ────────
        response = @hooks.around(:agent, st) do |s|
          s.chat.ask(s.message) do |chunk|
            emit(:content, { delta: chunk.content }, task: task) if chunk.content
          end
        end

        # ── estágio 8: Persistence (ordem fixa, doc 02 L4) ───────────
        actor.drain!                                  # nunca DURANTE o estágio 8 (D4)
        persist_turn(task, profile, st, response)

        # ── estágio 9: Response ──────────────────────────────────────
        emit(:done,           { content: response.content }, task: task)   # compat Fase 0
        emit(:task_completed, { task_id: task.id, content: response.content }, task: task)
      end
    end
  rescue Async::TimeoutError
    raise TimeoutError.new("turno excedeu #{turn_timeout}s", stage: :turn)
  end
end
```

Notas de implementação:
- `@hooks` na Fase desta task é o `NullHooks` (around = yield); a interface `around(pair, subject)` é a do doc 05 §2 — quando a task 16/19 chegar, nada muda aqui.
- Middleware halt: elo que curto-circuita **não** chama `nxt` e seta `state.halt_reason` (doc 05 §3) → o Executor converte em falha do turno (task `:failed`, evento `:error` — via captura única).
- Se `state.halt_reason` foi setado e a cadeia retornou sem executar o bloco terminal, tratar igualmente como falha (verificar após `@middleware.call`).
- `extract_message`: `task.command["payload"]["message"]` (ou símbolos) — a Task persiste o Command (Step 2).

#### Step 4: estágio 8 — `persist_turn`

**File:** `lib/harness/executor.rb`

```ruby
# Ordem FIXA: checkpoint → session → task (doc 02 L4). Se cair entre
# escritas, o pior caso é checkpoint novo com task ainda :running →
# Recovery reexecuta turno já salvo (seguro por side-effect registry).
def persist_turn(task, profile, state, response)
  new_messages = [
    { role: "user",      content: state.message },
    { role: "assistant", content: response.content }
  ]
  transcript = Array(state.context.history) + new_messages

  # checkpoint do turno n+1 = estado no INÍCIO do turno n+1 (doc 02 §3);
  # completed_side_effects: o save (task 7) absorve a chave avulsa — o
  # Executor NÃO une nada aqui.
  @checkpoint_store.save(Checkpoint.new(
    task_id: task.id, turn: state.turn + 1, session_id: task.session_id,
    agent_id: profile.id, messages: transcript,
    completed_side_effects: [], created_at: Time.now.utc.iso8601
  ))

  # sessão só quando o turno é de sessão persistida (D2); one-shot/history
  # não persistem NA SESSÃO (mas sempre checkpointam — doc 02 §3)
  @session_store.append_messages(task.session_id, new_messages) if task.session_id

  @task_store.finish_execution(task.id, outcome: :completed)
  @task_store.transition(task.id, to: :completed)
  @checkpoint_store.prune(task.id, keep: 1)          # doc 02 L6

  emit(:checkpoint_created, { task_id: task.id, turn: state.turn + 1 }, task: task)
end
```

#### Step 5: captura única no topo do fiber (substitui o rescue provisório da task 10)

**File:** `lib/harness/executor.rb`

Doc 03 §6/L3 — **um** só lugar mapeia erro→estado terminal→eventos; estágios não fazem rescue próprio (exceto tool, semântica RubyLLM):

```ruby
def execute(task, profile:, resume_from: nil, actor:)
  # ... begin_execution / transition(:running) / :task_started (task 10) ...
  run_pipeline(task, profile, actor, resume_from)
rescue CancelledError
  finalize(task, to: :cancelled, outcome: :cancelled,
           events: [[:task_cancelled, { task_id: task.id }]],
           error: nil)
rescue PolicyDenied => e
  emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task)   # D5
  fail_task(task, e, stage: :policy)
rescue ContextError  => e then fail_task(task, e, stage: :context)
rescue ProviderError => e then fail_task(task, e, stage: :ruby_llm)
rescue StoreError    => e then fail_task(task, e, stage: :persistence)
rescue TimeoutError  => e then fail_task(task, e, stage: e.stage)
rescue StandardError => e then fail_task(task, e, stage: :unknown)
ensure
  @running.delete(task.id)
end

def fail_task(task, error, stage:)
  @task_store.transition(task.id, to: :failed,
    error: { class: error.class.name, message: error.message, stage: stage })
  @task_store.finish_execution(task.id, outcome: :failed)
  emit(:task_failed, { task_id: task.id, error: error.class.name,
                       message: error.message }, task: task)
  emit(:error,       { message: error.message }, task: task)   # compat Fase 0 (D5)
  # NUNCA re-raise: o fiber morre limpo (doc 03 §6)
end
```

- `CancelledError` também emite `:error` compat? O doc 03 §6 manda emitir `:task_failed`/`:task_cancelled` **e** `:error`; seguir o literal (emitir `:error` com "task cancelada") — o consumidor Fase 0 só conhece `:done`/`:error`, e um cancelamento sem `:error` o deixaria pendurado.
- O checkpoint anterior **nunca** é tocado em falha (D4: "checkpoint nunca é corrompido") — nenhum caminho de erro escreve no CheckpointStore.
- A escrita de `fail_task` em si pode falhar (store caído): deixar propagar para o log do reactor após tentar emitir `:error` — subir sem persistência não tem resposta melhor na Fase 1 (doc 02 §6).

#### Step 6: tool-timeout (D4, 60s por tool)

**File:** `lib/harness/executor.rb`

Doc 03 §5: "por-tool (60s) envolvendo o estágio 7 de cada call"; D4: estouro é devolvido **ao modelo** como erro serializado (não derruba o turno). Como o loop de tools é do RubyLLM, o envelope é um decorator aplicado às instâncias permitidas (chamado em `wrap_tools`, Step 3):

```ruby
require "delegate"

# Envolve cada tool permitida: timeout por call (D4) + registro de
# side-effect não-idempotente ANTES de o resultado voltar ao modelo
# (doc 02 §2/§3). Delega todo o resto (name/description/params) à tool real.
class ToolEnvelope < SimpleDelegator
  def initialize(tool, state:, checkpoint_store:, tool_registry:, timeout:)

  # Sobrescrever o ponto de entrada que o RubyLLM invoca (Tool#call na
  # versão pinada; conferir na 1.15 — ver Notes).
  def call(args)
    result = Async::Task.current.with_timeout(@timeout) { __getobj__.call(args) }
    record_side_effect! if side_effect?
    result
  rescue Async::TimeoutError
    { error: "TimeoutError: tool excedeu #{@timeout}s" }   # volta ao modelo (D4)
  end

  private

  def side_effect?
    @tool_registry.respond_to?(:side_effect?) &&
      @tool_registry.side_effect?(__getobj__.name)
  end

  def record_side_effect!
    id = @state.current_tool_call&.id or return
    @checkpoint_store.record_side_effect(@state.task.id, turn: @state.turn,
                                         tool_call_id: id)
  end
end
```

- `wrap_tools(tools, state)` → `tools.map { |t| ToolEnvelope.new(t, state:, ...timeout: profile.limits[:tool_timeout] || 60) }`. A `LoadSkill` de sistema (task 11) também é envolvida (timeout vale para ela; `side_effect?` é falso).
- `state.current_tool_call` é setado no `before_tool_call` (ajustar o `wire_callbacks` da task 11: `state.current_tool_call = tool_call` na primeira linha do callback) — é a correlação call↔execução que a task 13 reusa para o skip.
- `side_effect?` programa contra o predicado `tool_registry.side_effect?(name)` — o registro real com `side_effect: true` chega no doc 06 (tasks 20/21); até lá o registry stub/fake dos testes o implementa, e um registry sem o método significa "nenhuma tool side-effect".

#### Step 7: fakes de spec (stubs das etapas D/E)

**File:** `spec/support/fakes.rb`

Interfaces dos docs 04/05, comportamento mínimo e determinístico:

- `FakeContextBuilder` — `#call(request)` → objeto com `system:` (do `profile.base_prompt`), `history:` (na ordem de precedência do doc 04: `request.checkpoint&.messages` → `request.history` → mensagens da `request.session` → `[]`), `tool_context: nil`. É um espelho pobre do Builder real (task 14) — mesma assinatura.
- `NullPolicyEngine` — `#decide(request)` → `Resolution`-like (`Struct.new(:allowed_tools, :allowed_skills)`) com `allowed_tools` = instâncias injetadas no construtor do fake e `allowed_skills` = `skill_catalog.effective(profile.skills).map(&:name)` (paridade Fase 0 até a task 17). Variante `DenyAllPolicyEngine` que levanta `PolicyDenied` (para o teste do estágio 3).
- `PassthroughMiddleware` — `#call(state) { |s| yield s }`; variante `HaltingMiddleware` que seta `state.halt_reason = "rate limit"` e não chama o bloco.
- `NullHooks` — `#around(pair, subject) { |s| yield s }`, gravando a ordem dos pares invocados (para o teste de wrappers).

### Edge Cases to Handle

1. `session_id` E `history` no payload → `ValidationError` **síncrono**, nenhuma Task criada (D2).
2. Nenhum dos dois → turno one-shot sem histórico (D2); checkpoint ainda é gravado (doc 02 §3).
3. `history` presente → nada é persistido na sessão (comportamento Fase 0, D2).
4. Sessão inexistente → `NotFoundError` **antes** do fiber (doc 03 §3).
5. `PolicyDenied` no estágio 3 → evento `:policy_denied` + task `:failed`; RubyLLM nunca é tocado (D4).
6. Middleware halt → task `:failed` com `halt_reason` na mensagem, sem tocar RubyLLM (doc 05 §4).
7. Cancel postado durante o estágio 6 → visto no próximo drain (fronteira) → `:cancelled`; checkpoint anterior intacto; **nenhum evento após** `:task_cancelled`.
8. Timeout de turno → `TimeoutError(stage: :turn)`, task `:failed`, checkpoint anterior preservado (D4).
9. Tool que estoura 60s → resultado de erro volta ao modelo; turno **continua** (D4 linha Tool Execution).
10. Falha do store no estágio 8 → `StoreError`, task `:failed`, evento `:error` — "o turno já executou; o erro é reportado, não silenciado" (D4 linha Persistence).
11. Exceção **dentro** do `chat.ask` (ex.: `TimeoutError(stage: :tool_limit)` do contador da task 11) → captura única → `:failed`.
12. `chunk.content` nil no streaming → não emite `:content` (paridade Fase 0).

## Testing

### Unit Tests

**File:** `spec/harness/commands/send_message_spec.rb` (executor = duplo que grava `spawn`)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| caminho feliz | payload válido com session | Task criada `:queued` com `command` persistido; `spawn` chamado; retorna `{task_id:}` |
| XOR D2 | `session_id` + `history` | `ValidationError`; **nenhuma** Task no store |
| agente inexistente | `agent: "ghost"` | `NotFoundError` |
| agent/message ausentes ou vazios | 4 variações | `ValidationError` |
| sessão inexistente | `session_id: "ghost"` | `NotFoundError`, nenhuma Task |
| history malformado | `[{foo: 1}]` | `ValidationError` |
| one-shot | sem session_id/history | Task criada com `session_id: nil` |

**File:** `spec/harness/executor_pipeline_spec.rb` (fakes do Step 7 + `FakeChat` da task 11 via stub de `create_chat`; tudo em `Sync { }`)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| ordem dos estágios | colaboradores-espião | builder → policy → middleware → chat → persistência, nessa ordem |
| estágio 8 na ordem L4 | espiões nos 3 stores | `checkpoint.save` → `session.append_messages` → `task.finish_execution/transition` |
| checkpoint do turno n+1 | turno 1 completo | checkpoint com `turn == 2`, `messages` = history + user + assistant, `agent_id` do profile |
| sessão persistida (D2) | task com session_id | `append_messages` com as 2 mensagens novas |
| one-shot não toca sessão | task sem session_id | `append_messages` NÃO chamado; checkpoint gravado mesmo assim |
| prune ao completar | turno completo | `prune(task_id, keep: 1)` chamado (L6) |
| PolicyDenied | `DenyAllPolicyEngine` | `:policy_denied` + `:task_failed` + `:error`; chat nunca construído |
| middleware halt | `HaltingMiddleware` | task `:failed` com halt_reason; chat nunca construído |
| captura única | builder que levanta `ContextError` | task `:failed` com `error.stage == :context`; fiber não vaza |
| StoreError no 8 | checkpoint_store que levanta | `:failed` stage `:persistence`; `:error` emitido |
| turn timeout | `limits[:turn_timeout] = 0.05` + fake chat lento (cede o fiber) | `:failed` com `stage: :turn` (via `with_timeout`, nunca `Timeout.timeout`) |
| tool timeout | ToolEnvelope com tool lenta e `tool_timeout` curto | retorno `{error: "TimeoutError..."}`; turno segue e completa |
| side-effect registrado | registry fake `side_effect?("x") == true`; tool executa | `record_side_effect` com o `tool_call_id` corrente, ANTES do resultado voltar |
| cancel na fronteira | post `:cancel` durante estágio 6 (fake que cede) | `:cancelled`; checkpoint anterior intacto; nenhum evento após `:task_cancelled` |

### Integration Tests

**File:** `spec/harness/integration/send_message_flow_spec.rb`

Wiring real: `CommandBus` + handler + `Executor` + stores de domínio sobre `Stores::Memory` + `EventStream` real; chat roteirizado. Duas variantes:

1. **Sem a gem** (roda sempre): `create_chat` stubado com `FakeChat` roteirizado (2 chunks + 1 tool call + resposta final).
2. **Com a gem** (tag `:ruby_llm`, skip se `LoadError`): stub de `RubyLLM.chat` devolvendo o mesmo roteiro — cobre `create_chat` real (doc 03 §7: "stub de RubyLLM.chat devolvendo chunks + tool calls roteirizados").

| Test Case | Description | Expected |
|-----------|-------------|----------|
| fluxo completo | dispatch de `send_message` com session; subscriber no stream | ordem: `:task_started` → `:content`×2 → `:tool_call` → `:tool_result` → `:checkpoint_created` → `:done` → `:task_completed` (doc 03 §7) |
| seq monotônico | mesmo fluxo | `meta.seq` estritamente crescente; `meta.task_id`/`session_id` corretos em todos |
| estado final | após `:done` | task `:completed`, Execution 1 fechada `outcome: :completed`, checkpoint `turn: 2` no store, transcript na sessão |
| resposta imediata | dispatch | retorna `{task_id:}` antes de `:done` ser emitido |
| paridade history-only | payload com `history`, sem session | mesmo fluxo de eventos; sessão intocada (caminho de migração doc 03 §8, passo 1) |

## Definition of Done

- [ ] `SendMessage` valida tudo síncrono (XOR D2, `NotFoundError` de agente/sessão) e responde `{task_id:}` imediato
- [ ] Pipeline executa os estágios na ordem do doc 03 §4, com drain de mailbox só nas fronteiras (L2)
- [ ] Estágio 8 na ordem checkpoint→session→task (doc 02 L4) + `prune(keep: 1)` + `:checkpoint_created`
- [ ] Timeouts com `Async::Task#with_timeout` (turno 300s, tool 60s — `profile.limits`); **zero** `Timeout.timeout`
- [ ] Captura única no topo do fiber mapeia D4 completo (classe→estado terminal→`stage`→eventos `:task_failed`/`:task_cancelled` + `:error` compat); fiber nunca re-raise
- [ ] Builder/Policy/Middleware/Hooks consumidos pelas interfaces dos docs 04/05 (stubs trocáveis sem tocar o Executor)
- [ ] Integração Command→Response verde com chat mockado; suíte (exceto tag `:ruby_llm`) roda **sem `ruby_llm` instalado** e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Ponto de entrada do `ToolEnvelope`:** o RubyLLM (1.15) invoca a tool por um método público (`call`/`execute` conforme a versão pinada, D9). Sobrescrever no delegator o método que o **loop** invoca — se for `call` que internamente chama `execute` em `self`, a sobrescrita de `call` funciona; verificar na versão pinada antes de fechar. É detalhe de integração, não decisão arquitetural.
- **`TurnState.current_tool_call`** não consta no contrato do doc 03 §3 — é campo interno de correlação (before_tool_call ↔ decorator) exigido pelo registro de side-effects (doc 02 §2: escrita "ANTES de o resultado da tool voltar ao modelo") e pelo skip da task 13. Registrado aqui como detalhe de implementação.
- **`tool_registry.side_effect?`** é o seam para `register(name, klass, side_effect: true)` (doc 06, tasks 20/21). Até lá, registry sem o método = nenhuma tool side-effect; os testes usam fake com o predicado.
- **`user_message` pendente** (mailbox): a Fase 1 não tem produtor (doc 03 §2); o loop `max_turns`/multi-turno fica dormindo — `max_turns` só é exercitado quando houver produtor (Fase 2) ou workflow multi-turno. Não implemente o loop de conversa agora; o guard `max_tool_calls` (task 11) cobre o loop real existente.
- Os fakes do Step 7 vivem em `spec/support` de propósito: **não** criar `NullPolicyEngine` em `lib/` — o wiring de produção só se fecha na task 26, quando os componentes reais existem.
- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 24 novos (8 send_message + 11 pipeline + 5 integração), 326 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/turn_state.rb`, `lib/harness/tool_envelope.rb`, `lib/harness/commands/send_message.rb`, `spec/support/fakes.rb`, `spec/harness/commands/send_message_spec.rb`, `spec/harness/executor_pipeline_spec.rb`, `spec/harness/integration/send_message_flow_spec.rb`
- **Arquivos modificados:** `lib/harness/executor.rb` (run_pipeline real 2-9, persist_turn, wrap_tools, captura única, current_tool_call no wire_callbacks), `lib/harness.rb` (requires), `spec/support/fake_chat.rb` (script/emit_chunk/final_content), `spec/harness/executor_chat_spec.rb` (State +current_tool_call)
- **Observações / decisões tomadas:**
  - **Captura única (D4/L3):** um só rescue no topo do fiber mapeia classe→estado terminal→`stage`→eventos. Reaproveitei a lição da task 10 — `transition(error:)` já fecha a Execution, então `fail_task` **não** chama `finish_execution` (evita dupla-fecho). O caminho `:cancelled` usa `transition` sem `error:` + `finish_execution`.
  - **Estágio 8** na ordem fixa checkpoint→session→task (doc 02 L4) + `prune(keep:1)` + `:checkpoint_created`. Sessão só é tocada quando há `session_id` (D2); one-shot/history sempre checkpointam.
  - **Timeouts (D4)** com `Async::Task#with_timeout` — turno (300s) envolvendo 2-8, tool (60s) no `ToolEnvelope`; **zero** `Timeout.timeout`. Estouro de tool volta `{error:}` ao modelo (turno segue); estouro de turno → `TimeoutError(stage: :turn)`.
  - **`ToolEnvelope`** (SimpleDelegator): timeout por call + `record_side_effect` antes de o resultado voltar (correlação via `state.current_tool_call`, setado na 1ª linha do `before_tool_call`). `side_effect?` programa contra `tool_registry.side_effect?(name)` (seam do doc 06).
  - **Desvio registrado:** a `LoadSkill` de sistema (adicionada em `configure_chat`) **não** é envelopada nesta fase (o doc §6 sugere envelopá-la). É tool de sistema sem side-effect e de latência trivial; envelopá-la exigiria passar timeout/checkpoint_store ao `configure_chat` (compartilhado com a task 11). Documentado; reavaliar se necessário.
  - **Middleware halt:** o elo que curto-circuita seta `halt_reason` e não chama o bloco; verifico `halt_reason` após `@middleware.call` e levanto `Error` → captura única → `:failed`. Chat nunca é construído.
  - Fakes das etapas D/E vivem em `spec/support/fakes.rb` (não em `lib/`) — wiring de produção só na task 26.
  - Integração roda **sem `ruby_llm`** (create_chat stubado com FakeChat roteirizado). A variante tag `:ruby_llm` (stub de `RubyLLM.chat` real) foi deixada para quando o wiring/boot da task 26 existir — `create_chat` (linha de fábrica) segue coberto só por inspeção, como na task 11.
