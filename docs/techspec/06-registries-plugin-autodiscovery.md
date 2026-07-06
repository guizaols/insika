# Techspec 06 — Registries restantes + Plugin Autodiscovery por Gem

> Implementa RFC-0003 §8 (pendências da Fase 1) e os Registries que faltam
> (Workflow, Prompt Catalog, Policy — BACKLOG). O PluginLoader da Fase 0 é
> **estendido**, não reescrito (RFC-0003 §7: núcleo já implementado e testado).

## 1. Objetivo e fronteira

**Faz:** `Registry` genérico; `WorkflowRegistry`, `PolicyRegistry`,
`PromptCatalog`; manifesto renomeado para `harness.plugin.yml` com contratos
de `workflows` e registro de `middleware`/`hooks`/`context_providers`;
autodiscovery por gem (boot hook estilo Railtie); validação de
`config_schema`; tools com flag `side_effect` (consumida pelo checkpoint,
doc 02 §3).

**Não faz:** Capability Registry (RFC-0004 — Fase 2); Tool Search; registry
público/assinatura de plugins (RFC-0003 §9.2 — Fase 2/3); sandbox de exec
(plugins seguem in-process/código confiável, RFC-0003 §5).

## 2. Interfaces públicas

```ruby
module Harness
  # Base executável (RFC-0001 princípio 6: Registry = executável).
  class Registry
    Entry = Data.define(:name, :plugin, :metadata, :factory)
    def register(name, callable = nil, plugin: nil, **metadata, &block)
    def resolve(name)                # -> instância (factory.call) | raise NotFoundError
    def entries                      # -> [Entry]
    def names                        # -> [String]
    # Duplicata: PRIMEIRO registro vence (precedência de plugin, RFC-0003 §5),
    # descartada com warn — mesma regra da Fase 0.
  end

  class ToolRegistry < Registry
    # Fase 0 preservada; metadata ganha: optional: (existente),
    # side_effect: false (NOVO — doc 02 §3, RFC-0006 §5)
  end

  class WorkflowRegistry < Registry
    # Workflow = callable Ruby (RFC-0001 §5): #call(input, context:, tools:)
    # que orquestra RubyLLM Agents/Workflows por dentro (RubyLLM First).
    # context: ContextPackage; tools: instâncias já filtradas pela Resolution
    # (doc 03 §4.1). Execução = um turno lógico, checkpoint ao final.
  end

  class PolicyRegistry < Registry
    # resolve(name) -> Policy::Base (doc 05). Builtin registradas no boot.
  end

  # Catalog, NÃO Registry (conteúdo não-executável — princípio 6).
  class PromptCatalog
    Prompt = Data.define(:name, :description, :path, :body)
    def initialize(roots)            # mesma precedência do SkillCatalog
    def find(name); def all
    # Convenção: prompts/<name>/PROMPT.md com frontmatter name/description —
    # espelha SKILL.md (Convention over Configuration).
  end

  module Plugin
    class Loader                     # evolui o PluginLoader da Fase 0
      # enabled: opt-in de bundled (Fase 0); disabled: opt-out de gems
      # anunciadas (default-enabled, §3); announced entram via roots.
      def initialize(roots:, registries:, enabled:, disabled: [], event_stream:)
      # registries: { tools:, workflows:, policies:, middleware:, hooks:,
      #               context_providers: }
      def load_all                   # -> { skill_dirs: [], prompt_dirs: [], plugins: [Plugin] }
    end

    # Boot hook por gem (RFC-0003 §2): a gem chama no load do seu lib/:
    #   Harness::Plugin.announce(File.expand_path("../plugin", __dir__))
    def self.announce(root)          # acumula roots ANTES do boot
    def self.announced_roots         # consumido pelo composition root

    class RegistrationAPI            # evolui a da Fase 0
      def register_tool(name, klass = nil, &block)
      def register_workflow(name, callable = nil, &block)
      def register_policy(name, klass)
      def register_middleware(instance)
      def register_hook(pair, before: nil, after: nil)
      def register_context_provider(instance)
      def config                     # -> Hash validado pelo config_schema
      # Regra Fase 0 mantida: tool/workflow fora de contracts.* → warn + ignora.
      # middleware/hooks/providers NÃO exigem contrato (não são endereçáveis
      # por nome pelo modelo — o risco que o contrato mitiga não existe).
    end
  end
end
```

## 3. Modelos de dados / schemas

### Manifesto `harness.plugin.yml` (evolução do `plugin.yml` — RFC-0003 §3)

```yaml
id: browser
name: Browser
description: Navegação web headless.
entry: plugin.rb
module: BrowserPlugin
contracts:
  tools: [browse, screenshot]
  workflows: [research]          # NOVO (RFC-0003 §8)
tool_metadata:
  screenshot: { optional: true }
  browse:     { side_effect: false }
skills: [skills]
prompts: [prompts]               # NOVO — dirs de PROMPT.md
config_schema:                   # NOVO — validado (RFC-0003 §8)
  type: object
  additionalProperties: false
  properties:
    timeout: { type: integer }
config:                          # valores default do plugin (operador sobrepõe)
  timeout: 30
```

- **Compatibilidade:** o Loader aceita `plugin.yml` (Fase 0) com warn de
  deprecação por uma fase; `harness.plugin.yml` tem precedência no mesmo dir.
- `capabilities` em contracts: **reservado, ignorado com warn** (RFC-0004 é
  Fase 2 — o manifesto não quebra quando ela chegar).
