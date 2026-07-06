# BACKLOG — Harness

> Documento **vivo**. Roadmap, status de implementação e mapeamento com o código.
> Fora do processo de RFC (ver RFC-0000): pode mudar a qualquer momento, sem
> emenda. A constituição (RFC-0001) não contém nada disto.

## Roadmap em fases

### Fase 0 — Núcleo (feito, testado)
Event contract (SSE), Skill Catalog (SKILL.md + progressive disclosure), Tool
Registry + política por agente, PluginLoader (manifesto + entry + skills),
AgentProfile, Runner, endpoint SSE. → é o `agent_runtime` atual.

### Fase 1 — Pipeline & Plataforma
Implementar a pipeline canônica (RFC-0002) end-to-end: Command Bus + Commands
iniciais; Context Builder + Providers (RFC-0005); Policy Engine; Middleware
pipeline; Lifecycle Hooks (wrappers); Runtime Executor; Task Engine in-process
(fiber + cancelamento + checkpoint); Session/Task/Checkpoint Stores (RFC-0006);
Registries restantes (Workflow, Prompt, Policy); autodiscovery de plugin por gem
(RFC-0003); Service Platform (HTTP/SSE/WS).

### Fase 2 — Avançado
Actor mailbox completa; Sessions como Actors; Capability Registry (RFC-0004);
Tool Search; memória cross-session + Skill Workshop (RFC-0005); tools externas
(MCP/webhook); bridge de observabilidade (`harness-instrumentation`);
cost/approval/tenant policies.

### Fase 3 — Ecossistema
Gems `harness-*` com autodiscovery; registry público de skills/plugins; adapter
A2A de borda para federação; SDKs.

## Mapeamento com o código atual (`agent_runtime`)

| Conceito                       | Arquivo                              | Status | RFC   |
|--------------------------------|--------------------------------------|--------|-------|
| Event Stream (projeção SSE)    | `lib/agent_runtime/event.rb`         | feito  | 0002  |
| Skill Catalog                  | `lib/agent_runtime/skill_catalog.rb` | feito  | 0005  |
| Progressive disclosure         | `tools/load_skill.rb` + catalog      | feito  | 0005  |
| Tool Registry                  | `lib/agent_runtime/tool_registry.rb` | feito  | 0003  |
| Policy Engine (allow/deny)     | `lib/agent_runtime/agent_profile.rb` | parcial| 0002  |
| Plugin System                  | `lib/agent_runtime/plugin_loader.rb` | feito  | 0003  |
| Runtime Executor (mínimo)      | `lib/agent_runtime/runner.rb`        | feito  | 0002  |
| Context Builder (base)         | `lib/agent_runtime/system_prompt.rb` | evolui | 0005  |
| Service Platform (HTTP/SSE)    | `app/server.rb` + `config.ru`        | feito  | —     |
| Pipeline canônica              | — (Runner é esboço linear)           | fase 1 | 0002  |
| Command Bus                    | —                                    | fase 1 | 0002  |
| Context Providers/Builder      | — (evolui do system_prompt)          | fase 1 | 0005  |
| Middleware + Hooks             | —                                    | fase 1 | 0002  |
| Task Engine / Actors           | —                                    | fase 1→2 | 0002 |
| Session/Task/Checkpoint Stores | —                                    | fase 1 | 0006  |
| Workflow / Prompt / Policy Reg.| —                                    | fase 1 | —     |
| Capability Registry            | —                                    | fase 2 | 0004  |
| Observability bridge           | —                                    | fase 2 | —     |

## Decisões pendentes (bloqueiam release público)

- Nome/namespace do projeto (RFC-0001 §8).
- Stateless vs stateful como default da API pública.
