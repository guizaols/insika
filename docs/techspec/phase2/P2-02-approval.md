# P2-02 — Human-in-the-loop: `PendingAction` + policy `ApprovalRequired` + `ApproveAction`

> **RFC base:** 0002 §9 (mailbox `approval`), 0007 §3 (tela Tasks, aprovar/rejeitar).
> **Evolui:** `lib/harness/tool_envelope.rb`, `lib/harness/policy/policy.rb`,
> `lib/harness/agent_profile.rb`, `lib/harness/commands/`. **Overview:** D2, D3.

## Objetivo

Fechar o elo que a Fase 1 só sabia negar (`PolicyDenied`): uma tool sensível
**pausa o turno para aprovação humana** em vez de negar/executar. A decisão é
enforcement de Policy (D3); o estado é um **record durável** (D2); a retomada
usa a mailbox `:approval` (P2-01) e o caminho do `ResumeTask` (D3 da Fase 1).

## Fluxo

```
estágio 3 (Policy): ApprovalRequired marca a tool "X" como needs_approval p/ o agente
estágio 6 (tool X é chamada pelo loop RubyLLM):
  ToolEnvelope#call, tool marcada:
    1. cria PendingAction (task, turn, tool, args, requested_at)      [durável]
    2. emit :approval_requested { pending_id, tool, args }
    3. transita a task -> :waiting; BLOQUEIA o fiber (actor.await(:approval))
  --- turno suspenso; sobrevive a kill -9 (PendingAction + task :waiting no store) ---
operador (via /admin ou API): POST ApproveAction { pending_id, decision: approved|rejected }
  handler: resolve o PendingAction (decision, resolved_by, resolved_at)
           posta :approval(payload) na mailbox do actor -> resolve o await
  de volta no ToolEnvelope:
    approved -> executa __getobj__.call(args), registra side-effect, devolve resultado ao modelo
    rejected -> devolve { error: "rejected by operator" } ao modelo (turno segue)
  emit :approval_resolved { pending_id, decision, resolved_by }
```

## Decisões

### L1 — `ApprovalRequired` é uma builtin de Policy (não caminho novo)
Espelha `ToolAllowlist` (Fase 1). Lê `profile.approvals_required` (nil = nenhuma;
`[names]` = essas tools exigem aprovação). Não NEGA nem PERMITE sozinha — anexa
`requires_approval: [names]` à `Resolution`. O gate real é no Envelope (estágio
6), onde a call acontece. Assim Policy continua pura/síncrona (doc 05 L1).

### L2 — O gate vive no `ToolEnvelope`, onde a call realmente ocorre
O Envelope já é o ponto que intercepta cada call (timeout, side-effect). Ganha a
checagem de aprovação **antes** de `__getobj__.call`. Isso mantém o loop do
RubyLLM intacto (a call só "demora" — o fiber bloqueia esperando o operador). O
Envelope recebe as `requires_approval` da Resolution + um handle da mailbox
(via `state`) para bloquear/retomar.

### L3 — `PendingAction` é RECORD durável (D2), não flag
Store de domínio próprio (`PendingActionStore`) sobre `Harness::Store`, chave
`pending:<task_id>:<seq>`. Sobrevive a `kill -9`: no reboot, o recovery reidrata
a task em `:waiting` e o `PendingAction` ainda está aberto — o operador aprova
depois. Um `PendingAction` = uma call que espera; append-only + resolução
in-place do status.

### L4 — Retomada de aprovação = mailbox `:approval`, não novo turno
`ApproveAction` NÃO reexecuta o turno; resolve o `PendingAction` e posta
`:approval` no actor vivo (se houver). Se o processo caiu (sem actor vivo), o
`ApproveAction` resolve o record e o **recovery/ResumeTask** reexecuta o turno do
checkpoint — e o Envelope, na reexecução, vê o `PendingAction` já resolvido e
**pula a espera** (usa a decisão registrada). Idempotente e crash-safe.

### L5 — `rejected` volta ao modelo como erro de tool (turno não falha)
Rejeição não é falha do turno: o modelo recebe `{ error: "rejected by operator" }`
(mesmo protocolo do timeout de tool na Fase 1) e decide o que fazer. Só um
`:approval_timeout` (P2-01 L4) leva a task a `:failed`.

## Interfaces

### `PendingActionStore`
```ruby
PendingAction = Data.define(:id, :task_id, :turn, :tool, :args,
                            :status, :requested_at, :resolved_by, :resolved_at)
# status ∈ %i[pending approved rejected]
create(task_id:, turn:, tool:, args:) -> PendingAction   # status :pending
find(id) -> PendingAction | nil
open_for(task_id:) -> [PendingAction]                    # status :pending (recovery/UI)
resolve(id, decision:, operator:) -> PendingAction       # :pending -> :approved|:rejected
```

