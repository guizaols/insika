# Techspec Fase 4 — Harness Studio (UI de gestão, substituto do agent-studio)

> **Autor:** Claude (AI-generated, pendente de revisão humana)
> **Criado:** 2026-07-12
> **Status:** Draft
> **Base:** main @ merge PR #23/#24/#25 (deployment real + Control UI + serve_real)
> **Fonte da verdade:** RFC-0002 (pipeline canônica), RFC-0004 (capabilities),
> RFC-0005 (context/memory), RFC-0007 (Control UI/serving). Referência de produto:
> `openclaw/app/*` (agent-studio Next.js que este doc replica **server-rendered**).

---

## 1. Contexto & Objetivo

O harness hoje é um **runtime de agentes** com uma **Control UI de operação** (`/admin`:
ler sessões/tasks/eventos + ações de ciclo de vida de task). Falta a camada de
**autoria/gestão de configuração** — criar e configurar agentes, editar prompts e
skills, gerenciar tools/MCP, memória e credenciais de LLM. Essa camada é o
`agent-studio` do OpenClaw.

**Objetivo:** entregar o **Harness Studio** — uma UI de gestão completa, equivalente
ao agent-studio, mas **server-rendered em Ruby (Hotwire)**, num único processo/deploy.
O alvo não é só uso interno: é **substituir o OpenClaw para qualquer pessoa** que
queira rodar agentes. A promessa de adoção: `git clone` → põe a chave → `ruby serve`
→ studio no ar, sem segundo stack, sem CORS, sem dança de token.

### Por que server-rendered (e não React/Next)

Levantamento das 9 páginas do agent-studio (`docs` deste doc, §5) mostra que o produto
é **lista + formulário + toggles + editor de código + chat-viewer**. **Não há**
drag-and-drop de dados, canvas, grafo ou árvore arrastável (o único "arrasto" é o
resize de colunas, cosmético). Nada disso exige um framework de front. O único
componente que genuinamente pede JS de cliente robusto é o **editor de código**
(CodeMirror) — resolvido como um *island* Stimulus. Logo: Hotwire (Turbo + Stimulus)
+ Tailwind entrega o mesmo UX, com um stack só.

### Princípio arquitetural (inegociável)

**Framework na borda, nunca no core.** O runtime (`lib/harness`) continua uma
**biblioteca Ruby pura** (é o moat: Async/Falcon, durável, RFC-driven, A2A). O Studio
é um **app separado** (`studio/`, sobre Roda) que fala com o runtime pela **mesma
superfície de Command + leitura de store** que a API já usa. Assim a API continua
sendo o contrato: quem quiser troca a UI (inclusive plugar o agent-studio React).

---

## 2. Requisitos

### Funcionais

1. **Gestão de agentes (CRUD):** criar, editar (identidade, papel, status, políticas),
   e remover agentes — em **runtime**, sem editar Ruby nem reiniciar.
2. **Prompts:** editar os arquivos de prompt de cada agente (IDENTITY/SOUL/TOOLS/…) num
   editor de código, com histórico/versões e restauração.
3. **Skills:** biblioteca compartilhada + edição do `SKILL.md` + habilitar/desabilitar
   por agente (allowlist). Criar/editar/deletar skill.
4. **Tools:** matriz tool × agente; ligar/desligar por agente/grupo; allow/deny.
5. **MCP:** biblioteca de tipos (read-only) + CRUD de instâncias (credenciais mascaradas).
6. **Settings + LLM:** configs gerais (timeouts, streaming, compaction) + CRUD de
   providers/models de LLM com **chaves mascaradas** (sentinel), aplicáveis em runtime.
7. **Memória:** dashboard de status + leitura/edição de fatos/notas por tenant.
8. **Chat viewer:** visualizar transcripts de sessões (read-only) com tool-calls e
   streaming ao vivo (SSE).
9. **Playground de chat:** enviar mensagens a um agente e ver a resposta ao vivo
   (evolução do `/admin/chat` — o agent-studio não tem, mas é essencial ao produto).