- Validação de `config_schema`: subset próprio de JSON Schema — `type`,
  `properties`, `required`, `additionalProperties`, `enum` (L4). Config
  inválida → plugin **não carrega** + warn (fail-closed por plugin, não
  derruba o boot).

### Ordem de precedência de roots (consolidada)

`workspace/plugins` (maior) → roots anunciados por gem (ordem de `announce`)
→ bundled. Habilitação: bundled exige `enabled` explícito (Fase 0); **gem
anunciada é default-enabled**, desabilitável por `disabled: [ids]` no wiring
(RFC-0003 §5).

## 4. Fluxo de controle

```
boot (config/wiring.rb — composition root):
  1. gems já carregadas chamaram Plugin.announce(root)     (require do Gemfile)
  2. Loader.new(roots: [workspace, *announced, *bundled], ...)
  3. load_all:
       manifesto achado → validado (sem executar código, RFC-0003 §2)
       → precedência por id (primeiro root vence, Fase 0)
       → config_schema valida config
       → require entry → module.register(api) → registries preenchidos
       → skill_dirs/prompt_dirs acumulados p/ catálogos
       → evento :plugin_loaded { id, tools, skills }        (RFC-0003 §6)
  4. Catálogos construídos com os dirs (precedência: workspace > plugin)
```

Em runtime, os registries participam da pipeline: ToolRegistry no estágio 3
(candidatas → Policy, doc 05); WorkflowRegistry no estágio 6 do
`TriggerWorkflow` (doc 03 §4.1); PolicyRegistry na montagem do Engine;
PromptCatalog é fonte para o provider Prompt (doc 04) quando um perfil
referencia um prompt por nome.

## 5. Concorrência

Carga de plugin é **exclusivamente no boot**, single-fiber, antes do servidor
aceitar conexões — sem concorrência por construção. Registries são
imutáveis pós-boot na Fase 1 (registro dinâmico em runtime não é requisito;
leituras concorrentes de Hash congelado são seguras em fibers).

## 6. Erros e timeouts

- Manifesto ilegível/sem `id` → plugin ignorado com warn (Fase 0).
- `config_schema` inválido ou config que não valida → plugin não carrega,
  warn detalhado; boot **continua** (um plugin quebrado não derruba o
  serviço).
- Exceção dentro de `register(api)` → idem: captura, warn com backtrace,
  plugin descartado, registries limpos das entradas parciais daquele plugin
  (rollback do registro — as entries carregam `plugin:` justamente para isso).
- `resolve` de nome inexistente → `Harness::NotFoundError` (D4).
- Sem timeouts: boot síncrono.

## 7. Estratégia de testes

- **Registry genérico:** duplicata primeiro-vence com warn; resolve
  inexistente; factory por bloco e por classe; metadata preservada.
- **Loader (portados da Fase 0 + novos):** fixtures de plugin em tmpdir —
  manifesto novo e antigo (deprecação); workflow em contracts registrado,
  fora de contracts ignorado; middleware/hook/provider registrados sem
  contrato; config_schema válido/inválido; rollback quando register levanta
  no meio; precedência workspace > gem > bundled; disabled de gem.
- **Autodiscovery:** `Plugin.announce` acumula; roots anunciados entram na
  ordem correta; simulação de "gem" = announce manual de fixture.
- **PromptCatalog:** paridade com os testes do SkillCatalog (mesma convenção).
- Zero RubyLLM (tools fake são POROs; a fixture não requer a gem).

## 8. Evolução a partir da Fase 0

- `plugin_loader.rb` → `plugin/loader.rb`: estrutura mantida (manifests →
  precedência → entry → RegistrationAPI); muda o nome do manifesto (com
  compat), a API ganha os métodos novos, e o retorno de `load_all` passa de
  `[skill_dirs]` para o Hash de §2.
- `tool_registry.rb` → herda do `Registry` genérico; `Entry` ganha
  `metadata` (absorve `optional`, adiciona `side_effect`); `resolve` segue o
  caminho do doc 05 §8.
- `config/wiring.rb` → monta o conjunto de registries e passa ao Loader; o
  exemplo `weather` da Fase 0 migra de manifesto (fixture de regressão).

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | `announce` no load da gem (não scan de LOAD_PATH) | explícito e barato; scan de gems instaladas é lento e surpreende (responde RFC-0003 §9.1: precedência clara porque a ordem é a de require + workspace sempre ganha) |
| L2 | Gem default-enabled, bundled opt-in | RFC-0003 §5 literal; instalar gem é ato intencional do operador, bundled vem "de fábrica" |
| L3 | Rollback de entradas parciais em falha de register | sem isso um plugin meio-registrado deixa o registry num estado que nenhum teste cobre; `plugin:` na Entry torna o rollback O(n) trivial |
| L4 | Validador de config_schema próprio (subset), sem gem json-schema | Reuse First pede gem, mas núcleo pequeno + zero deps no core pesa mais para um subset de 5 keywords; trocável por gem na Fase 2 se schemas crescerem |
| L5 | middleware/hooks/providers sem exigência de contrato no manifesto | o contrato existe para o que o modelo/config endereça por nome (tools/workflows); exigi-lo para o resto é burocracia sem risco mitigado |
| L6 | Registries imutáveis pós-boot | elimina toda uma classe de corrida; reload de plugin em runtime é feature da Fase 2/3 com ciclo próprio |
