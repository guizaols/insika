# HANDOFF — Fase 4 (Harness Studio) · onde paramos

> **Atualizado:** 2026-07-12 (Etapa F) · **main @** merge PR #31 (`449668c`)
> Documento de retomada: uma sessão nova continua daqui **sem** o histórico do chat.
> Leia junto com [`00-overview.md`](./00-overview.md) (spec) e [`tasks/tasks.md`](./tasks/tasks.md) (plano).

---

## 1. O que é este projeto

**harness** = runtime de agentes de IA em Ruby (Async/Falcon, RFC-driven, CQRS,
durável). Análogo ao *gateway* do OpenClaw (`/Users/guizaols/projetos/tedi/openclaw`),
**não** ao frontend React. Fases 0-3 (runtime, capabilities, memória, A2A) estão
completas e mergeadas. **Fase 4 = Harness Studio**: uma UI de gestão server-rendered
(substituto do `agent-studio` React do OpenClaw) para criar/configurar agentes,
prompts, skills, tools, MCP, settings e memória — **um processo, um deploy, uma
linguagem**. Meta de produto: *substituir o OpenClaw pra qualquer um* — `clone → chave
→ ruby serve → studio no ar`.

## 2. Decisões travadas (não re-litigar sem motivo)

- **Framework na borda, core puro.** `lib/harness` e `server/` continuam biblioteca
  Ruby sem framework. O Studio será um app **Roda** em `studio/` (D1).
- **Hotwire, não React.** As 9 páginas do agent-studio são lista+form+toggles+editor+
  chat-viewer; zero canvas/drag. Único island pesado: **CodeMirror**.
- **Assets: esbuild + `dist/` versionado** (D8) — `ruby serve` roda sem Node.
- **Topologia: multi-agent, single-tenant por ora.** **SQLite em produção** (volume
  persistente); Postgres + multi-tenant **adiados** (a costura `Store`/`tenant` já
  permite habilitar depois sem reescrever).
- **D3 revisado:** conteúdo de prompts/skills vive no **Store** (fonte única), não em
  disco; arquivo vira só import/export/seed.

## 3. O que já está feito e mergeado

| Etapa/PR | Entrega | Estado |
|---|---|---|
| #23 | Deployment real (DeepSeek) + fix do seam `:vars` | merged |
| #24 | Control UI `/admin` repaginada (Hotwire/Turbo, tool-cards, bolhas) | merged |
| #25 | `serve_real.rb` (servidor HTTP single-process) + multi-turn | merged |
| **#26 (Etapa A)** | **`ConfigStore` + `ProfileSource` (Static/Stored) + refactor Executor/Commands p/ profiles dinâmicos** | merged |
| **#27 (Etapa B)** | **CRUD de agente em runtime (`:create/update/delete_agent`, `:set_agent_tools`) + deployment com profiles dinâmicos + SQLite-aware** | merged |
| **#29 (Etapa C)** | **Prompts/skills por-agente: `AgentFileStore`+`SkillStore` (store-backed, D3 revisado), overlay+`reload` de catálogo, Prompt provider lê `profile.prompt_files`, 5 Commands (`:write/delete/restore_agent_file`, `:write_skill`, `:set_skill_agents`)** | merged |
| **#30 (Etapa D)** | **Memória + Settings + LLM: 3 Commands de memória (`:memory_put_fact/forget_fact/add_note`), `SettingsStore` + `:update_settings`, `SecretMasking` (sentinel `__OCULTO__`), `LLMProviderStore` (masked) + `LLMConfigurator` (reconfigure RubyLLM runtime) + `:upsert/delete_llm_provider`** | merged |
| **#31 (Etapa E)** | **Primeira UI: app `studio/` (Roda) sob `/studio` + login por cookie (D7) + CSRF + CSP estrita; pipeline esbuild/Tailwind → `dist/` versionado (D8); shell/layout + páginas login/agents(list)/playground(SSE)** | merged |
| **Etapa F** | **Páginas de autoria: agents(detail) — config/model + prompts (island `code-editor`) + skills + memória (tenant=agente) + histórico; skills (matriz + editor, `write_skill`/`set_skill_agents`); tools (matriz `set_agent_tools`); viewer read-only de sessão. Correção: normalização UTF-8 dos segmentos de path do Roda (bug de encoding vs SQLite `get`)** | PR aberto |

**Progresso do plano: 17/20 tasks (Etapas A + B + C + D + E + F).** Ver `tasks/tasks.md`.

### Arquivos-chave criados/alterados (na main)
- `lib/harness/config_store.rb` — KV durável de configuração (scopes agents/settings/
  llm_providers/mcp) sobre o backend `Store`.