10. **Login:** autenticação por sessão (cookie httpOnly), não Bearer manual.

### Não-Funcionais

- **Um processo, um deploy, uma linguagem.** Assets same-origin (CSP-safe), sem CDN.
- **Core intacto:** `lib/harness` e `server/` (API/A2A) não ganham dependência de
  framework. O Studio é aditivo.
- **Durabilidade:** configuração persiste no backend durável (SQLite) — sobrevive a
  restart, igual aos stores de execução.
- **Segurança:** fail-closed (sem token → sem studio), constant-time compare, segredos
  nunca voltam em plaintext, escape de todo conteúdo de LLM/usuário (XSS), CSRF nos POSTs.
- **Observabilidade:** toda escrita de config audita no EventStream (como o `/admin` já
  faz com `:operator_action`).

---

## 3. Estado atual — o que reusa vs. o que falta

### Já existe e é reusável (base sólida de "operação")

| Capacidade | Onde |
|---|---|
| EventStream + SSE `/v1/events` (filtra task/session) | `server/app.rb:211`, `lib/harness/event_stream.rb` |
| Stores de execução (session/task/checkpoint/pending/memory) com leituras ricas | `lib/harness/*_store.rb` |
| Commands de ciclo de vida (7) + CommandBus | `lib/harness/commands/*`, `command_bus.rb` |
| Control UI read + ações (pause/resume/cancel/approve/chat) + auditoria de operador | `server/admin/app.rb` |
| AdminAuth fail-closed + CORS estrito | `server/admin_auth.rb`, `server/app.rb:132` |
| Catálogos de leitura (Skill/Prompt) + Registries (Tool/Workflow/Capability/Policy) | `lib/harness/*catalog.rb`, `registry.rb` |
| Tool-cards + bolhas + SSE no `/admin` (PR #24) | `server/admin/views/*` |
| `serve_real.rb` (servidor single-process) | `scripts/serve_real.rb` (PR #25) |

### GAPS — o que o Studio precisa e **não existe** hoje

O sistema tem stores de **dados de execução**, mas **nenhum de configuração**. Toda a
superfície de autoria está ausente:

| Gap | Detalhe | Impacto |
|---|---|---|
| **G1. Profiles estáticos** | `PROFILES = {}.freeze` (`config/wiring.rb:104`); profiles reais são hardcoded em Ruby (`config/deployment.rb:74`) e injetados como Hash congelado no Executor e nos Commands de turno. Sem store, sem CRUD, sem reload. | **Bloqueia** criar/editar agente em runtime — é o gap central. |
| **G2. Catálogos read-only** | Skill/PromptCatalog carregam de disco no boot e não têm escrita nem reload. Registries são imutáveis pós-boot (`registry.rb:8`). | Bloqueia autoria de prompts/skills. |
| **G3. Memória sem HTTP** | MemoryStore tem read+write, mas nenhuma rota/Command a expõe (só via tool `remember` dentro do turno). | Bloqueia o painel de memória. |
| **G4. Config de LLM só no boot** | `RubyLLM.configure` lê ENV no boot; modelo é fixo no profile. `CONFIG` é ENV + `.freeze`. | Bloqueia gestão de providers/keys em runtime. |
| **G5. Sem persistência de config** | Não há ConfigStore; nada de settings/providers/mcp persistidos. | Base de tudo acima. |
| **G6. Auth só Bearer** | AdminAuth exige `Authorization: Bearer`, que o navegador não manda ao navegar (daí o `LocalAdminShim` do #25). | UX de login ruim para produto. |
| **G7. Sem pipeline de assets** | `/admin` usa CSS/JS inline. Não escala pra 9 páginas + CodeMirror + Tailwind. | Bloqueia UI de produto. |

---

## 4. Decisões de arquitetura

> Convenção: cada decisão vira base de tasks. `D#` referenciado no `tasks.md`.

### D1 — Camada web: app `studio/` sobre **Roda**, core intacto

Novo diretório `studio/` (irmão de `server/`), montado sob `/studio/*`. **Roda**
(roteador em árvore, ~thin, roda sob Falcon, **sem** ActiveRecord) — não Sinatra
(menos modular), **não Rails** (pesado; ActiveRecord/Puma duplicam e brigam com os
stores + reactor async que já temos). O `server/app.rb` delega `/studio` ao
`Studio::App` (ou o boot monta os dois apps no mesmo endpoint). `lib/harness` e
`server/` **não** ganham dependência de Roda.

**Alternativa considerada:** crescer o Rack bespoke do `/admin`. Rejeitada: 9 páginas +
forms + nested routing vira roteamento à mão custoso; Roda paga por si sem lock-in.

### D2 — Configuração persistente + **profiles dinâmicos** (o gap central, G1/G5)

- **`ConfigStore`** novo (KV sobre o backend durável existente — `Stores::SQLite`),
  escopos: `agents`, `settings`, `llm_providers`, `mcp`. Igual aos stores de execução,
  mas guarda *configuração*. Durável, sobrevive a restart.
- **`AgentProfile` vira dado persistido.** Um profile no ConfigStore serializa os campos
  de `AgentProfile` (§ AgentProfile do levantamento). CRUD via Commands (D-API).
- **`ProfileSource` mutável e recarregável** substitui o `PROFILES` congelado. Executor
  e Commands de turno passam a **resolver o profile no dispatch** (snapshot copy-on-read)
  em vez de fechar sobre um Hash imutável no construtor. Um turno em andamento mantém o
  profile que capturou (imutável para aquele turno) — preserva a semântica atual.

**Risco/cuidado:** é a mudança mais invasiva e toca a costura Executor↔Commands. Isolar
atrás de uma interface (`ProfileSource#fetch(id) -> AgentProfile | nil`), com o Hash
estático de hoje como uma impl (`StaticProfileSource`) e o novo `StoredProfileSource`
como a outra — zero regressão para wiring/deployment existentes.

### D3 — Prompts & skills: **arquivos em workspace** + reload de catálogo (G2)

Autoria escreve arquivos num **workspace dir** por agente (`workspace/agents/<id>/*.md`)
e skills compartilhadas em `workspace/skills/<slug>/SKILL.md` — como o OpenClaw
(arquivos = fonte da verdade, versionáveis, git-friendly). Adiciona:
- **Escrita** nos catálogos (gravar arquivo + validar frontmatter).
- **Reload** (`SkillCatalog#reload` / `PromptCatalog#reload`): rescan + troca atômica do
  índice. Skills/prompts passam a valer **sem restart** (hot). Tools continuam código
  (reload de tool = restart; documentado).
- **Histórico/versões**: snapshots datados na escrita (dir `.history/`), com restore.

### D4 — Tools: **continuam código**; Studio gere allow/deny (G2 parcial)

Tool = classe Ruby registrada no boot (não muda). O Studio **não cria tools**; gerencia
a **allowlist/denylist por agente** — que é config de profile (D2). A matriz tool×agente
lê do ToolRegistry (catálogo) e escreve em `profile.tools_allow/tools_deny`. "Tool
definida por dados" é feature grande e **fora de escopo** (open question §7).

### D5 — Memória: expor MemoryStore por Command + HTTP (G3)

MemoryStore já tem `facts`/`notes`/`get_fact`/`put_fact`/`forget_fact`/`add_note`.
Adiciona Commands (`:memory_put_fact`, `:memory_forget_fact`, `:memory_add_note`) e
leituras no Studio (dashboard read + edição). Escopo por `tenant`.

### D6 — LLM providers/keys: ConfigStore + masking + reconfigure em runtime (G4)

Providers/models/keys no ConfigStore (`llm_providers`). Chaves **nunca** retornam em
plaintext — sentinel `__OCULTO__` (padrão OpenClaw): enviar sentinel preserva, string
nova substitui, `""` limpa. Aplicação: um `LLMConfigurator` reconfigura o `RubyLLM`
(ou resolve por-provider no create_chat do Executor). Meta: **sem restart**; se algum
provider exigir reconfig global, degrada para "restart recomendado" (banner, como o
OpenClaw).

### D7 — Auth: **login por sessão (cookie)**, substitui o shim (G6)

Página `/studio/login` (token único, constant-time compare contra `HARNESS_ADMIN_TOKEN`),
seta cookie **httpOnly, SameSite=Lax**, expira em N dias. Middleware Roda protege
`/studio/*` (fail-closed: sem token configurado → login não valida → studio inacessível).
Substitui o `LocalAdminShim` do #25. CSRF token nos forms POST.

### D8 — Assets: pipeline **esbuild** (Tailwind + Stimulus + CodeMirror), same-origin (G7)

Um build step mínimo (esbuild) empacota Tailwind (JIT), Stimulus e CodeMirror 6 em
`studio/assets/dist/*` servidos same-origin por `/studio/assets/*`. CSP: `script-src
'self'` + `style-src 'self'` (sem `unsafe-inline` no Studio; hashes/nonce se preciso).
**Nota honesta:** isto introduz Node **só para build de assets** (não runtime). Alternativa
sem Node: importmaps + ESM vendorado (estilo Rails/Propshaft) — mais atrito com CodeMirror.
**Decidido:** esbuild (script `npm run build:studio`), com os artefatos `dist/`
**versionados** — `ruby serve` funciona sem Node; Node só para quem edita o front.

### D9 — Islands (Stimulus) — o mínimo de JS, isolado

| Island | Onde | Papel |
|---|---|---|
| `code-editor` | agent-studio, skills, system-files | Embrulha CodeMirror 6 (syntax por extensão, wrap, Cmd+S, validação JSON reativa) |
| `live-transcript` | chats, playground | Turbo Stream via SSE `/v1/events`; render de bolhas/tool-cards (já provado no #24) |
| `dirty-guard` | editores/forms | `beforeunload` + confirm ao trocar de aba com mudança não salva |
| `toggle` | tools, skills, mcp | Toggle por linha via Turbo Frame (round-trip; "otimista" opcional) |
| `dynamic-form` | mcp, settings | Troca de tipo/provider recarrega campos via Turbo Frame; add/remove linha estilo cocoon |
| `masked-secret` | settings, mcp | Reveal/ocultar 👁 de secret mascarado |

---

## 5. Mapa das 9 páginas → capacidades (contrato de paridade)

| Página (agent-studio) | Studio (rota) | Complexidade | Lê | Escreve | Novo backend necessário |
|---|---|---|---|---|---|
| `/` redirect | `/studio` → agents | Nula | — | — | — |
| `/login` | `/studio/login` | Baixa | — | cookie | D7 |
| `/agent-studio` | `/studio/agents` | **Alta** | agentes, config, prompts, skills, model, memória, histórico | profile, arquivos | D2, D3, D5, `code-editor` |
| `/chats` | `/studio/chats` | Alta (render) | sessões, transcripts, tool-calls | **nada (read-only)** | leituras já existem + `live-transcript` |
| `/skills` | `/studio/skills` | Média-baixa | skills-shared, allowlist | SKILL.md, allowlist p/ agente | D3 + escrita catálogo |
| `/tools` | `/studio/tools` | Média | catálogo tools, allow/deny | `profile.tools_allow/deny` | D2, D4 |
| `/mcp` | `/studio/mcp` | Média-alta | tipos MCP, instâncias | `mcp.*` (credenciais) | D6 (ConfigStore mcp) |
| `/settings` | `/studio/settings` | Média-alta | settings, providers/models | settings, LLM providers/keys | D6 |
| `/system-files` | `/studio/system-files` | Média | arquivos allowlisted do workspace | arquivos | D3 (workspace) + `code-editor` |

**Playground (novo, não no agent-studio):** `/studio/playground` — envia `send_message`
com `session_id`, streama a resposta com tool-cards. Evolui o `/admin/chat`.

---

## 6. Contratos de API & Commands (novos)

### Commands CQRS de autoria (novos, no CommandBus)

| Command | Payload | Efeito |
|---|---|---|
| `:create_agent` | `id, name, model, provider, role, status, tools_allow, skills, policies, limits, …` | Persiste profile no ConfigStore; audita |
| `:update_agent` | `id, patch{}` | Merge + valida + persiste; hot via ProfileSource |
| `:delete_agent` | `id, delete_files?` | Remove profile (+ workspace se pedido) |
| `:write_agent_file` | `agent_id, file, content, create_only?` | Grava prompt/skill + snapshot histórico + reload catálogo |
| `:delete_agent_file` | `agent_id, file` | Remove (só skills) |
| `:restore_agent_file` | `agent_id, version` | Restaura versão como nova |
| `:set_agent_tools` | `agent_id, allow[], deny[]` | Atualiza allow/deny do profile (hot) |
| `:write_skill` | `name, content` | Grava skills-shared + reload |
| `:set_skill_agents` | `name, agent_ids[]` | Habilita/desabilita skill em N profiles |
| `:upsert_mcp` / `:delete_mcp` / `:enable_mcp` | `name, type, merchant, env{}` | CRUD instância MCP no ConfigStore |
| `:update_settings` | `patch{}` (timeouts, streaming, compaction) | Persiste settings gerais |
| `:upsert_llm_provider` / `:delete_llm_provider` | `api, baseUrl, authHeader, apiKey(sentinel), models[]` | CRUD provider; reconfigure runtime |
| `:memory_put_fact` / `:memory_forget_fact` / `:memory_add_note` | `tenant, key, value / text` | Edita MemoryStore |

Todos seguem a regra do transporte: validação síncrona → `ValidationError`/`NotFoundError`
→ HTTP direto; escrita audita no EventStream.

### Endpoints do Studio (Roda, sob `/studio`, protegidos por sessão)

GET (HTML, server-rendered): `/studio`, `/studio/agents[/:id]`, `/studio/chats`,
`/studio/skills[/:name]`, `/studio/tools`, `/studio/mcp`, `/studio/settings`,
`/studio/system-files`, `/studio/playground`, `/studio/login`, `/studio/assets/*`.

POST/PATCH/DELETE (Turbo Stream ou 303): despacham os Commands acima via o **mesmo bus**.
Reusam `/v1/events` (SSE) para streaming/realtime. **Nenhuma escrita direta em store** —
tudo por Command (mantém a regra constitucional do `server/`).

---

## 7. Plano de implementação (etapas → PRs)

Ordenado por dependência: **fundação de config → autoria → páginas → polish**. Cada
etapa é 1 PR, suíte verde, convenção de commit do projeto.

| Etapa | PR | Escopo | Depende |
|---|---|---|---|
| **A. Fundação de config** | 1 | `ConfigStore` (KV durável) + `ProfileSource` (Static/Stored) + refactor Executor/Commands p/ resolver profile no dispatch. **Sem UI.** Testes de regressão do turno. | — |
| **B. Commands de autoria (agentes)** | 2 | `:create/update/delete_agent`, `:set_agent_tools` + validações + auditoria. **Sem UI** (testado por spec). | A |
| **C. Catálogos graváveis + workspace** | 3 | Escrita + `reload` em Skill/PromptCatalog; workspace dir; `:write/delete/restore_agent_file`, `:write_skill`, `:set_skill_agents`. | A |
| **D. Memória + Settings + LLM** | 4 | Commands de memória; `ConfigStore` settings/llm_providers; `LLMConfigurator` (reconfigure runtime); masking sentinel. | A |
| **E. App Roda + auth + assets** | 5 | `studio/` (Roda), login por cookie (D7), pipeline esbuild (D8), layout/shell, Stimulus base. Páginas: login + agents(list) + playground. | A–D |
| **F. Páginas de autoria** | 6 | agents(detail: config/prompts/skills/model/tools/memória/histórico) + skills + tools. `code-editor` island. | E |
| **G. MCP + Settings + System-files + Chats** | 7 | mcp, settings (providers/models), system-files, chats(viewer com `live-transcript`). | E, F |
| **H. Polish & paridade** | 8 | dirty-guards, masked-secret, dynamic-form, banner de restart, health chip, empty states, tema. | F, G |

Cada etapa vira `task-NN.md` via `/create-task` (o `tasks.md` detalha).

---

## 8. Riscos & edge cases

| Risco | L | I | Mitigação |
|---|---|---|---|
| Refactor de `ProfileSource` regride o turno | M | A | Interface + impl estática idêntica à de hoje; suite de turno cobre; snapshot copy-on-read |
| Reload de catálogo em concorrência com um turno | M | M | Troca atômica do índice; turno captura catálogo no dispatch |
| Reconfigure de LLM em runtime afeta turnos em voo | M | M | Aplicar por-provider no `create_chat`; degrade p/ "restart recomendado" se global |
| Node no build de assets afasta adotantes | M | M | Versionar artefatos `dist/`; `ruby serve` roda sem Node; build só p/ quem edita front |
| CSP mais estrita no Studio quebra CodeMirror | B | M | `script-src 'self'`, bundle same-origin; sem inline; nonce se necessário |
| Segredos vazando na UI | B | A | Sentinel `__OCULTO__`, nunca retorna plaintext; masked-secret; escape universal |
| CSRF em POSTs de escrita | M | A | Token CSRF por sessão nos forms; SameSite=Lax |
| Escopo explode (paridade 1:1 com OpenClaw) | A | M | MVP por etapa; `/chats` e memória read-first; features WhatsApp-específicas fora |

### Edge cases

1. **Agente `main`/core não deletável/desabilitável** (paridade OpenClaw) — regra no Command.
2. **Allowlist vazia de tools** = "tudo ligado" vs. "nada" — definir semântica explícita (hoje `nil`=todas, `[]`=nenhuma no AgentProfile; UI deve deixar claro).
3. **Skill órfã** (arquivo sumiu mas está na allowlist) — mostrar como órfã, permitir limpar.
4. **Edição concorrente do mesmo arquivo** por 2 operadores — `create_only`/ETag/no-op-se-idêntico.
5. **Profile inválido** salvo (model inexistente) — validar contra providers configurados.

### Rollback

Studio é **aditivo**: `lib/harness` e `server/` intactos. Rollback = não montar `/studio`
e reverter o refactor do `ProfileSource` para `StaticProfileSource` (default). Config no
ConfigStore é ignorada se o Studio não estiver montado.

---

## 9. Open questions

1. **Tools definidas por dados** (sem código Ruby) — fora de escopo agora. Vale como Fase 5?
2. **Multi-tenancy real** no Studio (hoje memória tem `tenant`, mas profiles não) — o Studio é single-operator; multi-tenant é evolução.
3. ~~**Node no build**~~ **DECIDIDO:** esbuild com `dist/` versionado (Node só p/ editar front; `ruby serve` sem Node).
4. **`/chats` WhatsApp-específico**: o parser de bolhas/carrossel/marcadores do OpenClaw é acoplado ao domínio Tedi. O Studio genérico renderiza transcript + tool-calls; o render "WhatsApp" fica como plugin/opcional?
5. **Reconfigure de LLM sem restart**: confirmar que o RubyLLM permite trocar provider/key por-chamada (senão, "restart recomendado" para LLM).
6. **`ProfileSource` e A2A/wiring**: o AgentCard e o inbound A2A leem `PROFILES` — migrar para `ProfileSource` também.

---

## 10. Dependências & blockers

- **Roda** (nova gem, só no app `studio/`) + **esbuild/Tailwind/Stimulus/CodeMirror** (dev deps de front).
- **Etapa A é blocker de tudo** (ConfigStore + ProfileSource). Nada de UI antes dela.
- Reusa: EventStream/SSE, stores de execução, AdminAuth (constant-time compare), CommandBus, o design system e os islands já iniciados no `/admin` (#24).
- Não bloqueado por A2A nem pela Fase 3; convive.

---

> ⚠️ **Spec AI-generated, requer revisão humana.** Atenção especial a §4 D2 (refactor do
> `ProfileSource` — a mudança mais invasiva), §7 (ordem das etapas) e §9 (open questions
> 3 e 5, que afetam custo/UX).
