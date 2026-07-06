# Task 17: `Policy::Engine` + builtins `Tool/Skill/WorkflowAllowlist` (absorve `ToolRegistry#resolve`, fail-closed)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [05-policy-middleware-hooks.md](../05-policy-middleware-hooks.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Implementar o estágio 3 da pipeline: contrato de Policy (`Base`/`PolicyRequest`/`Decision`), o `Policy::Engine` com agregação determinística e fail-closed, e as três policies builtin (`ToolAllowlist`, `SkillAllowlist`, `WorkflowAllowlist`) que absorvem a lógica do `ToolRegistry#resolve` da Fase 0 — que vira atalho deprecated.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | ⬜ TODO |
| 14 | `ContextFragment`/`ContextProvider`/`Builder` (fan-out Async, orçamento global, pinned, evicção) | ⬜ TODO |

## Context

Doc 05 formaliza o princípio 9 da constituição (doc 00 §5.9): **Policy nega/filtra ANTES da execução, via `#decide` puro — sem IO, sem mutação** (doc 05 §1 e L1). Esta task entrega o estágio 3 completo (doc 05 §2-§4):

- O Executor (doc 03 §4, estágio 3) chamará `engine.decide(PolicyRequest[...])` com `candidate_tools: tool_registry.entries` (SEM filtrar) e `candidate_skills: skill_catalog.effective(profile.skills)` — **as skills candidatas vêm do CATÁLOGO, não do ContextPackage** (o pacote carrega texto formatado, não a lista estruturada — doc 05 §2, doc 03 §4). "Context antes de Policy" (RFC-0002 §5) é satisfeito porque `context` também está no `PolicyRequest`.
- O resultado (`Resolution`) alimenta `TurnState.allowed_tools/allowed_skills`; o Executor instancia SÓ as permitidas via factory — o modelo nunca enxerga tool negada (doc 05 §4, estilo Fase 0).
- Completa o item "Policy Engine (allow/deny) — parcial" do BACKLOG sem quebrar chamadores: `ToolRegistry#resolve` permanece como atalho deprecated que delega ao Engine com as builtins (doc 05 §8, doc 00 §4).

Depende da task 1 (`AgentProfile` com campos `policies`/`workflows_allow` — D6; `PolicyDenied` em `errors.rb` — D4) e da task 14 (o `context` do `PolicyRequest` é o `ContextPackage`; nos testes basta um duplo). O Policy Registry real chega na task 20 — aqui o Engine recebe qualquer objeto que resolva nome→policy (um `Hash` serve nos testes; ver Notes).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/policy/policy.rb` | `Policy::Base`, `PolicyRequest`, `Decision` + módulo `Builtin` com as três allowlists (layout doc 00 §3) |
| CREATE | `lib/harness/policy/engine.rb` | `Policy::Engine` + `Resolution`, agregação, audit, fail-closed, evento `:policy_denied` |
| CREATE (ou MODIFY, se a Etapa C já tiver migrado) | `lib/harness/tool_registry.rb` | migração do `tool_registry.rb` da Fase 0; `#resolve` vira atalho deprecated delegando ao Engine |
| MODIFY (se existir) | `config/wiring.rb` | trocar o duplo de `policy_engine` pelo Engine real com as builtins registradas |
| CREATE | `spec/harness/policy/policy_spec.rb` | contrato de `Decision` + builtins (inclui tabela de caracterização do `resolve`) |
| CREATE | `spec/harness/policy/engine_spec.rb` | agregação, empates, deny, fail-closed, audit |
| CREATE | `spec/harness/tool_registry_spec.rb` | registro/`names` + `resolve` deprecated com paridade Fase 0 |

### Step-by-Step Instructions

#### Step 1: Contratos — `Base`, `PolicyRequest`, `Decision`

**File:** `lib/harness/policy/policy.rb`

Implemente exatamente as interfaces do doc 05 §2 (com `# frozen_string_literal: true` e comentários em português, convenção da Fase 0):

