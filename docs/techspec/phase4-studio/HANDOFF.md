# HANDOFF — Fase 4 (Harness Studio) · onde paramos

> **Atualizado:** 2026-07-12 (Etapa C) · **main @** merge PR #27 (`8035d3a`)
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
| **Etapa C** | **Prompts/skills por-agente: `AgentFileStore`+`SkillStore` (store-backed, D3 revisado), overlay+`reload` de catálogo, Prompt provider lê `profile.prompt_files`, 5 Commands (`:write/delete/restore_agent_file`, `:write_skill`, `:set_skill_agents`)** | PR aberto |

**Progresso do plano: 8/20 tasks (Etapas A + B + C).** Ver `tasks/tasks.md`.

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

### Prova de "rodar de verdade"
- Turno real multi-turn (DeepSeek): Bia chama `current_time`/`menu`/`calc`/`load_skill`,
  lembra do nome entre turnos. (`scripts/run_real.rb`, `scripts/serve_real.rb`.)
- **CRUD em runtime provado:** agente "chef" criado via `:create_agent` → editado →
  **respondeu** (`status: completed`) → removido, tudo pelo BUS, sem restart.

## 4. Estado atual dos testes

`bundle exec rspec` → **908 examples, 0 failures** (sem chave de API; `require "ruby_llm"`
continua lazy — restrição D9 do core preservada). O "boom" no log é fixture intencional.

## 5. PRÓXIMO PASSO — Etapa D (tasks 9-11)

**Memória + Settings + LLM.** Escopo:
- Task 9: Commands de memória (`:memory_put_fact`/`:memory_forget_fact`/`:memory_add_note`) + leituras.
- Task 10: ConfigStore settings/llm_providers + `:update_settings` + masking sentinel `__OCULTO__`.
- Task 11: `LLMConfigurator` — reconfigure runtime por provider + `:upsert/delete_llm_provider`.

Depois: E (app Roda + auth + assets) → F (páginas de autoria) → G (mcp/settings/
system-files/chats) → H (polish). Ver `tasks/tasks.md`.

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
export HARNESS_DB=/caminho/harness.db  # opcional: persiste config+execução (SQLite)

ruby scripts/serve_real.rb             # sobe /admin + /v1 em http://localhost:9292
#   /admin/chat  → converse (agente: bia · session_id: web)
#   /admin/events, /admin/sessions/web, /admin/tasks
ruby scripts/run_real.rb               # 2 turnos multi-turn no terminal
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