- `lib/harness/profile_source.rb` — `ProfileSource` (contrato `source[id] → profile|nil`),
  `StaticProfileSource` (Hash legado, zero regressão), `StoredProfileSource`
  (ConfigStore ↔ AgentProfile, **re-simboliza provider/policies/limits** no round-trip).
- `lib/harness/commands/{create,update,delete}_agent.rb`, `set_agent_tools.rb`,
  `agent_payload.rb` — autoria de agente em runtime.
- `config/deployment.rb` — backend durável-aware (`HARNESS_DB`→SQLite senão Memory),
  `PROFILE_SOURCE = StoredProfileSource`, Bia semeada idempotente, 4 Commands no BUS.
- Executor + Commands de turno + `server/a2a/app.rb`: normalizam via
  `ProfileSource.coerce` (Hash → StaticProfileSource). **Corpos `@profiles[agent]`
  inalterados; wiring/deployment/specs não mudaram.**

**Etapa C (prompts/skills por-agente):**
- `lib/harness/agent_file_store.rb` — workspace por agente store-backed (scope
  `agent_files`): `read/list/write/delete/versions/restore`, history com teto.
- `lib/harness/skill_store.rb` — skills autoradas store-backed (scope `skills`), mesmo
  contrato de versionamento.
- `lib/harness/context/providers/prompt.rb` — **o fix central**: `agent_files:` +
  `build_identity(profile)` lê `profile.prompt_files` (Store→disco fallback); vence os
  `files:` do wiring. Sem prompt_files = default do deployment (paridade Fase 0).
- `lib/harness/skill_catalog.rb` — overlay do `SkillStore` (Store vence disco) + `reload`
  (troca atômica); `lib/harness/prompt_catalog.rb` — `reload` de paridade.
- `lib/harness/commands/{write,delete,restore}_agent_file.rb`, `write_skill.rb`,
  `set_skill_agents.rb` — 5 Commands (hot via reload/ProfileSource).
- `lib/harness/config_store.rb` — scopes `agent_files`/`skills`; `config/deployment.rb` —
  `AGENT_FILE_STORE`/`SKILL_STORE`, catálogo com overlay, provider com `agent_files:`, +5 no BUS.

**Etapa E (app Roda + auth + assets + primeiras páginas):**
- `studio/app.rb` — `Studio::App` (Roda). FRAMEWORK NA BORDA: `lib/harness` e `server/`
  NÃO ganham Roda. Plugins `sessions`+`route_csrf`+`content_security_policy`+`render`.
  `configure(command_bus:/profile_source:/event_stream:/config:)` injeta as deps (mesma
  superfície do `Server::App`); secret de sessão deriva do `admin_token` (estável entre
  restarts). Auth fail-closed por `Rack::Utils.secure_compare`. Rotas: `/login`,
  `/logout`, `/agents`, `/playground` (GET+POST), `/assets/dist/*`, 404 amigável.
- `studio/views/*.erb` — layout (app-bar + flash + nav) + login + agents (grid, lê
  `ProfileSource#all`) + playground + not_found. ERB com escape automático (erubi).
- `studio/assets/src/` + `dist/` — bundle esbuild (D8): `application.js` (Stimulus +
  Turbo + islands `live-transcript`/`code-editor` com CodeMirror 6), `application.css`
  (Tailwind base + design system em `@layer components`). **dist versionado** (`ruby
  serve` sem Node); `package.json`/`tailwind.config.js` só p/ quem edita o front.
- `scripts/serve_real.rb` — monta `/studio` via `Rack::URLMap` (Studio cookie-auth +
  resto no `Server::App` com o shim de Bearer). CSRF session-bound (`require_request_
  specific_tokens: false`) por causa do PATH_INFO pós-mount. CSP estrita `'self'` (sem
  `unsafe-inline`; todo asset same-origin).
- Gemfile: `roda`/`tilt`/`erubi` (só na borda `studio/`). `.gitignore`: `node_modules/`
  ignorado, `assets/dist/` versionado.

**Etapa D (memória + settings + LLM):**
- `lib/harness/commands/{memory_put_fact,memory_forget_fact,memory_add_note}.rb` — memória
  editável por HTTP (não só via tool `remember`); escopada por `tenant` (payload ou meta).
- `lib/harness/secret_masking.rb` — sentinel `__OCULTO__` (`mask`/`reconcile`/`present?`):
  segredo nunca volta em plaintext; sentinel preserva, "" limpa, string nova substitui.
- `lib/harness/settings_store.rb` + `commands/update_settings.rb` — settings gerais duráveis
  (streaming/timeouts/compaction) com DEFAULTS + deep-merge; `:update_settings` faz patch.
