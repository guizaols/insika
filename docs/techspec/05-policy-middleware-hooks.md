# Techspec 05 — Policy Engine + Middleware + Lifecycle Hooks

> Implementa os estágios 3 e 4 da pipeline e os wrappers before/after
> (RFC-0002 §4, §6). Formaliza o princípio 9 da constituição: **Middleware
> modifica, Hooks alteram, Events observam** — três papéis, três interfaces.

## 1. Objetivo e fronteira

A fronteira formal entre os três papéis (referida pelo doc 00 §5.9):

| Papel | Pode | Não pode | Interface |
|-------|------|----------|-----------|
| **Policy** | negar/filtrar ANTES da execução | modificar estado, ter efeito colateral | `#decide` puro |
| **Middleware** | modificar o TurnState, curto-circuitar, ter efeito operacional (rate limit, tracing, custo) | decidir permissão de tool/skill (isso é Policy) | cadeia `#call(state, &next)` |
| **Hook** | alterar entrada/saída de UM estágio que envolve | criar fluxo próprio, pular estágios | pares `before_X`/`after_X` |
| **Event** | observar | tudo o mais | `EventStream` (doc 03) |

**Faz:** `Policy::Engine` + contrato de Policy + policies builtin
(tool/skill/workflow allow-deny — absorve a lógica do `ToolRegistry#resolve`
e do `SkillCatalog#effective` como policies); pipeline de Middleware; `Hooks`
com os quatro pares da RFC-0002 §6.

**Não faz:** policies de custo/aprovação/tenant (Fase 2 — BACKLOG); auth de
transporte (doc 07); registro dinâmico via plugin (doc 06 fornece o Registry;
aqui só o contrato).

## 2. Interfaces públicas

```ruby
module Harness
  module Policy
    class Base
      def id = self.class.name
      # PURA: sem IO, sem mutação (determinismo testável — handoff §6).
      def decide(request)            # -> Decision
      # request: PolicyRequest (abaixo)
    end

    PolicyRequest = Data.define(:profile, :command, :context,
                                :candidate_tools, :candidate_skills)
    # candidate_tools:  [Entry] do ToolRegistry (nome, optional, plugin)
    # candidate_skills: [Skill] — o Executor as obtém de
    #                   skill_catalog.effective(profile.skills) (doc 03 §4,
    #                   estágio 3); o ContextPackage NÃO é a fonte (ele traz o
    #                   texto formatado). "Context antes de Policy" (RFC-0002
    #                   §5) é satisfeito porque `context` também está aqui —
    #                   a política vê o pacote montado ao decidir.

    Decision = Data.define(:allow_tools, :deny_tools,
                           :allow_skills, :deny_skills, :verdict, :reason) do
      # verdict: :allow | :deny  (deny = nega o TURNO inteiro)
      def self.allow(...) ; def self.deny(reason:, ...)
    end

    class Engine
      def initialize(policy_registry:, event_stream:)
      # Avalia profile.policies (D6) em ordem; agrega decisões:
      #   qualquer verdict :deny → PolicyDenied (deny vence, determinístico)
      #   tools  = candidatas ∩ allows − denies
      #   skills = idem
      def decide(request)            # -> Resolution | raise PolicyDenied
      Resolution = Data.define(:allowed_tools, :allowed_skills, :audit)
      # audit: [{policy:, verdict:, reason:}] — trilha p/ evento e Control UI
    end

    module Builtin
      class ToolAllowlist < Base
        # Reproduz ToolRegistry#resolve da Fase 0, agora como policy:
        #   optional sem opt-in → deny; allow não-vazia → conjunto final;
        #   deny sempre vence. Fonte: profile.tools_allow/tools_deny.
      end
      class SkillAllowlist < Base
        # Reproduz a semântica nil/[]/[names] de profile.skills.
      end
      class WorkflowAllowlist < Base
        # Aplica profile.workflows_allow (D6) em commands trigger_workflow:
        # workflow fora da allowlist → Decision.deny. Mesma semântica
        # nil/[]/[names]. É o enforcement do campo — sem ela, D6 declararia
        # política sem executor.
      end
    end
  end

  class Middleware                    # elo da cadeia (estágio 4)
    def call(state, &nxt)             # state: TurnState (doc 03 §3, mutável L5)
      nxt.call(state)                 # elo default: pass-through
    end
  end

  class MiddlewareStack
    def initialize(middlewares = [])  # ordem de registro = ordem de execução
    def call(state, &terminal)        # composição rack-like; curto-circuito =
                                      # não chamar nxt (deve setar state.halt_reason)
  end

  class Hooks
    PAIRS = %i[task prompt agent tool].freeze   # RFC-0002 §6
    def register(pair, before: nil, after: nil) # callables; múltiplos por par
    def around(pair, subject)                    # -> resultado do bloco
    #   befores na ordem de registro (podem ALTERAR subject retornando o novo),
    #   yield(subject), afters na ordem INVERSA (podem alterar o resultado).
  end
end
```

## 3. Modelos de dados / schemas

- `Decision`/`Resolution`/`PolicyRequest`: acima. Tudo `Data` imutável — a
  pureza da policy é estrutural, não só convenção.
- Semântica de agregação do Engine (determinística, testável em caso de
  empate — handoff §6):
  1. policies avaliadas na ordem de `profile.policies` (não há pesos);
  2. um `deny` de turno em qualquer policy → `PolicyDenied` imediato com
     `policy` e `reason` (primeiro deny reporta; os demais nem rodam — mas o
     audit registra até onde foi);
  3. para tools/skills: `candidatas ∩ (∩ allows não-nil) − (∪ denies)` —
     interseção de allows, união de denies; **empate impossível por
     construção** (conjuntos, não escolha).
