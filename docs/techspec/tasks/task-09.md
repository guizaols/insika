# Task 09: `Command` + `CommandBus` + handlers de controle (`CreateSession`, `CancelTask`)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Criar o tipo `Command` (com `build` preenchendo defaults de meta), o `CommandBus` (registro + dispatch) e os dois handlers de controle da Fase 1 — `CreateSession` e `CancelTask` — com validação síncrona de payload (`ValidationError`/`NotFoundError` antes de qualquer Task ser criada).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | ⬜ TODO |
| 5 | `SessionStore` (schema `session:<id>`, transcript como fonte da verdade) | ⬜ TODO |
| 6 | `TaskStore` (máquina de estados validada, Executions, campos de claim reservados) | ⬜ TODO |

## Context

Abre a Etapa C (o coração da fase). Pela RFC-0001 princípio 5, **toda interação vira Command** — esta task materializa esse princípio: o tipo `Command` (doc 00 §2), o `CommandBus` (doc 03 §2) e os dois Commands de **controle** do conjunto mínimo D3 (`CreateSession`, `CancelTask`), que agem sobre stores/mailbox e respondem **síncrono** (doc 03 L1 — não criam Task).

Os Commands de **turno** (`SendMessage`, `TriggerWorkflow`, `ResumeTask`) chegam nas tasks 12, 23 e 13; eles só se registram num bus que já existe. O `Recovery` (task 8) despacha `Command[:resume_task, ...]` num bus-duplo até a task 13 trocar pelo real — o contrato de `dispatch` definido aqui é o que esse duplo imita.

Regra do D4 (linha "Command Bus" da tabela): payload inválido → `ValidationError` **síncrono**, nenhuma Task criada. É o handler quem valida (doc 03 §3: "payloads validados pelo handler; violação → `ValidationError`").

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/command.rb` | `Command = Data.define(:type, :payload, :meta)` + `Command.build` com defaults |
| CREATE | `lib/harness/command_bus.rb` | registro `type → handler`, `dispatch`, tipo desconhecido → `ValidationError` |
| CREATE | `lib/harness/commands/create_session.rb` | handler de controle; cria sessão + emite `:session_created` |
| CREATE | `lib/harness/commands/cancel_task.rb` | handler de controle; posta `:cancel` via registro in-process do Executor |
| MODIFY | `lib/harness.rb` | acrescentar os `require_relative` (zero side-effects, doc 00 §3) |
| CREATE | `spec/harness/command_spec.rb` | defaults do `build`, imutabilidade |
| CREATE | `spec/harness/command_bus_spec.rb` | registro/dispatch/tipo desconhecido |
| CREATE | `spec/harness/commands/create_session_spec.rb` | payload, criação, evento |
| CREATE | `spec/harness/commands/cancel_task_spec.rb` | validações + post de cancel via duplo |

### Step-by-Step Instructions

#### Step 1: `Command` com `build`

**File:** `lib/harness/command.rb`

Implementar exatamente a interface do doc 03 §2:

```ruby
# frozen_string_literal: true

require "securerandom"

module Harness
  # Toda interação vira Command (RFC-0001 princípio 5).
  # type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                  :cancel_task, :resume_task)
  # payload: Hash validado pelo handler (schemas no doc 03 §3)
  # meta:    { command_id:, tenant:, transport:, issued_at: }
  Command = Data.define(:type, :payload, :meta) do
    def self.build(type, payload, transport: :internal, tenant: nil)
      new(
        type: type.to_sym,
        payload: payload || {},
        meta: {
          command_id: SecureRandom.uuid,
          tenant: tenant,
          transport: transport,
          issued_at: Time.now.utc.iso8601
        }
      )
    end
  end
