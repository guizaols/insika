---
rfc: "0003"
title: Plugin System
status: Draft
type: Componente
created: 2026-07-05
supersedes: []
depends_on: ["0001", "0002"]
---

# RFC-0003 — Plugin System

> Detalha a Extensibility Platform declarada na RFC-0001: como plugins são
> descobertos, validados, carregados e registrados. Segue a convenção do OpenClaw.

## 1. Motivação

Toda funcionalidade adicional entra por plugins, mantendo o núcleo pequeno. Um
plugin pode registrar: Tools, Workflows, Policies, Middleware, Hooks, Context
Providers, Skills, Prompts e Capabilities.

## 2. Modelo

Cada plugin é um **diretório** com:

- um **manifesto** (`harness.plugin.yml`) — descoberta e validação **sem executar
  código**;
- um **entry Ruby** — registra as implementações de verdade via `register(api)`.

Uma **gem** pode enviar um ou mais diretórios de plugin e se auto-registrar no
boot (estilo Railtie). Assim, instalar a gem = descoberta automática; o manifesto
dá validação, precedência e config schema sem carregar runtime.

## 3. Manifesto

```yaml
# harness.plugin.yml
id: browser
name: Browser
description: Navegação web headless.
entry: plugin.rb
module: BrowserPlugin
contracts:
  tools: [browse, screenshot]
  workflows: [research]
  capabilities: [browse, search]
tool_metadata:
  screenshot: { optional: true }
skills: [skills]           # diretórios de skill relativos ao root
config_schema:
  type: object
  additionalProperties: false
```

## 4. Entry

```ruby
module BrowserPlugin
  def self.register(api)
    api.register_tool     "browse", BrowseTool
    api.register_tool     "screenshot", ScreenshotTool
    api.register_workflow "research", ResearchWorkflow
    api.register_capability :browse, tool: "browse"
  end
end
```

O `api` é a fachada de registro (o análogo Ruby do `api.registerTool` do
OpenClaw), que injeta `plugin_id` e o `optional` vindo do `tool_metadata`.

## 5. Regras (fiéis ao OpenClaw)

- Toda tool/workflow deve constar em `contracts.*`; o que o entry registrar fora
  disso é **ignorado com aviso** (descoberta sem carregar runtime).
- Plugins **bundled** precisam ser habilitados explicitamente; plugins instalados
  como gem vêm habilitados por padrão (podem ser desabilitados).
- `id` duplicado: **maior precedência vence**; duplicatas são descartadas e
  logadas. O path da pasta é só organização; o id vem do manifesto.
- **Skills de plugin** entram em **baixa precedência** (workspace sobrescreve).
- Plugins rodam **in-process → código confiável**. Entry de terceiros exige
  revisão; `exec` de tools deve ser sandboxed (ver RFC-0001 §Security equivalente).

## 6. Descoberta

```
Instala gem (ou coloca diretório em um root)
        ↓
Manifesto encontrado e validado (sem executar entry)
        ↓
Precedência resolvida por id
        ↓
Entry requerido → register(api) → Registries atualizados
        ↓
Skills do plugin somadas ao Skill Catalog (baixa precedência)
        ↓
Evento PluginLoaded emitido
```

## 7. Estado atual

Implementado e testado no `agent_runtime`: `PluginLoader` com manifesto + entry +
skill dirs, `contracts.tools` obrigatório, precedência por id, plugin
desabilitado não carrega, skills de plugin mescladas no catálogo.

## 8. Pendências

- Contratos de **workflow** e **capability** no manifesto (hoje só tools).
- **Autodiscovery por gem** (hook de boot estilo Railtie).
- Validação de `config_schema`.
- Registro de Middleware/Hooks/Context Providers por plugin.

## 9. Questões em Aberto

1. Como autodiscovery por gem coexiste com precedência de id e overrides locais
   sem surpresas.
2. Verificação de integridade/assinatura de plugins de terceiros na instalação.