- `TurnState.halt_reason`: campo do TurnState (classe mutável, doc 03 §3)
  escrito pelo elo que curto-circuita → task `:failed` com o motivo (ex.:
  rate limit), evento `:error`.

## 4. Fluxo de controle

```
estágio 3 (doc 03 §4):
  candidatas = tool_registry.entries (SEM filtrar) + skills do contexto
  resolution = engine.decide(PolicyRequest[...])
    ├─ PolicyDenied → evento :policy_denied {policy, reason} → task :failed
    └─ Resolution   → TurnState.allowed_tools/allowed_skills
                      (o Executor instancia SÓ as permitidas via factory —
                       o modelo nunca enxerga tool negada, estilo Fase 0)

estágio 4:
  middleware_stack.call(turn_state) { |state| ...estágios 5-9... }
    └─ halt → task :failed(halt_reason), sem tocar RubyLLM

wrappers (todos os estágios): hooks.around(:task/:prompt/:agent/:tool, subject)
```

Ordem constitucional preservada: Context (2) → Policy (3) → Middleware (4) —
"autorização antes de efeitos operacionais" (RFC-0002 §5).

## 5. Concorrência

- Policies: puras e síncronas — rodam inline no fiber da task, sem fan-out
  (decisão em L1). Sem IO ⇒ sem timeout próprio.
- Middleware: roda no fiber da task; um middleware que faça IO (ex.: tracing
  exporter) deve fazê-lo async fora do caminho (`Async { ... }` fire-and-forget)
  ou aceitar a latência no turno — documentado no contrato.
- Hooks: síncronos por definição (alteram o subject do estágio); hook lento
  atrasa o estágio que envolve e é coberto pelo timeout do turno (D4).

## 6. Erros e timeouts

- `PolicyDenied` (D4): terminal, não-retry-ável, evento `:policy_denied`.
  Policy que **levanta exceção** (bug) → tratada como `deny` com
  `reason: "policy crash: <classe>"` — fail-closed, nunca fail-open.
- Exceção em middleware → falha do turno (D4, linha Middleware); sem retry.
- Exceção em hook `before_X` → falha do estágio envolvido (propaga conforme o
  estágio); em `after_X` → idem, mas o estágio já executou — o erro é
  reportado e o turno falha **sem** reexecutar o estágio (side-effects já
  aconteceram).
- Sem timeouts próprios: cobertos pelo timeout de turno.

## 7. Estratégia de testes

- **Engine — casos de empate e negação (handoff §6):** duas policies com
  allows disjuntos → interseção vazia (nenhuma tool, não erro); allow nil +
  allow [a,b] → [a,b]; deny em uma vence allow em todas; primeiro deny de
  turno interrompe; audit completo; policy que levanta → fail-closed.
- **Builtin vs Fase 0 (caracterização):** `ToolAllowlist` reproduz
  byte-a-byte a tabela de casos do `ToolRegistry#resolve` (required/optional/
  opt-in/allow-final/deny-vence) — os testes da Fase 0 são portados como
  estão antes de remover o `resolve`.
- **MiddlewareStack:** ordem de execução; curto-circuito não chama estágios
  seguintes (terminal spy); modificação de state visível ao próximo elo.
- **Hooks:** ordem before (registro) / after (inversa); alteração de subject
  propagada; exceção em after não reexecuta o estágio (spy de contagem).
- Tudo puro — zero RubyLLM, zero IO.

## 8. Evolução a partir da Fase 0

- `ToolRegistry#resolve` → a **lógica migra** para `Policy::Builtin::
  ToolAllowlist`; o registry mantém `resolve` como atalho deprecated que
  delega ao Engine com as builtin (BACKLOG marca o Policy Engine da Fase 0
  como "parcial" — isto o completa sem quebrar chamadores).
- `SkillCatalog#effective` → permanece no catálogo (é consulta de catálogo),
  mas a **decisão** de usá-lo vira `SkillAllowlist`; o provider Skill (doc 04)
  passa a receber as skills já decididas? **Não** — ordem constitucional é
  Context→Policy: o provider produz com `effective` (visão candidata) e a
  policy corta depois. O `LoadSkill` recebe `resolution.allowed_skills`
  (doc 03 §4.2).
- `agent_profile.rb` → campos novos `policies` (default
  `[ToolAllowlist, SkillAllowlist, WorkflowAllowlist]` — as três builtin;
  sem a terceira no default, `workflows_allow` ficaria sem enforcement por
  omissão) já previstos em D6.

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Policies puras e síncronas (sem IO) na Fase 1 | determinismo exigido pelo handoff §6; policy com IO (quota em store) entra na Fase 2 com contrato async explícito |
| L2 | Fail-closed em crash de policy | política que quebra não pode liberar por omissão; segurança > disponibilidade neste estágio |
| L3 | Interseção de allows / união de denies | única agregação sem ordem-dependência entre policies (comutativa) — elimina a classe inteira de bugs de precedência |
| L4 | Builtin allowlists como policies (não hard-code no registry) | completa o "parcial" do BACKLOG e torna a semântica extensível por plugin sem tocar no núcleo |
| L5 | Middleware não decide permissão | fronteira do princípio 9; sem isso Policy e Middleware colapsam num estágio só e a auditoria perde sentido |
| L6 | `after_X` com falha não reexecuta o estágio | side-effects do estágio já ocorreram; reexecutar violaria a idempotência que o checkpoint assume (doc 02) |