end
```

Nada além disso: `Command` não valida payload (isso é do handler) e não conhece o bus.

**Reference pattern from codebase** (mesmo padrão `Data.define` + factory da Fase 0, `reference-implementation/lib/agent_runtime/agent_profile.rb`):
```ruby
AgentProfile = Data.define(
  :id, :model, :provider, :base_prompt, :prompt_files,
  :tools_allow, :tools_deny, :skills
) do
  def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                 tools_allow: nil, tools_deny: [], skills: nil)
    new(
      id: id, model: model, provider: provider, base_prompt: base_prompt,
      ...
```

#### Step 2: `CommandBus`

**File:** `lib/harness/command_bus.rb`

```ruby
class CommandBus
  def initialize(event_stream:)   # guardado para uso futuro/consulta; handlers
  def register(type, handler)     # recebem suas dependências no construtor
  def dispatch(command)           # -> resultado do handler
end
```

- `register(type, handler)`: `handler` é qualquer objeto que responda a `#call(command)` (doc 03 §2). Guardar em `@handlers[type.to_sym]`. Registrar duas vezes o mesmo tipo sobrescreve (último vence — composition root é o único chamador).
- `dispatch(command)`: busca o handler por `command.type`; tipo não registrado → `raise Harness::ValidationError, "command desconhecido: #{command.type}"` (aplicação da linha "Command Bus" do D4 — síncrono, nenhuma Task). Caso contrário `@handlers[command.type].call(command)`.
- Semântica de retorno (doc 03 §2): controle → resultado síncrono (Session, Task…); turno → `{ task_id: }` imediato. O bus **não** distingue as classes — é responsabilidade do handler; o bus só roteia.
- Sem lock/mutex: um reactor, fibers (doc 00 §5.5); `dispatch` não faz IO próprio.

#### Step 3: handler `CreateSession`

**File:** `lib/harness/commands/create_session.rb`

Payload (doc 03 §2): `{ vars: {} }` → retorna `Session`.

```ruby
module Harness
  module Commands
    class CreateSession
      def initialize(session_store:, event_stream:)

      def call(command)
        vars = command.payload[:vars] || command.payload["vars"] || {}
        raise ValidationError, "vars deve ser um Hash" unless vars.is_a?(Hash)

        session = @session_store.create(vars: vars)
        @event_stream.emit(Event.new(
          type: :session_created,
          data: { session_id: session.id },
          meta: { session_id: session.id, at: Time.now.utc.iso8601 }
        ))
        session
      end
    end
  end
end
```

- `:session_created { session_id }` é do catálogo fechado D5 (origem: "handler CreateSession").
- `meta` sem `task_id`/`seq` (Command de controle não tem Task); o `to_h` do Event (task 1) já faz `meta.compact`.
- `event_stream` aqui é *qualquer* objeto com `#emit(event)` — a classe real chega na task 10; nos testes use um spy.
- Aceitar chave simbólica **e** string no payload (o transporte HTTP do doc 07 entrega JSON parseado; normalizar na borda do handler).

#### Step 4: handler `CancelTask`

**File:** `lib/harness/commands/cancel_task.rb`

Payload (doc 03 §3): `{ task_id: String }` → retorna `Task`. Efeito (D3/doc 03 §4.1): "posta `:cancel` na mailbox mínima da Task". O cancelamento em si é **cooperativo** — quem transiciona o status é o fiber da task ao drenar a mailbox (doc 03 L2), nunca este handler.

```ruby
module Harness
  module Commands
    class CancelTask
      # executor: objeto com #running?(task_id) e #cancel(task_id) — a
      # implementação real chega na task 10; aqui é contrato (duck type).
      def initialize(task_store:, executor:)

      def call(command)
        task_id = command.payload[:task_id] || command.payload["task_id"]
        raise ValidationError, "task_id é obrigatório" if task_id.to_s.empty?

        task = @task_store.find(task_id)
        raise NotFoundError, "task '#{task_id}' não encontrada" unless task

        @executor.cancel(task_id)   # no-op se não há fiber vivo neste processo
        @task_store.find(task_id)   # estado corrente pós-post
      end
    end
  end
end
```

- Não transicionar status aqui e não mexer em `mailbox_state` persistido: a Fase 1 só usa a mailbox in-process (`Async::Queue`, task 10).
- Cancel de task sem fiber vivo (terminal ou órfã) é **no-op idempotente**: retorna a Task como está. Órfãs são território do `ResumeTask`/`Recovery` (doc 03 §3), não do cancel.

#### Step 5: requires em `lib/harness.rb`

Acrescentar, mantendo zero side-effects (doc 00 §3):

```ruby
require_relative "harness/command"
require_relative "harness/command_bus"
require_relative "harness/commands/create_session"
require_relative "harness/commands/cancel_task"
```

### Edge Cases to Handle

1. `Command.build` com `payload` `nil` → normaliza para `{}` (handler decide se campos obrigatórios faltam).
2. `dispatch` de tipo não registrado → `ValidationError` com o nome do tipo na mensagem (nunca `KeyError`/`NoMethodError`).
3. `CreateSession` com `vars` não-Hash (ex.: string vinda do JSON) → `ValidationError`.
4. `CancelTask` com `task_id` ausente, vazio ou não-String → `ValidationError`; inexistente → `NotFoundError` (D4: 422 vs 404 no doc 07).
5. Payload com chaves string (JSON do transporte) e com chaves símbolo (dispatch interno) — ambos funcionam nos dois handlers.
6. Cancel repetido da mesma task → segundo call também retorna a Task sem erro (idempotente).

## Testing

### Unit Tests

**File:** `spec/harness/command_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| build preenche meta | `Command.build(:cancel_task, {task_id: "x"})` | `command_id` UUID, `issued_at` ISO8601 UTC, `transport: :internal`, `tenant: nil` |
| build com overrides | `transport: :http, tenant: "acme"` | meta reflete os valores |
| type normalizado | `build("cancel_task", ...)` | `type == :cancel_task` (Symbol) |
| imutável | tentar `command.payload = {}` | `NoMethodError` (Data) |

**File:** `spec/harness/command_bus_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| register + dispatch | handler lambda que ecoa o command | `dispatch` retorna o resultado do handler |
| handler recebe o Command | spy | `#call` chamado com o próprio `Command` |
| tipo desconhecido | `dispatch(Command.build(:nope, {}))` | `Harness::ValidationError` com "nope" na mensagem |
| re-registro | registrar `:x` duas vezes | último handler vence |

**File:** `spec/harness/commands/create_session_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| cria sessão | payload `{vars: {"a" => 1}}` com `SessionStore` real sobre `Stores::Memory` | retorna `Session` com `vars` gravadas |
| payload vazio | `{}` | sessão criada com `vars == {}` |
| vars inválido | `{vars: "x"}` | `ValidationError` |
| emite evento | spy de event_stream | 1 `Event` `:session_created` com `data.session_id == session.id` e `meta.session_id` preenchido |
| chaves string | `{"vars" => {...}}` | funciona igual |

**File:** `spec/harness/commands/cancel_task_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| posta cancel | task `:running` no `TaskStore` real; executor = duplo | `executor.cancel` chamado com o `task_id`; retorna a Task |
| task inexistente | `{task_id: "ghost"}` | `NotFoundError`; `executor.cancel` NÃO chamado |
| task_id ausente/vazio | `{}` / `{task_id: ""}` | `ValidationError` |
| task terminal | task `:completed` | sem erro; retorna a Task inalterada (no-op) |
| idempotente | dois calls seguidos | ambos retornam Task, sem exceção |

### Integration Tests (if applicable)

Não nesta task — o fluxo Command→fiber→eventos é coberto na task 12 (integração `SendMessage`). Aqui os stores de domínio reais (`Memory`) + duplos de executor/event_stream bastam.

## Definition of Done

- [ ] `Command.build` preenche `command_id`/`issued_at`/`transport`/`tenant` conforme doc 03 §2
- [ ] `CommandBus#dispatch` roteia por tipo e levanta `ValidationError` para tipo desconhecido (D4, linha Command Bus)
- [ ] `CreateSession` cria via `SessionStore` e emite `:session_created` conforme D5
- [ ] `CancelTask` valida (`ValidationError`/`NotFoundError`), posta via `executor.cancel` e retorna `Task`
- [ ] Handlers de controle respondem síncrono, sem criar Task (doc 03 L1)
- [ ] Suíte roda **sem `ruby_llm` instalado** e sem API key (handoff §6)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Interface do executor no `CancelTask`:** o doc 03 §2 lista só `execute`/`running?` no Executor, mas o §4.1 exige "postar `:cancel` na mailbox" e o registro in-process de actors mora no Executor. O método `#cancel(task_id)` é a menor superfície que resolve isso — a task 10 o implementa (`@running[task_id]&.post(:cancel)`). Não é mudança de arquitetura, é o ponto de acesso ao registro que o próprio doc já prevê.
- **Cancel de task órfã (sem fiber vivo, status não-terminal):** o techspec não define comportamento; esta task adota no-op + retorno da Task (coerente com "postar em mailbox morta = nada acontece"). Se o produto precisar de cancel forçado de órfã, é decisão nova — registrar antes de implementar diferente.
- O `event_stream:` no construtor do bus (doc 03 §2) fica guardado sem uso ativo nesta task; handlers emitem por conta própria. Mantido para o contrato não mudar quando o bus precisar emitir (ex.: auditoria de dispatch, Fase 2).
- Convenções: `# frozen_string_literal: true` em todo arquivo; comentários em português; `Data.define` para value objects.
- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 21 novos (todos passando), 258 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/command_bus.rb`, `lib/harness/commands/create_session.rb`, `lib/harness/commands/cancel_task.rb`, `spec/harness/command_spec.rb`, `spec/harness/command_bus_spec.rb`, `spec/harness/commands/create_session_spec.rb`, `spec/harness/commands/cancel_task_spec.rb`
- **Arquivos modificados:** `lib/harness/command.rb` (estendido com `build`), `lib/harness.rb` (requires)
- **Observações / decisões tomadas:**
  - **Reuso, não recriação:** `lib/harness/command.rb` já existia (criado na task 08 para o Recovery). Estendi-o com o factory `Command.build` (doc 03 §2) em vez de recriar — o `Recovery` continua usando `Command.new(...)` sem quebra.
  - `CommandBus#dispatch` roteia por `command.type`; tipo desconhecido → `ValidationError` síncrono (nunca `KeyError`/`NoMethodError`). `event_stream:` guardado sem uso ativo (contrato p/ Fase 2).
  - Handlers de controle respondem síncrono, sem criar Task (doc 03 L1). Ambos aceitam payload com chave símbolo E string (borda do transporte HTTP).
  - `CancelTask` é cooperativo: posta via `executor.cancel(task_id)` (duck type, real na task 10); **não** transiciona status nem toca `mailbox_state` persistido. No-op idempotente para task terminal/órfã.
  - `CreateSession` emite `:session_created` (catálogo D5) via `event_stream.emit`.
  - `build` aceita `payload` posicional com default `{}` (além de normalizar `nil → {}`), pequena folga sobre a assinatura do doc para ergonomia; sem impacto no contrato.
