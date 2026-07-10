# Task 20: `Registry` genérico + Workflow/Policy Registries + `PromptCatalog` (PROMPT.md)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [06-registries-plugin-autodiscovery.md](../06-registries-plugin-autodiscovery.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Criar a base executável `Harness::Registry` (Entry com `metadata`, duplicata primeiro-vence com warn, `NotFoundError`), fazer `ToolRegistry` re-herdar dela (com `side_effect` no metadata), criar `WorkflowRegistry` e `PolicyRegistry`, e criar o `PromptCatalog` (convenção `PROMPT.md` espelhando `SKILL.md`).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 1 | Migrar tipos base: `errors.rb`, `event.rb` (+meta), `agent_profile.rb` (+4 campos), `token_estimator.rb` | ⬜ TODO |

(Grafo do tasks.md: `20 → 1`. A task 20 pode andar em paralelo à Etapa C.)

## Context

Doc 06 §1-§2: o RFC-0001 princípio 6 (reafirmado no doc 00 §5.6) separa **Registry** (conteúdo executável — tools, workflows, policies) de **Catalog** (conteúdo não-executável — skills, prompts). A Fase 0 só tem o `ToolRegistry`; esta task generaliza sua estrutura num `Registry` base e adiciona os que faltam:

- `WorkflowRegistry` — consumido pelo estágio 6 do `TriggerWorkflow` (doc 03 §4.1, task 23);
- `PolicyRegistry` — consumido na montagem do `Policy::Engine` (doc 05 §2, task 17);
- `PromptCatalog` — fonte do provider `Prompt` quando um perfil usa `prompt_refs` (doc 04 §2, task 15 — que aceita `catalog: nil` até esta task chegar);
- `ToolRegistry` re-herdado, com `metadata` absorvendo `optional:` e ganhando `side_effect: false` (novo — doc 02 §3, RFC-0006 §5: tools declaram não-idempotência no registro; o checkpoint consome essa flag).

É a porta de entrada da Etapa F: a task 21 (Plugin::Loader) preenche estes registries.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/registry.rb` | Base executável genérica (doc 06 §2) |
| CREATE | `lib/harness/tool_registry.rb` | Herda do genérico; `optional`/`side_effect` no metadata; `resolve` de perfil deprecated (doc 06 §8, doc 05 §8) |
| CREATE | `lib/harness/workflow_registry.rb` | Registry de workflows (callable `#call(input, context:, tools:)`) |
| CREATE | `lib/harness/policy_registry.rb` | Registry de policies (`resolve(name) -> Policy::Base`) |
| CREATE | `lib/harness/prompt_catalog.rb` | Catalog de `PROMPT.md` (mesma convenção do `SkillCatalog`) |
| MODIFY | `lib/harness.rb` | Adicionar os `require_relative` dos 5 arquivos (zero side-effects, doc 00 §3) |
| CREATE | `spec/harness/registry_spec.rb` | Testes do genérico (doc 06 §7) |
| CREATE | `spec/harness/tool_registry_spec.rb` | Metadata `optional`/`side_effect`; caminho deprecated |
| CREATE | `spec/harness/workflow_registry_spec.rb` | Contrato do callable resolvido |
| CREATE | `spec/harness/policy_registry_spec.rb` | Resolve devolve instância de policy |
| CREATE | `spec/harness/prompt_catalog_spec.rb` | Paridade com os testes do SkillCatalog (doc 06 §7) |

### Step-by-Step Instructions

#### Step 1: `Harness::Registry` genérico

**File:** `lib/harness/registry.rb`

Implementar exatamente a interface do doc 06 §2:

```ruby
module Harness
  # Base executável (RFC-0001 princípio 6: Registry = executável).
  class Registry
    Entry = Data.define(:name, :plugin, :metadata, :factory)
    def register(name, callable = nil, plugin: nil, **metadata, &block)
    def resolve(name)   # -> instância (factory.call) | raise NotFoundError
    def entries         # -> [Entry]
    def names           # -> [String]
  end
end
```

