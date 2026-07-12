# HANDOFF — Fase 4 (Harness Studio) · onde paramos

> **Atualizado:** 2026-07-12 · **main @** merge PR #27 (`8035d3a`)
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

**Progresso do plano: 5/20 tasks (Etapas A + B).** Ver `tasks/tasks.md`.

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

### Prova de "rodar de verdade"
- Turno real multi-turn (DeepSeek): Bia chama `current_time`/`menu`/`calc`/`load_skill`,
  lembra do nome entre turnos. (`scripts/run_real.rb`, `scripts/serve_real.rb`.)
- **CRUD em runtime provado:** agente "chef" criado via `:create_agent` → editado →
  **respondeu** (`status: completed`) → removido, tudo pelo BUS, sem restart.

## 4. Estado atual dos testes

`bundle exec rspec` → **908 examples, 0 failures** (sem chave de API; `require "ruby_llm"`
continua lazy — restrição D9 do core preservada). O "boom" no log é fixture intencional.

## 5. PRÓXIMO PASSO — Etapa C (tasks 6-8)

**Catálogos graváveis + workspace + prompts/skills por-agente.** Fecha a limitação
conhecida (ver §6). Escopo:
- Task 6: escrita + `reload` em `SkillCatalog`/`PromptCatalog` (troca atômica do índice).
- Task 7: workspace por agente + `:write_agent_file`/`:delete_agent_file` + snapshots.
- Task 8: `:restore_agent_file` + `:write_skill` + `:set_skill_agents`.
- **D3 revisado:** o conteúdo deve viver no **Store** (não só disco). Decidir na Etapa C
  se o catálogo passa a ser store-backed OU se materializa em disco + reload.

Depois: D (memória/settings/LLM) → E (app Roda + auth + assets) → F (páginas de autoria)
→ G (mcp/settings/system-files/chats) → H (polish). Ver `tasks/tasks.md`.

## 6. Limitação conhecida a resolver (crítica p/ o produto)

**Prompts não são por-agente ainda.** O `Context::Providers::Prompt` lê os `files:` do
WIRING (`config/deployment.rb` → `IDENTITY_FILES` da Bia), **não** `profile.prompt_files`.
Por isso um agente novo (ex.: "chef") **herda o prompt da Bia**. Para "cada um cria sua
BIA com identidade própria" funcionar, o Prompt provider precisa ler do profile/Store —
é o coração da **Etapa C** (+ tocar `context/providers/prompt.rb`).

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
