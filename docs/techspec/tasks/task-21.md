# Task 21: `Plugin::Loader` estendido — manifesto `harness.plugin.yml` (compat), config_schema, rollback parcial, novos registros

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [06-registries-plugin-autodiscovery.md](../06-registries-plugin-autodiscovery.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Evoluir o `PluginLoader` da Fase 0 para `Harness::Plugin::Loader`: manifesto renomeado para `harness.plugin.yml` (com compat para `plugin.yml`), contrato de `workflows`, `capabilities` reservado, validador próprio de `config_schema` (subset L4), rollback de entradas parciais (L3) e `RegistrationAPI` completa (tools, workflows, policies, middleware, hooks, context providers, config).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 17 | `Policy::Engine` + builtins `Tool/Skill/WorkflowAllowlist` | ⬜ TODO |
| 20 | `Registry` genérico + Workflow/Policy Registries + `PromptCatalog` | ⬜ TODO |

(Grafo do tasks.md: `21 → 17, 20`. Da 17 vem o contrato `Policy::Base` que `register_policy` registra; da 20 vêm os registries que o Loader preenche e o `deregister_plugin` usado no rollback.)

## Context

Doc 06 §2-§4 e §8; RFC-0003 §7 manda **estender, não reescrever**: o `plugin_loader.rb` da Fase 0 (núcleo já implementado e testado) mantém a estrutura *manifests → precedência → entry → RegistrationAPI* e ganha o delta desta task. O Loader roda **exclusivamente no boot**, single-fiber, antes do servidor aceitar conexões (doc 06 §5) — zero concorrência por construção. A task 22 adiciona por cima a classificação de roots anunciados por gem; aqui a regra de habilitação é a da Fase 0 (`enabled:` explícito).

Delta em relação à Fase 0 (o "o quê" desta task):

| Fase 0 (`plugin_loader.rb`) | Fase 1 (`plugin/loader.rb`) |
|---|---|
| manifesto `plugin.yml` | `harness.plugin.yml`; `plugin.yml` aceito com warn de deprecação; novo tem precedência no mesmo dir |
| `contracts.tools` | + `contracts.workflows`; `contracts.capabilities` reservado (warn + ignora) |
| `tool_metadata: { optional: }` | + `side_effect:` (consumido pelo checkpoint, doc 02 §3) |
| — | `prompts:` (dirs de PROMPT.md) e `config_schema`/`config` validados (subset L4) |
| `registry:` (um ToolRegistry) | `registries:` (hash: tools, workflows, policies, middleware, hooks, context_providers) |
| `RegistrationAPI#register_tool` | + `register_workflow`, `register_policy`, `register_middleware`, `register_hook`, `register_context_provider`, `config` |
| `load_all -> [skill_dirs]` | `load_all -> { skill_dirs:, prompt_dirs:, plugins: }` |
| exceção em `register` derruba o boot | captura + warn com backtrace + **rollback das entradas parciais** (L3); boot continua |
| — | evento `:plugin_loaded { id, tools, skills }` (D5, RFC-0003 §6) |

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/plugin/loader.rb` | `Plugin::Loader` + `RegistrationAPI` + validador de config_schema (evolui `plugin_loader.rb`) |
| MODIFY | `lib/harness.rb` | `require_relative "harness/plugin/loader"` |
| MODIFY | `config/wiring.rb` | Monta o hash de registries e passa ao Loader (doc 06 §8) |
| CREATE | `plugins/weather/harness.plugin.yml` | Migração do exemplo da Fase 0 (manifesto novo — fixture de regressão, doc 06 §8) |
| CREATE | `plugins/weather/plugin.rb` | Cópia da Fase 0 (módulo `WeatherPlugin`, tool `get_weather`) |
| CREATE | `plugins/weather/skills/weather_report/SKILL.md` | Cópia da Fase 0 |
| CREATE | `spec/harness/plugin/loader_spec.rb` | Suíte portada da Fase 0 + casos novos (doc 06 §7), fixtures em tmpdir |

### Step-by-Step Instructions

#### Step 1: Estrutura e descoberta de manifestos

**File:** `lib/harness/plugin/loader.rb`

```ruby
module Harness
  module Plugin
    class Loader
      Discovered = Data.define(:id, :name, :root, :tool_names, :workflow_names,
                               :skill_dirs, :prompt_dirs, :config)

      def initialize(roots:, registries:, enabled:, event_stream:)
      # registries: { tools:, workflows:, policies:, middleware:, hooks:,
      #               context_providers: }
      def load_all   # -> { skill_dirs: [], prompt_dirs: [], plugins: [Discovered] }
    end
  end
end
```

- Manter a mecânica da Fase 0: glob dos manifestos por root **em ordem de precedência** (maior primeiro), `seen` por id, **primeiro root vence**.
- Descoberta agora procura os DOIS nomes: `Dir.glob(File.join(r, "**", "{harness.plugin.yml,plugin.yml}"))`. Agrupe por diretório: se o mesmo dir tem os dois, `harness.plugin.yml` tem precedência (doc 06 §3); se só tem `plugin.yml`, carregue-o normalmente e emita `warn "[plugin <id>] plugin.yml está deprecado — renomeie para harness.plugin.yml"` (compat por uma fase).
- `registries:` é o hash do doc 06 §2. `tools`/`workflows`/`policies` são instâncias de `Registry` (task 20). `hooks` é a instância `Harness::Hooks` (task 16). `middleware` e `context_providers` são **coleções ordenadas** (respondem a `<<`) que o composition root usa DEPOIS do `load_all` para construir `MiddlewareStack` e `Builder` (o boot carrega plugins antes de montar a pipeline — doc 06 §4).
- Validação do manifesto **sem executar código** (RFC-0003 §2): manifesto ilegível (YAML inválido) ou sem `id` → plugin ignorado com warn (regra Fase 0, doc 06 §6). Habilitação: `next unless @enabled.include?(id)` (Fase 0; a task 22 refina para roots anunciados).
- `contracts.capabilities` presente → `warn "[plugin <id>] contracts.capabilities é reservado (Fase 2) — ignorado"` e segue (doc 06 §3: o manifesto não quebra quando a RFC-0004 chegar).

**Reference pattern from codebase** (Fase 0, `docs/harness_handoff/reference-implementation/lib/agent_runtime/plugin_loader.rb` — o esqueleto a preservar):

```ruby
def load_all
  seen = {}
  skill_dirs = []

  manifests.each do |file|
    manifest = YAML.safe_load(File.read(file, encoding: "UTF-8")) || {}
    id = manifest["id"].to_s
    next if id.empty?
    next unless @enabled.include?(id)
    next if seen.key?(id) # precedência: primeiro root vence

    root = File.dirname(file)
    plugin = build_plugin(manifest, root)
    register_tools(manifest, plugin)
    skill_dirs.concat(plugin.skill_dirs)
    seen[id] = plugin
  end

  skill_dirs
end

private

def manifests
  @roots.flat_map { |r| Dir.glob(File.join(r, "**", "plugin.yml")).sort }
end
```

#### Step 2: Validador de `config_schema` (subset L4)

**File:** `lib/harness/plugin/loader.rb` (classe aninhada `ConfigSchema`; extrair para `lib/harness/plugin/config_schema.rb` se passar de ~80 linhas — classes pequenas)

Subset próprio de JSON Schema, **sem gem externa** (L4 — trocável por gem na Fase 2). Keywords suportadas, e SOMENTE elas:

- `type` — um de `object | array | string | integer | number | boolean | null` (mapeamento Ruby: Hash, Array, String, Integer, Numeric, true/false, nil);
- `properties` — Hash de sub-schemas (recursivo);
- `required` — Array de nomes que devem existir no valor;
- `additionalProperties` — `false` proíbe chaves fora de `properties`;
- `enum` — Array de valores permitidos.

API: `ConfigSchema.validate(schema, value) -> [String]` (lista de erros; vazia = válido). Duas classes de falha, ambas fail-closed por plugin (doc 06 §3/§6):

1. **Schema inválido** (keyword fora do subset, `type` desconhecido, `properties` que não é Hash…) → erro na lista;
2. **Config que não valida** contra um schema válido → erro na lista, com o caminho da chave (`"config.timeout: esperado integer, veio String"`).

No Loader: se o manifesto tem `config_schema`, valide `manifest["config"] || {}` contra ele **antes** do require do entry. Lista de erros não-vazia → `warn` detalhado (id + cada erro) e o plugin **não carrega** (não entra em `seen`, nada é registrado); o boot **continua** (um plugin quebrado não derruba o serviço — doc 06 §6). Sem `config_schema` → config passa como está (sem validação).

O manifesto de referência (doc 06 §3):

```yaml
config_schema:                   # NOVO — validado (RFC-0003 §8)
  type: object
  additionalProperties: false
  properties:
    timeout: { type: integer }
config:                          # valores default do plugin (operador sobrepõe)
  timeout: 30
```

#### Step 3: `RegistrationAPI` completa

**File:** `lib/harness/plugin/loader.rb`

Evolui a `RegistrationAPI` da Fase 0 com a interface do doc 06 §2:

```ruby
class RegistrationAPI
  def register_tool(name, klass = nil, &block)
  def register_workflow(name, callable = nil, &block)
  def register_policy(name, klass)
  def register_middleware(instance)
  def register_hook(pair, before: nil, after: nil)
  def register_context_provider(instance)
  def config   # -> Hash validado pelo config_schema (congelado)
end
```

Regras por método:

- `register_tool` — regra Fase 0 mantida: nome fora de `contracts.tools` → `warn "[plugin <id>] tool '<name>' não declarada em contracts.tools — ignorada"` + ignora. Metadata do manifesto (`tool_metadata.<name>`): `optional:` (existente) e `side_effect:` (NOVO — doc 02 §3), com default `false` para ambos. Delega a `registries[:tools].register(name, klass, plugin: id, optional:, side_effect:, &block)`.
- `register_workflow` — mesma regra, contra `contracts.workflows` (NOVO — RFC-0003 §8): fora do contrato → warn + ignora. Delega a `registries[:workflows].register(name, callable, plugin: id, &block)`.
- `register_policy(name, klass)` — delega a `registries[:policies].register(name, klass, plugin: id)`. Sem exigência de contrato (ver Notes — o manifesto não define `contracts.policies`).
- `register_middleware(instance)` / `register_context_provider(instance)` / `register_hook(pair, before:, after:)` — **NÃO exigem contrato** (doc 06 §2/L5: o contrato existe para o que o modelo/config endereça por nome; middleware/hooks/providers não são endereçáveis pelo modelo). São **acumulados em staging interno da API** e efetivados pelo Loader só depois de `register(api)` retornar sem exceção (mecânica do rollback, Step 4): middleware/providers via `<<` nas coleções, hooks via `hooks.register(pair, before:, after:)`.
- `config` — devolve o Hash validado no Step 2, `.freeze` (o plugin lê, não muda).

**Reference pattern from codebase** (Fase 0 — a API que estes métodos estendem):

```ruby
class RegistrationAPI
  def initialize(registry:, plugin_id:, declared:, metadata:)
    @registry = registry
    @plugin_id = plugin_id
    @declared = declared
    @metadata = metadata
  end

  def register_tool(name, klass = nil, &block)
    name = name.to_s
    unless @declared.include?(name)
      warn "[plugin #{@plugin_id}] tool '#{name}' não declarada em contracts.tools — ignorada"
      return
    end
    optional = !!(@metadata.dig(name, "optional"))
    @registry.register(name, klass, optional: optional, plugin: @plugin_id, &block)
  end
end
```

#### Step 4: Carga do entry + rollback de entradas parciais (L3)

**File:** `lib/harness/plugin/loader.rb`

Para cada plugin habilitado, validado e não-visto:

```
require File.join(root, entry)  →  Object.const_get(manifest["module"])
  →  mod.register(api)          →  efetiva staging (middleware/hooks/providers)
  →  acumula skill_dirs/prompt_dirs  →  emite :plugin_loaded
```

Envolver `require` + `const_get` + `mod.register(api)` em `begin/rescue StandardError`. Na exceção (doc 06 §6):

1. `warn` com id, classe, mensagem e backtrace;
2. **rollback**: `registries[:tools].deregister_plugin(id)`, idem `workflows` e `policies` (o `deregister_plugin` da task 20 — as entries carregam `plugin:` justamente para isso, L3); o staging de middleware/hooks/providers é simplesmente descartado (nunca foi efetivado);
3. plugin descartado: não entra em `seen`, seus `skill_dirs`/`prompt_dirs` não são acumulados;
4. o boot **continua** com os próximos manifestos.

No sucesso, emitir pelo `event_stream` (D5, doc 00):

```ruby
@event_stream.emit(Harness::Event.new(
  type: :plugin_loaded,
  data: { id: plugin.id, tools: plugin.tool_names, skills: plugin.skill_dirs },
  meta: { at: Time.now.utc.iso8601 }
))
```

Retorno de `load_all`: `{ skill_dirs: [...], prompt_dirs: [...], plugins: [Discovered] }` (doc 06 §2/§8 — deixa de ser só `[skill_dirs]`). `prompt_dirs` vem da chave `prompts:` do manifesto (mesma mecânica de `skills:` — paths relativos ao root do plugin).

#### Step 5: Migrar o exemplo `weather` (fixture de regressão)

**Files:** `plugins/weather/harness.plugin.yml`, `plugins/weather/plugin.rb`, `plugins/weather/skills/weather_report/SKILL.md`

Copiar de `docs/harness_handoff/reference-implementation/plugins/weather/` e migrar o manifesto para o formato novo (doc 06 §8: "o exemplo `weather` da Fase 0 migra de manifesto"):

```yaml
id: weather
name: Weather
description: Consulta de clima. Entrega a tool get_weather e a skill weather_report.
entry: plugin.rb
module: WeatherPlugin
contracts:
  tools:
    - get_weather
tool_metadata:
  get_weather:
    optional: true
    side_effect: false
skills:
  - skills
```

`plugin.rb` e o `SKILL.md` copiam como estão (o `plugin.rb` requer `ruby_llm` — por isso ele NÃO é carregado na suíte de testes; ver Testing).

#### Step 6: Wiring

**File:** `config/wiring.rb`

Substituir o bloco da Fase 0 (`AgentRuntime::PluginLoader.new([...], registry:, enabled:)`) pela montagem do doc 06 §8: construir os registries (task 20), o hash `registries:`, o Loader com `roots: [workspace/plugins, *bundled]`, `enabled:` e `event_stream:`; usar o retorno para compor `SkillCatalog` e `PromptCatalog` (precedência: workspace > plugin — doc 06 §4). O wiring completo com boot/recovery é da task 26 — aqui só o trecho de plugins/catálogos.

**Reference pattern from codebase** (Fase 0, `config/wiring.rb` — o trecho evoluído):

```ruby
PLUGIN_SKILL_DIRS = AgentRuntime::PluginLoader.new(
  [File.join(ROOT, "plugins")],
  registry: REGISTRY,
  enabled: %w[weather]
).load_all

CATALOG = AgentRuntime::SkillCatalog.new(
  [File.join(ROOT, "skills"), *PLUGIN_SKILL_DIRS]
)
```

### Edge Cases to Handle

1. **Mesmo dir com `harness.plugin.yml` E `plugin.yml`** → só o novo é lido (precedência, doc 06 §3); sem warn de deprecação nesse caso.
2. **`plugin.yml` sozinho** → carrega + warn de deprecação (uma vez por plugin).
3. **Manifesto ilegível / YAML inválido / sem `id`** → ignorado com warn (Fase 0, doc 06 §6). `YAML.safe_load` que levanta → rescue local, warn, próximo manifesto.
4. **`config_schema` inválido OU config que não valida** → plugin não carrega, warn detalhado, boot continua (fail-closed por plugin, doc 06 §3).
5. **Exceção dentro de `register(api)`** (inclusive `require` que falha e `const_get` de módulo inexistente) → warn com backtrace + rollback + plugin descartado (L3, doc 06 §6).
6. **Tool/workflow fora de `contracts.*`** → warn + ignora (regra Fase 0 mantida); os demais registros do plugin seguem valendo (não é erro).
7. **`contracts.capabilities`** → warn "reservado" + ignora (doc 06 §3).
8. **Mesmo `id` em dois roots** → primeiro root vence (Fase 0); o segundo nem é validado.
9. **Plugin sem `entry`** → só skills/prompts são acumulados (Fase 0 já retornava cedo em `register_tools`); nenhum registro executável.
10. **Duplicata de nome ENTRE plugins** → resolvida pelo Registry (task 20): primeiro vence com warn — o Loader não precisa tratar.

## Testing

### Unit Tests

**File:** `spec/harness/plugin/loader_spec.rb`

Fixtures **construídas em tmpdir** (doc 06 §7): helper que escreve manifesto + entry Ruby com tools/workflows **PORO** (a fixture não requer `ruby_llm`). Registries reais da task 20; `hooks` = instância real de `Harness::Hooks` (task 16) ou duplo com `register`; `middleware`/`context_providers` = arrays; `event_stream` = spy com `emit`.

Casos (portados da Fase 0 + novos — doc 06 §7):

| Test Case | Description | Expected |
|-----------|-------------|----------|
| manifesto novo | `harness.plugin.yml` com tool em contracts | tool registrada com `plugin:` e metadata do manifesto |
| manifesto antigo (compat) | só `plugin.yml` | carrega + warn de deprecação |
| precedência no mesmo dir | os dois manifestos no mesmo dir | só o novo é lido |
| workflow em contracts | `contracts.workflows: [x]` + `register_workflow("x", ...)` | registrado no WorkflowRegistry |
| workflow fora de contracts | `register_workflow("y")` não declarado | warn + não registrado |
| tool fora de contracts | regra Fase 0 | warn + não registrada |
| middleware sem contrato | `register_middleware(obj)` | `middleware` (array) contém obj após load_all |
| hook sem contrato | `register_hook(:tool, before: cb)` | `hooks.register` chamado com o par |
| provider sem contrato | `register_context_provider(obj)` | coleção contém obj |
| policy registrada | `register_policy("p", Klass)` | PolicyRegistry resolve "p" |
| side_effect do manifesto | `tool_metadata: { t: { side_effect: true } }` | entry com `metadata[:side_effect] == true` |
| config_schema válido | schema + config ok | plugin carrega; `api.config` == config congelada |
| config que não valida | `timeout: "trinta"` vs `type: integer` | plugin NÃO carrega; warn; boot segue (outros plugins carregam) |
| config_schema inválido | keyword fora do subset | idem (fail-closed) |
| validador — cada keyword | type/properties/required/additionalProperties/enum | erros corretos por caso (tabela própria) |
| rollback em register | entry registra 1 tool e depois levanta | tool removida do registry; staging descartado; skill_dirs sem o plugin; warn com backtrace; próximo plugin carrega |
| capabilities reservado | `contracts.capabilities: [x]` | warn + plugin carrega normalmente |
| precedência de roots | mesmo id em root A e B | o de A (primeiro) vence |
| enabled gating | id fora de `enabled:` | não carregado (Fase 0) |
| retorno de load_all | plugin com skills e prompts | `{ skill_dirs:, prompt_dirs:, plugins: }` corretos |
| evento :plugin_loaded | carga com sucesso | spy recebeu Event `type: :plugin_loaded, data: {id, tools, skills}` |
| fixture weather (regressão) | manifesto de `plugins/weather/harness.plugin.yml` copiado p/ tmpdir com entry PORO substituto | descoberta/validação/contratos idênticos à Fase 0 |

### Integration Tests (if applicable)

Não nesta task — a integração boot→plugins→recovery→listen é o smoke E2E da task 26. O `plugins/weather/` real (que requer `ruby_llm`) só é exercitado ali.

## Definition of Done

- [ ] `Plugin::Loader` com a assinatura do doc 06 §2 e retorno `{ skill_dirs:, prompt_dirs:, plugins: }`
- [ ] Compat de manifesto: `plugin.yml` com warn de deprecação; `harness.plugin.yml` precede no mesmo dir
- [ ] `contracts.workflows` funcionando; `contracts.capabilities` ignorado com warn
- [ ] Validador de `config_schema` cobrindo exatamente o subset L4 (type, properties, required, additionalProperties, enum); config inválida = plugin não carrega, boot continua
- [ ] `RegistrationAPI` com os 7 métodos do doc 06 §2; contrato exigido só para tools/workflows (L5)
- [ ] Rollback de entradas parciais em falha de `register` (L3) — verificado por teste
- [ ] Evento `:plugin_loaded` emitido por plugin carregado (D5)
- [ ] `plugins/weather/` migrado para o manifesto novo (fixture de regressão)
- [ ] Todos os testes passando; **suíte roda sem `ruby_llm` instalado e sem API key** (fixtures PORO em tmpdir)
- [ ] Sem erros de lint
- [ ] Código revisado

## Notes

- **Aviso de drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Rollback misto (registries vs staging):** o doc 06 §6/L3 define o rollback via `plugin:` nas entries — isso cobre tools/workflows/policies (Registries). Para middleware/hooks/providers o doc é silencioso e seus alvos não carregam `plugin:`; o staging-até-sucesso na `RegistrationAPI` é a materialização de menor custo da mesma garantia ("nada parcial sobra"). Se preferir registro direto + remoção, precisará de remoção por identidade nas coleções e de API de unregister no `Hooks` — não invente isso sem necessidade.
- **`register_policy` sem contrato:** o manifesto (doc 06 §3) só define `contracts.tools` e `contracts.workflows`; policies são endereçáveis por nome via `profile.policies`, mas o techspec não criou `contracts.policies`. Lacuna registrada — seguir o doc (sem contrato) e apontar no PR se julgar risco.
- **Override de config pelo operador:** o doc 06 §3 diz "operador sobrepõe" os defaults de `config:`, mas a assinatura de §2 (`roots:, registries:, enabled:, event_stream:`) não tem porta para overrides. Na Fase 1, `api.config` entrega os defaults do manifesto validados. Lacuna registrada — não adicionar kwarg por conta própria.
- O warn de deprecação de `plugin.yml` vale "por uma fase" (doc 06 §3) — a remoção da compat é trabalho da Fase 2, não desta task.
- A task 22 muda a regra de habilitação para roots anunciados por gem (default-enabled + `disabled:`); escreva o gate de `enabled` de forma que essa extensão seja localizada (um predicado `enabled?(id, root)`).