Regras:

- `# frozen_string_literal: true` no topo; comentários em português (convenção Fase 0).
- `register`: normaliza `name.to_s`; `factory = block || -> { callable }`. Se `callable` é `nil` **e** não há bloco → `ArgumentError` (registro sem factory é bug; "erro alto e cedo" — ver Notes). Retorna `self` (encadeável, como a Fase 0).
- **Duplicata: PRIMEIRO registro vence** (precedência de plugin, RFC-0003 §5 — mesma regra da Fase 0 do PluginLoader): o segundo registro é **descartado com `warn`** informando nome, plugin vencedor e plugin descartado. Não levanta erro.
- `resolve(name)`: `name.to_s`; entrada inexistente → `raise Harness::NotFoundError, "..."` (D4; a classe vem de `lib/harness/errors.rb`, task 1). Existente → `entry.factory.call`.
- `entries` → `@entries.values`; `names` → `@entries.keys`.
- `metadata`: Hash de keywords capturado por `**metadata`, guardado como veio (chaves Symbol). Preservado na Entry — as subclasses e a task 21 leem dele.
- Método adicional voltado ao Loader (doc 06 §6 + L3 — "as entries carregam `plugin:` justamente para isso"): `deregister_plugin(plugin_id)` remove todas as entries cujo `entry.plugin == plugin_id.to_s`. É o suporte de rollback de entradas parciais que a task 21 usa; documente no comentário que **não** é API de runtime (registries são imutáveis pós-boot — doc 06 §5, L6).

**Reference pattern from codebase** (Fase 0, `docs/harness_handoff/reference-implementation/lib/agent_runtime/tool_registry.rb` — a estrutura Entry/factory/register que o genérico generaliza):

```ruby
class ToolRegistry
  Entry = Data.define(:name, :optional, :plugin, :factory)

  def initialize
    @entries = {}
  end

  def register(name, klass = nil, optional: false, plugin: nil, &block)
    name = name.to_s
    factory = block || -> { klass }
    @entries[name] = Entry.new(name: name, optional: optional, plugin: plugin, factory: factory)
    self
  end
```

E o warn de duplicata segue o estilo da Fase 0 (`plugin_loader.rb`):

```ruby
warn "[plugin #{@plugin_id}] tool '#{name}' não declarada em contracts.tools — ignorada"
```

#### Step 2: `Harness::ToolRegistry` re-herdando do genérico

**File:** `lib/harness/tool_registry.rb`

- `class ToolRegistry < Registry`. A Fase 0 é preservada (doc 06 §2): quem registrava `register("x", Klass, optional: true, plugin: "p")` continua funcionando — `optional:` agora cai no `**metadata`.
- Normalização de defaults no `register` (override fino que chama `super`): garante `metadata[:optional] = false` e `metadata[:side_effect] = false` quando ausentes (NOVO — doc 02 §3, RFC-0006 §5: `side_effect: true` marca tool não-idempotente; o mecanismo de checkpoint do doc 02 consome via `entry.metadata[:side_effect]`).
- `resolve` segue o caminho do doc 05 §8 (doc 06 §8): o `ToolRegistry#resolve(profile)` da Fase 0 vira **atalho deprecated**. Como o genérico define `resolve(name)`, implemente um único método com despacho por tipo do argumento:
  - argumento responde a `:tools_allow` (é um `AgentProfile`) → `warn` de deprecação + comportamento Fase 0: se `Policy::Builtin::ToolAllowlist` (task 17) estiver disponível, delega a ela; senão, reproduz inline a lógica da Fase 0 (optional exige opt-in; allow não-vazia = conjunto final; deny sempre vence; devolve `factory.call` das selecionadas).
  - caso contrário → `super` (lookup por nome, contrato do genérico).