- `Harness::Policy::Base` — classe com `def id = self.class.name` e `decide(request)` abstrato (levante `NotImplementedError`). Documentar no comentário: **PURA — sem IO, sem mutação** (L1; determinismo exigido pelo handoff §6).
- `PolicyRequest = Data.define(:profile, :command, :context, :candidate_tools, :candidate_skills)` — `candidate_tools` são `[ToolRegistry::Entry]`; `candidate_skills` são `[SkillCatalog::Skill]` obtidas de `catalog.effective(profile.skills)` pelo Executor (doc 05 §2).
- `Decision = Data.define(:allow_tools, :deny_tools, :allow_skills, :deny_skills, :verdict, :reason)`:
  - `verdict: :allow | :deny` (deny = nega o TURNO inteiro);
  - construtores: `Decision.allow(allow_tools: nil, deny_tools: [], allow_skills: nil, deny_skills: [])` (verdict `:allow`, reason `nil`) e `Decision.deny(reason:, **rest)` (verdict `:deny`);
  - semântica: `allow_* == nil` significa "sem restrição desta policy" (não entra na interseção); `[]` significa conjunto vazio; `deny_*` sempre é lista (união).

Tudo `Data` imutável — "a pureza da policy é estrutural, não só convenção" (doc 05 §3).

#### Step 2: Builtins — `ToolAllowlist`, `SkillAllowlist`, `WorkflowAllowlist`

**File:** `lib/harness/policy/policy.rb` (módulo `Harness::Policy::Builtin`, mesmo arquivo — o layout do doc 00 §3 só prevê `policy.rb` e `engine.rb`)

**`ToolAllowlist < Base`** — reproduz o `ToolRegistry#resolve` da Fase 0 como policy (doc 05 §2, L4). Lê `request.profile` e `request.candidate_tools`:

1. `deny_tools` = nomes de `candidate_tools` com `optional: true` **e** sem opt-in (`!profile.tool_opted_in?(name)`) — "optional sem opt-in → deny" — **mais** `Array(profile.tools_deny)` ("deny sempre vence");
2. `allow_tools` = `profile.tools_allow` conforme a semântica D6: `nil` → `nil` (todas, + opt-in das optional); `[]` → `[]` (conjunto vazio); `[names]` → conjunto final (não faz merge com defaults);
3. `verdict` sempre `:allow` (esta policy nunca nega o turno); `allow_skills: nil, deny_skills: []` (sem opinião sobre skills).

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/tool_registry.rb` — a lógica que migra):
```ruby
# Política aplicada ANTES da chamada ao modelo (estilo OpenClaw): o que
# sai daqui é exatamente o que o modelo enxerga.
def resolve(profile)
  selected = @entries.keys

  # optional exige opt-in
  selected = selected.select do |n|
    !@entries[n].optional || profile.tool_opted_in?(n)
  end

  # allow não-vazia = conjunto final
  allow = profile.tools_allow
  selected &= allow if allow && !allow.empty?

  # deny sempre vence
  selected -= Array(profile.tools_deny)

  selected.map { |n| @entries[n].factory.call }
end
```

E o opt-in em `agent_profile.rb` (Fase 0 — mantido em D6):
```ruby
# opt-in de tool optional = estar na allow do agente.
def tool_opted_in?(name)
  Array(tools_allow).include?(name)
end
```

**`SkillAllowlist < Base`** — reproduz a semântica `nil`/`[]`/`[names]` de `profile.skills` (doc 05 §2): `allow_skills` = `nil` se `profile.skills.nil?`; `[]` se vazio; a lista de nomes caso contrário. `deny_skills: []`, tools sem opinião, `verdict :allow`. O `SkillCatalog#effective` **permanece no catálogo** (é consulta); a **decisão** de usá-lo é desta policy (doc 05 §8) — como as candidatas já vêm de `effective`, a policy é idempotente sobre elas, mas torna a decisão auditável e extensível.

**`WorkflowAllowlist < Base`** — enforcement do campo `workflows_allow` (D6): "sem ela, D6 declararia política sem executor" (doc 05 §2).