### Policy builtin
```ruby
module Harness::Policy::Builtin
  class ApprovalRequired < Base
    def decide(request)
      names = request.profile.approvals_required
      Decision.allow(requires_approval: names.nil? ? [] : Array(names).map(&:to_s))
    end
  end
end
```
(`Decision`/`Resolution` ganham o campo aditivo `requires_approval`.)

### `AgentProfile`
Novo campo `approvals_required` (nil default; semântica allowlist como os demais).

### Command `ApproveAction` (controle)
```ruby
# payload { pending_id:, decision: "approved"|"rejected" }, meta traz o operador (D6)
# valida (ValidationError se pending_id/decision ausentes; NotFoundError se o record sumiu)
# resolve o PendingAction + posta :approval(decision) no actor (no-op se não há fiber vivo)
# -> PendingAction resolvido (200)
```

### `ToolEnvelope` (gate)
```ruby
def call(args)
  return skipped if already_executed?           # Fase 1 (side-effect skip)
  if approval_required?                          # nome ∈ state.requires_approval
    decision = ensure_approval(args)             # cria/consulta PendingAction; bloqueia se :pending
    return { error: "rejected by operator" } if decision == :rejected
  end
  # ... timeout + side-effect + __getobj__.call (inalterado)
end
```
`ensure_approval`: se já há `PendingAction` resolvido para esta call (reexecução
pós-aprovação/crash) → retorna a decisão sem bloquear; senão cria, emite
`:approval_requested`, transita `:waiting`, `state.actor.await(:approval)`.

## Files to Touch

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| CREATE | `lib/harness/pending_action_store.rb` | store de domínio (D2/L3) |
| MODIFY | `lib/harness/policy/policy.rb` | builtin `ApprovalRequired`; campo `requires_approval` em `Decision` |
| MODIFY | `lib/harness/policy/engine.rb` | agregar `requires_approval` na `Resolution` |
| MODIFY | `lib/harness/agent_profile.rb` | campo `approvals_required` |
| MODIFY | `lib/harness/tool_envelope.rb` | gate de aprovação (L2); recebe `requires_approval` + actor/pending_store via `state` |
| MODIFY | `lib/harness/executor.rb` | injeta `requires_approval`/`pending_store` no estado; transição `:waiting`; wiring do `:approval_timeout` |
| MODIFY | `lib/harness/turn_state.rb` | expõe `requires_approval`, `pending_store`, `actor` ao Envelope |
| CREATE | `lib/harness/commands/approve_action.rb` | Command (L4) |
| MODIFY | `lib/harness.rb` | requires |
| MODIFY | catálogo D5 | `:approval_requested`, `:approval_resolved` |
| CREATE | `spec/harness/pending_action_store_spec.rb` | + shared contract de store |
| CREATE | `spec/harness/policy/approval_required_spec.rb` | allowlist de aprovação |
| CREATE | `spec/harness/tool_envelope_approval_spec.rb` | bloqueia/retoma; rejected→erro; reexecução usa decisão registrada |
| CREATE | `spec/harness/commands/approve_action_spec.rb` | resolve + posta `:approval`; crash-safe |

## Edge Cases

1. **Aprovar um `pending_id` já resolvido** → NotFoundError/idempotente (só
   resolve `:pending`).
2. **`kill -9` entre criar o PendingAction e suspender** → checkpoint inicial do
   turno existe; recovery reexecuta; Envelope recria/encontra o PendingAction
   `:pending` → re-suspende. Sem dupla execução da tool (ela nunca rodou).
3. **`kill -9` DEPOIS de aprovar mas ANTES de executar a tool** → PendingAction
   `:approved` durável; recovery reexecuta; Envelope vê `:approved` → executa
   direto (sem re-suspender). A tool ainda não rodou → sem dupla execução.
4. **Aprovar tool side-effect que JÁ rodou** (reexecução) → o skip de side-effect
   da Fase 1 (`already_executed`) vence antes do gate. União segura.
5. **Rejeição** → `{error: rejected}` ao modelo; turno segue (L5).
6. **`approval_timeout`** → `:waiting` além do teto → `:timeout` (P2-01) →
   `:failed` stage `:approval_timeout`; o PendingAction fica `:pending` (auditável).
7. **Workflow (trigger_workflow) chamando tool com aprovação** → mesmo gate (o
   Envelope é o mesmo); a limitação de correlação por-nome (Fase 1) se aplica.

## Testing (resumo)
- Store: contrato compartilhado + `open_for`/`resolve` transições.
- Policy: `approvals_required` nil/[]/[names] → `requires_approval` correto.
- Envelope: com FakeChat + gate, tool marcada bloqueia; `:approval(approved)`
  libera e executa; `:approval(rejected)` → erro ao modelo; reexecução com
  PendingAction resolvido não re-bloqueia.
- ApproveAction: resolve o record + posta na mailbox; sem fiber vivo → só resolve
  (recovery reexecuta).
- Tudo sem `ruby_llm`/chave.