- Nenhum chamador da Fase 1 usa o caminho deprecated (o Executor usa `entries` + Policy Engine, doc 03 §4 estágio 3) — ele existe só para não quebrar chamadores externos (doc 05 §8).

**Reference pattern from codebase** (a lógica Fase 0 que o caminho deprecated reproduz — `tool_registry.rb`):

```ruby
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

#### Step 3: `WorkflowRegistry` e `PolicyRegistry`

**Files:** `lib/harness/workflow_registry.rb`, `lib/harness/policy_registry.rb`

Subclasses finas do genérico — o valor delas é o **contrato documentado**, não código novo:

- `WorkflowRegistry < Registry` — comentário de classe copiando o contrato do doc 06 §2: workflow é um callable Ruby (RFC-0001 §5) com assinatura `#call(input, context:, tools:)` que orquestra RubyLLM Agents/Workflows **por dentro** (RubyLLM First); `context:` é o ContextPackage, `tools:` são instâncias já filtradas pela Resolution (doc 03 §4.1); execução = um turno lógico, checkpoint ao final. Nada é validado no registro (o callable pode vir por bloco factory).
- `PolicyRegistry < Registry` — comentário: `resolve(name) -> Policy::Base` (doc 05); as builtin (`ToolAllowlist`, `SkillAllowlist`, `WorkflowAllowlist`) são registradas **no boot** pelo composition root (`config/wiring.rb`, tasks 17/26 — não aqui).

#### Step 4: `PromptCatalog`

**File:** `lib/harness/prompt_catalog.rb`

**Catalog, NÃO Registry** (conteúdo não-executável — RFC-0001 princípio 6, doc 00 §5.6). Espelha o `SkillCatalog` da Fase 0 (que a task 15/migração mantém intocado):

- `Prompt = Data.define(:name, :description, :path, :body)`.
- `initialize(roots)` — roots ordenados por precedência (maior primeiro), **mesma precedência do SkillCatalog**: mesmo nome em mais de um root → o primeiro vence.
- Convenção: `prompts/<name>/PROMPT.md` com frontmatter YAML `name`/`description` — espelha SKILL.md (Convention over Configuration, doc 00 §5.7). Glob: `Dir.glob(File.join(root, "**", "PROMPT.md")).sort`.
- `find(name)` → `Prompt | nil` (o provider `Prompt`, doc 04 §2, converte `nil` em `ContextError` — não é papel do catálogo levantar).
- `all` → `[Prompt]`.
- Sem `effective`/`format_for_prompt` — são específicos de skills (doc 06 §2 só lista `find`/`all`).
- `yaml` da stdlib (`YAML.safe_load`), zero dependências.

**Reference pattern from codebase** (o parse do `skill_catalog.rb` da Fase 0 — replicar trocando SKILL.md por PROMPT.md):

```ruby
def load_all
  found = {}
  @roots.each do |root|
    Dir.glob(File.join(root, "**", "SKILL.md")).sort.each do |file|
      skill = parse(file)
      next unless skill

      found[skill.name] ||= skill # precedência: primeiro root vence
    end
  end
  found
end

def parse(file)
  raw = File.read(file, encoding: "UTF-8")
  match = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
  return nil unless match

  meta = YAML.safe_load(match[1]) || {}
  name = meta["name"]
  return nil unless name

  Skill.new(
    name: name.to_s,
    description: meta["description"].to_s,
    path: file,
    body: match[2].strip
  )
end
```

### Edge Cases to Handle