- Se `request.command.type != :trigger_workflow` → `Decision.allow` (neutra);
- Senão, extraia o nome do workflow de `request.command.payload` (chave `:workflow` — doc 03 §3) e aplique a mesma semântica: `workflows_allow == nil` → allow; `[]` ou lista que não contém o nome → `Decision.deny(reason: "workflow '<nome>' fora da allowlist do agente '<profile.id>'")`. Deny de workflow nega o TURNO (verdict `:deny`).

#### Step 3: `Policy::Engine` + `Resolution`

**File:** `lib/harness/policy/engine.rb`

Interface do doc 05 §2:

```ruby
class Engine
  Resolution = Data.define(:allowed_tools, :allowed_skills, :audit)

  def initialize(policy_registry:, event_stream:)
  def decide(request) # -> Resolution | raise PolicyDenied
end
```

Comportamento (doc 05 §3, semântica de agregação — determinística):

1. Resolva as policies de `request.profile.policies` **na ordem declarada** (não há pesos) via `policy_registry` (objeto que responde a `fetch(name)`; ver Notes). Nome não registrado → tratar como crash (passo 3).
2. Para cada policy, chame `decision = policy.decide(request)` e acrescente `{policy: policy.id, verdict: decision.verdict, reason: decision.reason}` ao `audit`.
3. **Fail-closed (L2):** policy que **levanta exceção** (bug) é tratada como `deny` com `reason: "policy crash: <classe da exceção>"` — nunca fail-open.
4. Qualquer `verdict :deny` → registre no audit, emita `Event` `:policy_denied` com `data: { policy:, reason: }` no `event_stream` (D5 — a origem do evento é o Policy Engine) e levante `PolicyDenied` (D4, com `policy` e `reason`). **Primeiro deny reporta; as policies seguintes nem rodam — mas o audit registra até onde foi.**
5. Sem deny, agregue (L3 — comutativa, "empate impossível por construção: conjuntos, não escolha"):
   - `nomes_permitidos = nomes(candidatas) ∩ (∩ allows não-nil) − (∪ denies)` — interseção de allows, união de denies; idem para skills;
   - `allowed_tools` = subconjunto de `request.candidate_tools` (as `Entry`, para o Executor instanciar via factory — doc 05 §4) cujos nomes estão em `nomes_permitidos`; `allowed_skills` = subconjunto análogo de `candidate_skills` por `name`.
6. Retorne `Resolution.new(allowed_tools:, allowed_skills:, audit:)`. O `audit` é a trilha para evento e Control UI (doc 05 §2).

Policies rodam **inline no fiber da task, sem fan-out e sem timeout próprio** (doc 05 §5 — puras, sem IO). Não use `Async` aqui.

#### Step 4: `ToolRegistry` — `resolve` vira atalho deprecated

**File:** `lib/harness/tool_registry.rb`

Migre o arquivo da Fase 0 para o namespace `Harness` (D1), mantendo `Entry = Data.define(:name, :optional, :plugin, :factory)`, `register`, `names` intactos, e adicione `entries` (lista de `Entry` — é o que o Executor passa como `candidate_tools`, doc 03 §4). Se a Etapa C já tiver migrado o arquivo, apenas modifique `resolve`.

`#resolve(profile)` (doc 05 §8): mantém a assinatura e o retorno da Fase 0 (array de **instâncias** de tool), mas:

1. emite `warn "[DEPRECATION] ToolRegistry#resolve: use Policy::Engine#decide (doc 05 §8)"` (uma vez por processo é suficiente);
2. delega ao Engine com a builtin: monte um `Engine` com um registry mínimo contendo `ToolAllowlist` (um `Hash` literal serve) e um event_stream nulo (objeto com `emit` no-op — o atalho não participa da pipeline de eventos), `PolicyRequest` com `candidate_tools: entries`, `candidate_skills: []`, `command: nil`, `context: nil`;
3. mapeie `resolution.allowed_tools.map { |e| e.factory.call }`.

Assim o BACKLOG "Policy Engine — parcial" é completado **sem quebrar chamadores** (doc 05 §8).

#### Step 5: Wiring (se aplicável)

**File:** `config/wiring.rb`

