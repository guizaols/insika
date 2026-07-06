# agent_runtime

Runtime de agentes model-agnostic, standalone, exposto por HTTP com streaming
de eventos. O "Agent Runtime" do OpenClaw como serviço, agora multi-agente:
N skills + N tools dinâmicas, política por agente e plugins.

Não conhece canais. Seu sistema recebe do WhatsApp, chama o runtime com um
`agent` id, recebe streaming de eventos de volta.

## O que reusa do ecossistema (não reinventa)

- Loop de agente: `RubyLLM` (RubyLLM.chat + with_tools/with_instructions).
- Convenção de prompt/skill: **AgentSkills / SKILL.md** (padrão OpenClaw,
  portável p/ Claude Code e Codex).
- Modelo de tools/plugins/allowlist: convenção do **OpenClaw**.

## Skills dinâmicas (progressive disclosure)

Cada skill é um diretório com `SKILL.md` (YAML frontmatter + markdown).
Nível 1: só name+description vão pro prompt. Nível 2: a tool `load_skill`
carrega o corpo sob demanda. O modelo decide quando ativar.

Roots por precedência: workspace `skills/` > skills de plugin. Nome vem do
frontmatter, não da pasta.

## Tools dinâmicas + política por agente

`ToolRegistry` registra tools por nome (análogo a api.registerTool +
contracts.tools). Política aplicada ANTES da chamada ao modelo — o modelo só
vê o que sobra.

- **required** (`optional: false`): sempre disponível, salvo deny.
- **optional** (`optional: true`): só com opt-in via `tools_allow`.
- `tools_allow` não-vazia = conjunto final (não faz merge com defaults).
- `tools_deny` sempre vence.

Skills seguem a mesma allowlist: `nil` = todas, `[]` = nenhuma, `[names]` =
subconjunto. `load_skill` respeita isso.

Perfis são data-driven (não uma subclasse por tenant) — ver `config/wiring.rb`.

## Plugins (modelo OpenClaw)

Cada plugin é um diretório com um manifesto `plugin.yml` (descoberta sem
executar código) + um entry Ruby (registra as tools de verdade). Plugins
podem entregar skills próprias.

```
plugins/weather/
  plugin.yml     # id, entry, module, contracts.tools, tool_metadata, skills
  plugin.rb      # module WeatherPlugin; def self.register(api); ...; end
  skills/weather_report/SKILL.md
```

Regras (fiéis ao OpenClaw): toda tool precisa constar em `contracts.tools`
(senão é ignorada); bundled precisa ser habilitado explicitamente (`enabled`);
skills de plugin entram em baixa precedência; id duplicado -> primeiro vence.

## Contrato de streaming

Cada evento é uma linha SSE `data: {json}\n\n`:

| type            | payload             |
|-----------------|---------------------|
| skill_activated | { name }            |
| tool_call       | { name, arguments } |
| tool_result     | { result }          |
| content         | { delta }           |
| done            | { content }         |
| error           | { message }         |

`load_skill` é traduzido para `skill_activated`.

## Consumo

```bash
curl -N -X POST http://localhost:9292/agent/messages \
  -H 'content-type: application/json' \
  -d '{ "agent": "sales", "message": "voces tem mouse gamer?", "history": [] }'
```

## Arquitetura

```
lib/agent_runtime/
  event.rb           contrato de streaming
  skill_catalog.rb   scaneia SKILL.md, allowlist, nivel-1
  system_prompt.rb   base + SOUL.md + lista de skills
  tool_registry.rb   registro dinamico + politica por agente
  agent_profile.rb   config por agente (tool/skill policy)
  plugin_loader.rb   manifesto -> tools + skill dirs
  tools/load_skill.rb  nivel-2, respeita allowlist
  runner.rb          resolve perfil, monta chat, emite eventos
skills/<n>/SKILL.md  skills do workspace
plugins/<n>/         plugins (manifesto + entry + skills)
tools/               RubyLLM::Tool default do usuario
config/wiring.rb     registry + plugins + catalogo + perfis
app/server.rb        endpoint Rack/SSE
```

Núcleo stateless: quem chama manda o histórico.

## Escala: Tool Search

Para catálogos grandes, o passo seguinte é o Tool Search do OpenClaw — não
expor todo schema no prompt, e sim uma tool que busca no registry e carrega
schemas sob demanda (o mesmo progressive disclosure das skills, aplicado a
tools). Não implementado ainda; o `ToolRegistry` já é a base.

## Notas honestas

- `before_tool_call`/`after_tool_result` são v1.15+; `RubyLLM::Agent` v1.12+.
  Trave a versão no Gemfile e confirme `add_message`/`.chat`.
- Plugins rodam in-process: código confiável. Sanitize entry de terceiros.
- Streaming real exige servidor async (Falcon). Sob Puma, rode num job.