- `lib/harness/llm_provider_store.rb` — providers de LLM store-backed, `api_key` mascarada nas
  leituras de UI (`get`/`all`), real só em `get_raw`/`all_raw` (pro configurator).
- `lib/harness/llm_configurator.rb` — reaplica `<api>_api_key=`/`<api>_api_base=` no RubyLLM
  em runtime (require lazy, D9; `configure:` injetável p/ teste sem a gem); provider não
  reconhecido -> `skipped` (degrada "restart recomendado"), resto aplica.
- `commands/{upsert,delete}_llm_provider.rb` — CRUD de provider; upsert reconfigura runtime.
- `config/deployment.rb` — `SETTINGS_STORE`/`LLM_PROVIDER_STORE`/`LLM_CONFIGURATOR` + 6 no BUS.

### Prova de "rodar de verdade"
- Turno real multi-turn (DeepSeek): Bia chama `current_time`/`menu`/`calc`/`load_skill`,
  lembra do nome entre turnos. (`scripts/run_real.rb`, `scripts/serve_real.rb`.)
- **CRUD em runtime provado:** agente "chef" criado via `:create_agent` → editado →
  **respondeu** (`status: completed`) → removido, tudo pelo BUS, sem restart.

## 4. Estado atual dos testes

`bundle exec rspec` → **1003 examples, 0 failures** (sem chave de API; `require "ruby_llm"`
continua lazy — restrição D9 do core preservada; o `LLMConfigurator` recebe `configure:`
falso nos specs). O "boom" no log é fixture intencional. `spec/studio/app_spec.rb` (41 ex.)
usa doubles de bus/profile_source/stores — o Studio só lê e despacha, não escreve em store
direto; a Etapa F inclui uma regressão SQLite-real do bug de encoding de path (ver §5).

## 5. PRÓXIMO PASSO — Etapa G (tasks 18-19): **mcp/settings/system-files/chats**

A Etapa F entregou as **páginas de autoria** — o Studio agora edita a BIA de ponta a
ponta (config, prompts, skills, tools, memória, histórico). Falta a Etapa G (depende de
E+F): página de **settings** gerais + **providers/models de LLM** (masked-secret,
dynamic-form) e **MCP**; página **system-files** + **chats** (viewer read-only,
`live-transcript`). Depois: H (polish & paridade). Ver `tasks/tasks.md`.

### O que a Etapa F entregou (arquivos)
- `studio/app.rb` — `configure` ganhou os stores de LEITURA (agent_file/skill/tool/
  memory/session; opcionais). Rotas novas: `/agents/:id` (detalhe) + `config`/`prompts`
  (write/delete/restore)/`skills`/`memory` (fact/forget/note, **tenant = id do agente**);
  `/skills` (index+matriz) + `/skills/:name` (editor) + `POST /skills` (write_skill) +
  `/skills/:name/agents` (set_skill_agents); `/tools` (matriz) + `POST /tools/:id`
  (set_agent_tools, deny preservado); `/sessions/:id` (viewer read-only). Toda escrita
  passa pelos Commands B–D; o Studio nunca escreve em store direto.
- `studio/views/{agent_detail,skills,skill_edit,tools,session}.erb` + `agents.erb` (card
  clicável). Islands `code-editor` (prompts/skills) e design system reaproveitados.
- `studio/assets/src/application.css` (+ `dist/` rebuildado): componentes de autoria
  (seções, matriz por cards, check-grid, kv de memória, histórico, transcript read-only).
  **Sem JS/CSS inline** (CSP estrita: nada de `onsubmit=`/`style=`); matriz é card+checkbox
  (não `<form>` dentro de `<table>`, que é HTML inválido).
- `scripts/serve_real.rb` — injeta os stores de leitura no `Studio::App.configure`.

### ⚠️ Bug de encoding do Roda (corrigido na F — não regredir)
O matcher `String` do Roda entrega o segmento de path em **ASCII-8BIT** (binário). O
`ConfigStore#get`/`StoredProfileSource#fetch` sobre **SQLite** NÃO casa uma chave gravada
em UTF-8 com uma string binária (o sqlite3 faz bind como BLOB) → `/agents/bia` dava 404
enquanto a LISTA (que usa `all`) funcionava. Sessão/memória escapavam por acaso (prefixam
a chave com um literal UTF-8, coagindo o encoding). Correção na BORDA: `utf8(seg)` normaliza
todo segmento capturado antes de virar chave/payload (`agents/:id`, `skills/:name`,
`tools/:id`, `sessions/:id`). Regressão trava isso com **SQLite real + PATH_INFO binário**
(doubles não reproduzem — `String#==` é encoding-agnóstico p/ ASCII).