Se a Etapa C já tiver criado o composition root com um duplo de `policy_engine`, substitua pelo real: registre as builtins sob nomes canônicos (`"tool_allowlist"`, `"skill_allowlist"`, `"workflow_allowlist"`) no objeto que faz papel de Policy Registry até a task 20, e construa `Policy::Engine.new(policy_registry:, event_stream:)`. Caso contrário, pule — a task 20/21 fará o registro definitivo.

### Edge Cases to Handle

1. **Interseção vazia não é erro:** duas policies com allows disjuntos → `Resolution` com zero tools; o turno segue sem tools (doc 05 §7).
2. **`allow nil` não restringe:** allow `nil` + allow `[a,b]` → `[a,b]` (só allows não-nil entram na interseção).
3. **Deny vence allow em todas:** tool presente em todos os allows mas em um deny → excluída.
4. **Primeiro deny de turno interrompe:** policies posteriores não são avaliadas; audit contém as já avaliadas + a que negou.
5. **Policy crash → fail-closed:** exceção vira deny do turno com `reason: "policy crash: <classe>"`; nunca libera por omissão (L2).
6. **Nome de policy não registrado:** tratar como crash (fail-closed) — ver Notes.
7. **`profile.policies` vazio/nil:** nenhuma policy → todas as candidatas passam (`Resolution` = candidatas; audit vazio). É o comportamento neutro — a restrição vem das builtins declaradas no perfil (default D6: `ToolAllowlist` + `SkillAllowlist`).
8. **`tools_allow: []` (divergência Fase 0 × D6):** a Fase 0 tratava `[]` como "sem restrição" (`selected &= allow if allow && !allow.empty?`); D6 fixa `[] = ∅` para allow, uniforme com skills/providers/workflows. Siga D6; ver Notes.
9. **`WorkflowAllowlist` em command que não é workflow:** neutra (`Decision.allow`), inclusive quando `command` é `nil` (caso do `resolve` deprecated).
10. **Candidatas com nomes String vs Symbol:** normalize nomes com `to_s` antes de interseção/subtração (a Fase 0 usa `name.to_s` no register).

## Testing

### Unit Tests

**File:** `spec/harness/policy/engine_spec.rb` (casos de empate e negação — doc 05 §7, handoff §6)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| allows disjuntos | policy A allow `[x]`, policy B allow `[y]`, candidatas `[x,y]` | `allowed_tools == []` (vazio, não erro) |
| allow nil + allow [a,b] | nil não entra na interseção | `allowed_tools` com nomes `[a,b]` |
| deny vence | allow `[a,b]` em todas, deny `[a]` em uma | só `b` |
| primeiro deny interrompe | policy 1 allow, policy 2 deny (verdict), policy 3 com spy | `PolicyDenied` levantado; policy 3 nunca chamada; audit tem 2 entradas |
| evento :policy_denied | deny de turno | `event_stream` recebe `Event(:policy_denied, {policy:, reason:})` antes do raise |
| audit completo | 3 policies allow | `resolution.audit` com 3 entradas `{policy:, verdict:, reason:}` na ordem |
| fail-closed | policy cujo `decide` levanta `RuntimeError` | `PolicyDenied` com `reason` contendo `"policy crash: RuntimeError"` |
| policies vazio | `profile.policies == []` | Resolution = todas as candidatas, audit vazio |
| ordem de avaliação | spies registram ordem | ordem de `profile.policies`, não do registry |
| skills agregadas | allow_skills interseção/união análoga | subconjunto correto de `candidate_skills` |