1. **Duplicata no mesmo registry** → primeiro vence, segundo descartado com `warn` (nunca exceção, nunca overwrite) — doc 06 §2/§7.
2. **`resolve` de nome inexistente** → `Harness::NotFoundError` (D4, doc 06 §6). Em qualquer subclasse.
3. **`register` sem callable e sem bloco** → `ArgumentError` (ver Notes — decisão registrada).
4. **Nomes Symbol** — `register(:foo, ...)` e `resolve(:foo)` funcionam (normalização `to_s` na borda).
5. **PROMPT.md sem frontmatter ou sem `name`** → arquivo ignorado silenciosamente (comportamento idêntico ao `SkillCatalog#parse` retornando `nil`).
6. **Roots inexistentes no PromptCatalog** → `Dir.glob` devolve vazio; catálogo vazio, sem erro.
7. **`deregister_plugin` de plugin sem entries** → no-op.
8. **Imutabilidade pós-boot** (doc 06 §5, L6): não há mecanismo de lock — a imutabilidade é por construção (só o boot registra). Não implementar `freeze!` (não está na interface §2).

## Testing

### Unit Tests

**File:** `spec/harness/registry_spec.rb` (casos do doc 06 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| duplicata primeiro-vence | registra `a` duas vezes (plugins distintos) | `resolve("a")` devolve a 1ª factory; `warn` emitido; `entries.size == 1` |
| resolve inexistente | `resolve("nope")` | `Harness::NotFoundError` |
| factory por classe | `register("a", Klass)` | `resolve("a") == Klass` |
| factory por bloco | `register("a") { Obj.new }` | `resolve("a")` invoca o bloco a cada resolve |
| metadata preservada | `register("a", K, plugin: "p", foo: 1)` | `entries.first.metadata == { foo: 1 }`; `plugin == "p"` |
| sem factory | `register("a")` sem klass/bloco | `ArgumentError` |
| names/entries | 2 registros | `names == %w[a b]`; entries são `Entry` |
| deregister_plugin | 3 entries, 2 do plugin "x" | remove as 2, preserva a outra |

**File:** `spec/harness/tool_registry_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| defaults de metadata | `register("t", K)` | `metadata == { optional: false, side_effect: false }` |
| side_effect explícito | `register("t", K, side_effect: true)` | `metadata[:side_effect] == true` |
| compat Fase 0 | `register("t", K, optional: true, plugin: "p")` | entry com `optional: true` no metadata, `plugin: "p"` |
| resolve por nome | `resolve("t")` | instância via factory (contrato do genérico) |
| resolve(profile) deprecated | profile com allow/deny (duplo com `tools_allow`/`tools_deny`/`tool_opted_in?`) | warn de deprecação + mesma tabela de casos da Fase 0 (required/optional/opt-in/allow-final/deny-vence) |

**File:** `spec/harness/workflow_registry_spec.rb` — registra callable (lambda e bloco) e resolve devolve algo que responde a `call`; herda duplicata/NotFound (smoke).

**File:** `spec/harness/policy_registry_spec.rb` — registra classe de policy fake (PORO com `#decide`) e resolve instancia; NotFound.

**File:** `spec/harness/prompt_catalog_spec.rb` (paridade com os testes do SkillCatalog — doc 06 §7; fixtures de PROMPT.md em tmpdir)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| parse de PROMPT.md | frontmatter name/description + corpo | `Prompt` com campos corretos, `body` sem frontmatter |
| precedência de roots | mesmo `name` em dois roots | o do primeiro root vence |
| find inexistente | `find("nope")` | `nil` |
| arquivo sem frontmatter | PROMPT.md sem `---` | ignorado (não aparece em `all`) |
| frontmatter sem name | só description | ignorado |
| all | 2 prompts válidos | lista com os 2 |

### Integration Tests (if applicable)

Não aplicável — componentes puros, sem colaboradores externos. A integração real acontece nas tasks 21 (Loader preenche os registries) e 23 (Executor consome o WorkflowRegistry).

## Definition of Done

- [ ] `Registry` genérico com Entry(name, plugin, metadata, factory), primeiro-vence com warn e `NotFoundError` conforme doc 06 §2/§6
- [ ] `ToolRegistry` herda do genérico; `optional`/`side_effect` no metadata com defaults `false`; caminho deprecated de `resolve(profile)` preservando a semântica Fase 0
- [ ] `WorkflowRegistry` e `PolicyRegistry` criados com contratos documentados
- [ ] `PromptCatalog` com convenção `prompts/<name>/PROMPT.md` e paridade de comportamento com o `SkillCatalog`
- [ ] `lib/harness.rb` requere os novos arquivos sem side-effects
- [ ] Todos os testes passando; **suíte roda sem `ruby_llm` instalado e sem API key** (doc 06 §7: tools fake são POROs)
- [ ] Sem erros de lint
- [ ] Código revisado

## Notes

- **Aviso de drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- `deregister_plugin` não consta na listagem de interface do doc 06 §2, mas é exigido pelo §6/L3 ("registries limpos das entradas parciais daquele plugin — as entries carregam `plugin:` justamente para isso"). Está aqui, e não na task 21, porque é comportamento do Registry.
- `ArgumentError` para registro sem factory é uma micro-decisão local desta task (a Fase 0 aceitava `klass` nil e o resolve devolvia `nil`, o que violaria o contrato "`resolve` → instância | NotFoundError" do doc 06 §2). Se discordar, registre no PR — não mude o contrato do `resolve`.
- O despacho por tipo em `ToolRegistry#resolve` (nome vs profile) é a leitura mais direta de "resolve segue o caminho do doc 05 §8" (doc 06 §8) sem quebrar a assinatura do genérico. Se a task 17 já tiver removido todos os chamadores do caminho deprecated, ele pode ser um simples warn+delegação à `ToolAllowlist`.
- A task 15 (provider `Prompt`) aceita `catalog: nil` justamente para não depender desta task (grafo: `15 → 20*`) — ao integrar, basta passar a instância do `PromptCatalog` no wiring.
- Não criar diretório `prompts/` de exemplo no repo — fixtures vivem em tmpdir nos specs; dirs reais chegam via plugins (task 21) e workspace (wiring, task 26).

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 34 novos (11 registry + 12 tool_registry + 3 workflow + 3 policy_registry + 8 prompt_catalog − ajustes), 494 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/{registry,workflow_registry,policy_registry,prompt_catalog}.rb` + 5 specs
- **Arquivos modificados:** `lib/harness/tool_registry.rb` (reescrito herdando `Registry`), `lib/harness/policy/policy.rb` (`ToolAllowlist` lê `metadata[:optional]`), `lib/harness.rb`, `spec/harness/policy/policy_spec.rb` (Entry metadata-based), `spec/harness/tool_registry_spec.rb` (reescrito)
- **Observações / decisões tomadas:**
  - **Refatoração do `ToolRegistry` (task 17 → task 20):** de classe standalone para `ToolRegistry < Registry`. `optional`/`side_effect` migraram para `metadata` (defaults false); adicionado `side_effect?(name)` (consumido pelo `ToolEnvelope`). **Ripple:** `Policy::Builtin::ToolAllowlist` passou a ler `e.metadata[:optional]` (antes `e.optional`); o `policy_spec` acompanhou (Entry struct metadata-based).
  - `Registry` genérico: Entry(name, plugin, metadata, factory), duplicata **primeiro-vence** com warn, `NotFoundError`, `deregister_plugin` (rollback do Loader, task 21). `register` sem factory → `ArgumentError` (micro-decisão registrada — o contrato `resolve → instância|NotFound` não admite factory nula).
  - **`PolicyRegistry#resolve` instancia** a policy quando registrada como classe (o Engine chama `#decide` no resultado); `fetch` é alias (duck-type do Engine). Isso permite trocar o Hash-registry da task 17 pelo `PolicyRegistry` real no wiring (task 26) sem mudar o Engine.
  - `ToolRegistry#resolve` despacha por tipo (AgentProfile → atalho deprecated que delega à `ToolAllowlist`; nome → genérico).
  - `PromptCatalog` é Catalog (não Registry) — espelha `SkillCatalog` (`prompts/<name>/PROMPT.md`), sem `effective`/`format_for_prompt`.