**Prova de "rodar de verdade" (Etapa F):** `ADMIN_TOKEN=... DEEPSEEK_API_KEY=...
HARNESS_DB=/tmp/x.db ruby scripts/serve_real.rb`. Por HTTP real (curl, cookie+CSRF): login;
`/agents/bia` 200; **autorei** `IDENTITY.md` (entrou em `prompt_files`), o fato de memória
`cliente_vip=Dona Ana` (tenant=bia), `turn_timeout=99`, a skill `reembolso` e restringi as
tools a `menu` — tudo pelos Commands, tudo **durável no SQLite** (lido de volta do arquivo).
Aí no **playground** perguntei "qual o nome da cliente VIP?" e a **Bia respondeu "Dona Ana"**
(DeepSeek real) — a memória autorada pela UI chegou no turno via `tenant=agente`; o
transcript apareceu no viewer read-only `/studio/sessions/:id`.

### Decisão D3 travada na Etapa C: **conteúdo store-backed**
Prompts por-agente e skills autoradas vivem no **ConfigStore** (scopes novos
`agent_files` e `skills`), não em disco — coerente com o alvo single-tenant/SQLite-com-
volume (um arquivo de backup) e com "core na borda" (FS efêmero na edge). Disco continua
como **seed/import** (precedência: Store vence). Nomes de arquivo em `profile.prompt_files`
referenciam o conteúdo no `AgentFileStore`; caminho absoluto ainda cai em `File.read`
(compat/seed).

## 6. Limitação conhecida — ✅ RESOLVIDA na Etapa C

**Prompts agora são por-agente.** O `Context::Providers::Prompt` recebe um `agent_files:`
(AgentFileStore) e lê `profile.prompt_files` — que **vence** sobre os `files:` do wiring.
Um agente com `prompt_files` próprios usa sua identidade autorada (store-backed, hot);
um agente **sem** `prompt_files` cai no default do deployment (`IDENTITY_FILES`), paridade
byte-a-byte da Fase 0 (zero regressão — 940 examples, 0 failures). "Cada um cria sua BIA
com identidade própria" está provado (`spec/harness/integration/per_agent_prompt_spec.rb`).

## 7. Como rodar / provar (dev local)

```bash
# chave DeepSeek (autorizado): openclaw/.env.local → DEEPSEEK_API_KEY
export DEEPSEEK_API_KEY=...            # NUNCA commitar/logar o valor
export ADMIN_TOKEN=troque-isto         # token de login do Studio (D7); default "local-demo"
export HARNESS_DB=/caminho/harness.db  # opcional: persiste config+execução (SQLite)

ruby scripts/serve_real.rb             # sobe /studio + /admin + /v1 em http://localhost:9292
#   /studio      → Harness Studio (login com o ADMIN_TOKEN) → agents + playground
#   /admin/chat  → converse (agente: bia · session_id: web)
#   /admin/events, /admin/sessions/web, /admin/tasks
ruby scripts/run_real.rb               # 2 turnos multi-turn no terminal

# Editar o front (só quem mexe em CSS/JS; o dist é versionado):
cd studio && npm install && npm run build
```
O `serve_real.rb` tem um `LocalAdminShim` que injeta o Bearer nas rotas `/admin` (o
`/admin` é fail-closed; navegador não manda Authorization) — conveniência de demo local.

## 8. Open questions ainda abertas (spec §9)

1. Tools definidas por dados (sem código Ruby) — Fase 5?
2. Reconfigure de LLM sem restart — o RubyLLM permite trocar provider/key por-chamada?
3. `/chats` WhatsApp-específico (parser de bolhas/carrossel do Tedi) — genérico vs plugin.
4. Migrar A2A/AgentCard p/ `ProfileSource` (hoje leem o Hash antigo em alguns pontos).

## 9. Gotchas / higiene

- **Segredo:** `DEEPSEEK_API_KEY` vive em `openclaw/.env.local`. Nunca imprimir/commitar.
- **Branch `demo-live`** é local descartável (merge deploy+admin, não empurrada) — pode apagar.
- **Round-trip do AgentProfile:** JSON transforma symbol→string; `StoredProfileSource`
  re-simboliza `provider`, `policies` e chaves de `limits` (senão `DEFAULT_LIMITS.merge`
  quebra). Qualquer novo campo symbol precisa entrar nessa normalização.
- **Fluxo de trabalho:** cada etapa = 1 PR; suíte verde; commit convencional terminando em
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; corpo do PR
  terminando em `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Skills do projeto: `/create-techspec-from-jira`, `/create-tasks`, `/create-task`.