**File:** `spec/harness/policy/policy_spec.rb` (builtins; a tabela de caracterização do `resolve` da Fase 0 — doc 05 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| required sempre entra | registry `{a: required}`, allow nil, deny [] | `a` permitida |
| optional sem opt-in | registry `{b: optional}`, allow nil | `b` em `deny_tools` (negada) |
| optional com opt-in | allow `[b]`, `b` optional | `b` permitida |
| allow não-vazia = conjunto final | registry `{a,b}` required, allow `[a]` | só `a` (sem merge com defaults) |
| deny sempre vence | allow `[a]`, deny `[a]` | nenhuma |
| allow `[]` (D6) | allow `[]` | nenhuma tool (∅ — divergência documentada da Fase 0; ver Notes) |
| SkillAllowlist nil/[]/[names] | os três casos de `profile.skills` | `allow_skills` = nil / [] / [names] |
| WorkflowAllowlist allow | `workflows_allow: ["w1"]`, command trigger_workflow `w1` | `Decision.allow` |
| WorkflowAllowlist deny | `workflows_allow: []` ou lista sem o nome | `Decision.deny` com reason citando o workflow |
| WorkflowAllowlist neutra | command `:send_message` (ou nil) | `Decision.allow` |
| pureza | `decide` chamado 2× com o mesmo request | mesmo resultado (determinismo, handoff §6) |

**File:** `spec/harness/tool_registry_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| register/names/entries | registra por klass e por block | `names` e `entries` corretos; factory devolve a tool |
| resolve deprecated — paridade | mesmos cenários da tabela de caracterização | mesmas instâncias que a Fase 0 devolveria (exceto caso `allow []`, D6) |
| resolve emite deprecation | captura `warn` | mensagem de deprecation presente |

`command`/`context` nos testes são duplos simples (`Data.define(:type, :payload)` local ou `instance_double`) — a task 9/14 não precisa estar pronta. **Tudo puro — zero RubyLLM, zero IO** (doc 05 §7).

## Definition of Done

- [ ] `Policy::Base`, `PolicyRequest`, `Decision` (com `.allow`/`.deny`) conforme doc 05 §2, tudo `Data` imutável
- [ ] `Engine#decide` agrega por interseção de allows/união de denies (L3), primeiro deny interrompe com `PolicyDenied` + evento `:policy_denied`, audit completo
- [ ] Crash de policy e nome não registrado → fail-closed (L2)
- [ ] `ToolAllowlist` passa a tabela de caracterização do `ToolRegistry#resolve` da Fase 0 (com a divergência `allow []` documentada por D6)
- [ ] `SkillAllowlist` e `WorkflowAllowlist` com semântica `nil`/`[]`/`[names]` uniforme (D6)
- [ ] `ToolRegistry#resolve` mantido como atalho deprecated que delega ao Engine (retorno compatível com a Fase 0)
- [ ] Nenhum `Async`, nenhum IO em `lib/harness/policy/` (doc 05 §5, L1)
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Policy Registry ainda não existe** (task 20, Etapa F — não é dependência desta). O Engine deve exigir apenas o duck-type `fetch(name)`; nos testes e no `resolve` deprecated um `Hash` basta. A task 20 pluga o `Registry` real sem mudar o Engine.
- **Divergência Fase 0 × D6 em `tools_allow: []`:** o código da Fase 0 ignora allow vazia (`if allow && !allow.empty?` ⇒ sem restrição); D6 fixa `[] = ∅` para unificar a semântica de allowlist ("uma regra só, testada uma vez"). Esta task segue D6 e o teste de caracterização marca o caso como divergência intencional — não é regressão.
- **Nome de policy não registrado → fail-closed** é interpretação local de L2 (o doc 05 só cobre crash de `decide`); registrar config inexistente liberar o turno seria fail-open. Se o revisor preferir `ValidationError` síncrono, ajustar aqui e no teste.
- **Lacuna observada:** o default de `profile.policies` (doc 05 §8 / D6) é `[ToolAllowlist, SkillAllowlist]` — a `WorkflowAllowlist` NÃO está no default. Um perfil que declare `workflows_allow` sem incluir `workflow_allowlist` em `policies` não terá enforcement. O wiring (task 20/21/23) deve incluí-la para agentes com workflows; registrado aqui para não passar batido.
- O formato exato dos elementos de `profile.policies` (nomes String vs classes) foi definido na task 1/D6 como **nomes no Policy Registry** — confirme no código real de `agent_profile.rb` ao implementar.
- A integração do Engine no estágio 3 do Executor é exercitada de verdade na task 23 (`TriggerWorkflow`) e no wiring; aqui basta o contrato standalone + a substituição do duplo se o Executor já existir.
