# Task 25: Esqueleto Control UI `/admin` read-only (ERB) + `AdminAuth` fail-closed + CORS

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [07-service-platform.md](../07-service-platform.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Adicionar ao `Server::App` a superfície `/admin` **read-only** da Fase 1
(Sessions, Tasks, Events ao vivo, Skills, Plugins — doc 07 §2, RFC-0007)
renderizada com ERB da stdlib (L3), protegida por `AdminAuth` fail-closed
(Bearer de `HARNESS_ADMIN_TOKEN`; sem token configurado → 503) e CORS estrito
por `allowed_origins`.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 24 | Rotas formais: `POST /v1/commands/:type` + açúcar, reads GET, `/v1/events` SSE, rota legada | ⬜ TODO |

## Context

O Control UI completo (pause/approve/config, Hotwire/Turbo) é Fase 2/3
(RFC-0007 §4); a Fase 1 entrega **só o esqueleto read-only** (handoff §3.7,
doc 07 §1). A decisão L3 é explícita: **ERB da stdlib, zero deps, zero asset
pipeline** — SSE + ERB entregam o "Events ao vivo". Tudo aqui é leitura de
stores/catálogos/registries já injetados no `App` (task 24); nenhum Command é
despachado a partir do `/admin`.

A auth é a mínima de operador (RFC-0007 §5): Bearer token estático. A regra
inegociável é **fail-closed**: sem `HARNESS_ADMIN_TOKEN` configurado, o
`/admin` responde 503 "admin disabled" — nunca aberto por omissão (doc 07 §2
e §6).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `server/admin_auth.rb` | `Harness::Server::AdminAuth` — Bearer de `HARNESS_ADMIN_TOKEN`, fail-closed |
| CREATE | `server/admin/app.rb` | roteamento + render das 6 rotas `/admin*` (read-only) |
| CREATE | `server/admin/views/index.erb` | índice com links para as seções |
| CREATE | `server/admin/views/sessions.erb` | lista de sessões |
| CREATE | `server/admin/views/session.erb` | transcript de uma sessão |
| CREATE | `server/admin/views/tasks.erb` | lista de tasks |
| CREATE | `server/admin/views/task.erb` | status/executions/checkpoints de uma task |
| CREATE | `server/admin/views/events.erb` | Events ao vivo (EventSource → `/v1/events`) |
| CREATE | `server/admin/views/skills.erb` | Skill Catalog (nível 1 + corpo) |
| CREATE | `server/admin/views/plugins.erb` | plugins carregados + tools/workflows por registry |
| MODIFY | `server/app.rb` | montar `/admin` (AdminAuth → CORS → Admin::App); passar `checkpoint_store` (ver Notes) |
| MODIFY | `config/wiring.rb` | `admin_token: ENV["HARNESS_ADMIN_TOKEN"]`, `allowed_origins` no `config` |
| CREATE | `spec/harness/server/admin_auth_spec.rb` | 503/401/200 (doc 07 §7) |
| CREATE | `spec/harness/server/admin_app_spec.rb` | render das rotas com duplos + CORS |

### Step-by-Step Instructions

#### Step 1: `AdminAuth` — fail-closed

**File:** `server/admin_auth.rb`

Interface do doc 07 §2:

```ruby
module AdminAuth                # RFC-0007 §5
  # Bearer token de HARNESS_ADMIN_TOKEN (obrigatório p/ /admin).
  # Sem token configurado → /admin responde 503 "admin disabled"
  # (nunca aberto por omissão — fail-closed).
end
```

Implementar como módulo com um método puro, testável sem Rack:

```ruby
# frozen_string_literal: true

module Harness
  module Server
    # Auth mínima de operador (RFC-0007 §5). Fail-closed por construção:
    # sem token configurado, o /admin não existe para o mundo (503).
    module AdminAuth
      module_function

      # config_token: vem de config[:admin_token] (wiring lê HARNESS_ADMIN_TOKEN)
      # header: valor cru de Authorization
      # -> :ok | :disabled | :unauthorized
      def check(config_token, header)
        return :disabled if config_token.nil? || config_token.empty?

        provided = header.to_s[/\ABearer (.+)\z/, 1]
        return :unauthorized unless provided
        return :unauthorized unless Rack::Utils.secure_compare(config_token, provided)

        :ok
      end
    end
  end
end
```

Mapeamento no App (doc 07 §6): `:disabled` → **503** corpo
`{"error":{"class":"Harness::Error","message":"admin disabled"}}`;
`:unauthorized` → **401** (incluir header `www-authenticate: Bearer`);
`:ok` → segue para o Admin::App. Use `Rack::Utils.secure_compare`
(comparação em tempo constante — evita timing attack no token de operador).

#### Step 2: CORS estrito por `allowed_origins`

**File:** `server/admin/app.rb` (helper privado) e integração no `server/app.rb`

Doc 07 §3: config do servidor é
`{ bind:, port:, admin_token:, allowed_origins: [] }` — `allowed_origins`
aplicado como **CORS estrito em `/admin`** (RFC-0007 §5):

- Request com header `Origin` presente: se o valor constar **exatamente** em
  `config[:allowed_origins]`, incluir na resposta
  `access-control-allow-origin: <origin>` e `vary: origin`; caso contrário,
  **nenhum** header CORS (o browser bloqueia — estrito = allowlist exata, sem
  `*`, sem sufixos).
- `OPTIONS /admin/...` (preflight) com Origin permitida → 204 com
  `access-control-allow-methods: GET` e
  `access-control-allow-headers: authorization`; Origin não permitida → 204
  sem headers CORS.
- Sem header `Origin` (curl, mesma origem) → sem headers CORS, fluxo normal.
- Lista default `[]` = nenhuma origem cross-site permitida (fail-closed
  coerente com o AdminAuth).

Ordem de aplicação no `App#call` para `path` começando com `/admin`:
preflight OPTIONS (não exige auth — browsers não mandam Authorization em
preflight) → `AdminAuth.check` → CORS headers na resposta → render.

#### Step 3: Roteamento e render do `/admin`

**File:** `server/admin/app.rb`

Rotas da tabela do doc 07 §2 (Fase 1, **read-only** — só GET; qualquer outro
método em `/admin*` → 404):

| Rota | Conteúdo (Fase 1, read-only) |
|------|------------------------------|
| `GET /admin` | índice |
| `GET /admin/sessions[/:id]` | lista/transcript (SessionStore) |
| `GET /admin/tasks[/:id]` | lista/status/executions/checkpoints |
| `GET /admin/events` | Event Stream ao vivo (a mesma `/v1/events` renderizada) |
| `GET /admin/skills` | Skill Catalog (nível 1 + corpo) |
| `GET /admin/plugins` | plugins carregados + tools/workflows por registry |

Estrutura: classe `Harness::Server::Admin::App` recebendo
`session_store:, task_store:, checkpoint_store:, catalogs:, registries:,
event_stream:` (subconjunto do que o `Server::App` da task 24 já tem — ele
repassa). Roteamento explícito como na task 24 (L1 vale para o admin também).

Render com **ERB da stdlib** (L3 — sem Hotwire, sem asset pipeline):

```ruby
require "erb"
require "cgi"

def render(view, locals = {})
  template = File.read(File.join(VIEWS_DIR, "#{view}.erb"))
  html = ERB.new(template, trim_mode: "-").result_with_hash(locals)
  [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
end
```

**Escapar TODO valor interpolado com `CGI.escapeHTML`** — transcripts e
payloads contêm conteúdo de usuário/modelo (ver Edge Cases #1). Convencione um
helper `h(value)` disponível nas views. CSS mínimo inline no layout (uma tag
`<style>` no topo de cada view ou parcial compartilhada) — zero assets
externos.

#### Step 4: Conteúdo das views

**Files:** `server/admin/views/*.erb`

- **`index.erb`**: links para as cinco seções.
- **`sessions.erb`**: itera `session_store.each_id` + `find` — tabela com
  `id`, nº de mensagens, `updated_at`, link para o detalhe. (`each_id` existe
  no SessionStore exatamente para o Control UI — doc 02 §2.)
- **`session.erb`**: `session_store.find(id)` — `vars` e transcript
  (`role`/`content`/`at` por mensagem). `nil` → 404.
- **`tasks.erb`**: `task_store.each_id` + `find` — tabela com `id`, `status`,
  `session_id`, nº de executions, `updated_at`.
- **`task.erb`**: `task_store.find(id)` — status, command (`type` + payload),
  tabela de Executions (`attempt`, `started_at`, `finished_at`, `outcome`,
  `error`) e o checkpoint mais recente via
  `checkpoint_store.latest(task_id)` (`turn`, `created_at`,
  `completed_side_effects`, tamanho de `messages`). `nil` → 404.
- **`events.erb`**: "Events ao vivo" = a mesma `/v1/events` renderizada
  (doc 07 §2). Página HTML com `<script>` inline usando `EventSource` para
  `/v1/events` (mesma origem) e appendando cada `data:` num `<pre>`/lista.
  Inputs opcionais `task_id`/`session_id` que remontam a URL com query string.
  Isso cumpre L3: SSE + ERB, zero deps. (Limitação de auth via browser: ver
  Notes.)
- **`skills.erb`**: `catalogs[:skills].all` — nível 1 (`name`, `description`,
  `path`) + corpo (`body`) em `<details><pre>` por skill.

  **Reference pattern from codebase**
  (`docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb`
  — o shape que a view consome; o catálogo migra inalterado na Fase 1):

  ```ruby
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    def all
      @skills.values
    end
  ```

- **`plugins.erb`**: plugins carregados + tools/workflows **por registry**.
  Derivar dos próprios registries: `Registry::Entry` carrega `plugin:`
  (doc 06 §2) — agrupar `registries[:tools].entries` e
  `registries[:workflows].entries` por `entry.plugin` (`nil` = registrado
  direto no wiring/sistema). Exibir por plugin: id + tools (com `metadata` —
  `optional`, `side_effect`) + workflows. Não exigir uma lista separada de
  plugins no construtor (ver Notes).

#### Step 5: Integração no `Server::App` + wiring

**Files:** `server/app.rb`, `config/wiring.rb`

- No `App#call` (task 24), o branch `path.start_with?("/admin")` deixa de
  responder 404 e passa a: OPTIONS/CORS (Step 2) → `AdminAuth.check(
  config[:admin_token], env["HTTP_AUTHORIZATION"])` → delegar ao
  `Admin::App`, aplicando os headers CORS à resposta.
- `Server::App#initialize` ganha `checkpoint_store:` (leitura apenas —
  necessário para a coluna "checkpoints" de `/admin/tasks/:id`; ver Notes
  sobre a assinatura do doc 07 §2). A regra constitucional se mantém:
  `server/` só **lê** stores.
- `config/wiring.rb`: preencher
  `config: { ..., admin_token: ENV["HARNESS_ADMIN_TOKEN"], allowed_origins:
  ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",") }` e injetar
  `CHECKPOINT_STORE` no `App`.

### Edge Cases to Handle

1. **XSS**: ERB stdlib não escapa nada — todo `content` de transcript, nome de
   skill, payload de command etc. passa por `CGI.escapeHTML` antes de ir ao
   HTML. É a superfície onde conteúdo de usuário/LLM encontra o browser do
   operador.
2. **Token configurado como string vazia** (`HARNESS_ADMIN_TOKEN=""`) →
   tratar como não configurado → 503 (fail-closed; string vazia nunca é um
   token válido).
3. **Header sem o prefixo `Bearer `** (token cru, `Basic ...`) → 401.
4. **Sessão/task inexistente** em `/admin/sessions/:id` / `/admin/tasks/:id`
   → 404 (página simples, não JSON).
5. **Task sem checkpoint** (`latest` → nil) → view mostra "sem checkpoint",
   não quebra.
6. **Preflight OPTIONS** não carrega Authorization → não pode exigir auth;
   mas também não vaza nada (resposta 204 vazia).
7. **`allowed_origins` vazio** (default) → nenhuma origem cross-site; o
   painel continua acessível same-origin/curl com o token.
8. **Stores grandes**: `each_id` é enumeração completa — aceitável para o
   esqueleto Fase 1 (single-node, volume de dev); paginação é Fase 2. Não
   otimizar aqui.

## Testing

### Unit Tests

**File:** `spec/harness/server/admin_auth_spec.rb` (doc 07 §7: sem token→503, errado→401, certo→200)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| sem token configurado | `check(nil, "Bearer x")` e request a `/admin` sem `admin_token` | `:disabled` / HTTP 503 "admin disabled" |
| token vazio configurado | `check("", ...)` | `:disabled` / 503 |
| token errado | `check("s3cret", "Bearer nope")` | `:unauthorized` / 401 + `www-authenticate` |
| sem header | `check("s3cret", nil)` | `:unauthorized` / 401 |
| formato errado | `check("s3cret", "s3cret")` (sem `Bearer `) | `:unauthorized` / 401 |
| token certo | `check("s3cret", "Bearer s3cret")` | `:ok` / 200 na rota |
| comparação constante | implementação usa `secure_compare` | verificado por spy/leitura do código |

**File:** `spec/harness/server/admin_app_spec.rb` (`Rack::MockRequest` + stores/catalogs/registries duplos; token correto no header)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| índice | `GET /admin` | 200 text/html com links para as 5 seções |
| lista de sessões | store duplo com 2 sessões | 200; ids presentes no HTML |
| transcript | `GET /admin/sessions/:id` | mensagens renderizadas; conteúdo escapado |
| escape XSS | mensagem com `<script>alert(1)</script>` | HTML contém `&lt;script&gt;`, nunca a tag crua |
| sessão inexistente | `find` → nil | 404 |
| lista de tasks | duplo com tasks em vários status | 200; status visíveis |
| detalhe de task | task com 2 executions + checkpoint duplo | executions e dados do checkpoint no HTML |
| task sem checkpoint | `latest` → nil | 200 com "sem checkpoint" |
| events ao vivo | `GET /admin/events` | 200 HTML contendo `EventSource` apontando para `/v1/events` |
| skills | catálogo duplo com 2 skills | nível 1 (name/description) + corpo presentes |
| plugins | registries duplos com entries `plugin: "weather"` e `plugin: nil` | agrupamento por plugin; tools/workflows listados com metadata |
| read-only | `POST /admin/...` | 404; bus-espião nunca recebe dispatch a partir de `/admin` |
| CORS permitido | `GET /admin` com `Origin` ∈ allowed_origins | `access-control-allow-origin` = origem + `vary: origin` |
| CORS negado | `Origin` fora da lista | resposta **sem** headers CORS |
| preflight | `OPTIONS /admin/tasks` com Origin permitida | 204 + allow-methods GET + allow-headers authorization |
| preflight negado | Origin não permitida | 204 sem headers CORS |

### Integration Tests (if applicable)

Não há integração além do Rack (as views consomem duplos). O smoke E2E da
task 26 cobre o boot com o `/admin` montado.

## Definition of Done

- [ ] Seis rotas `/admin*` do doc 07 §2 renderizando read-only com ERB stdlib (L3 — zero deps novas)
- [ ] `AdminAuth`: sem token → 503 fail-closed; errado → 401; certo → 200; comparação em tempo constante
- [ ] CORS estrito por `allowed_origins` (allowlist exata, default vazio)
- [ ] Todo conteúdo dinâmico escapado (`CGI.escapeHTML`)
- [ ] `/admin` não despacha nenhum Command e não escreve em store algum
- [ ] `config/wiring.rb` lê `HARNESS_ADMIN_TOKEN` / origins para o `config`
- [ ] Suíte roda sem `ruby_llm` instalado e sem API key
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já
  estiverem implementadas quando você pegar esta task, leia o código real —
  ele prevalece sobre o estado planejado aqui.
- **Lacuna na assinatura do doc 07 §2:** `App#initialize` não lista
  `checkpoint_store:`, mas a rota `/admin/tasks[/:id]` exibe "checkpoints".
  A menor extensão fiel é adicionar o kwarg (leitura apenas, via
  `CheckpointStore#latest` — doc 02 §2). Registrado como lacuna, não
  re-decisão.
- **Lista de plugins:** o doc 07 §2 pede "plugins carregados"; a fonte
  escolhida são as `Entry#plugin` dos registries (doc 06 §2) — evita criar um
  canal novo wiring→App. Se a task 21/22 expuser a lista de `Plugin` do
  `Loader#load_all` de forma acessível ao wiring, pode-se enriquecer a view;
  opcional.
- **Auth via browser:** `EventSource` e navegação normal não enviam header
  `Authorization` — na prática o operador acessa `/admin` via curl, extensão
  que injeta o header ou reverse proxy que o adiciona. É a auth "mínima de
  operador" da Fase 1 (doc 07 §1); esquema de cookie/query-token é Fase 2
  (Control UI completo). Não inventar workaround aqui. Consequência prática:
  no `events.erb`, o `EventSource` aponta para `/v1/events` (API do
  consumidor, fora do `/admin`) — funciona sem header.
- Convenções: `# frozen_string_literal: true`, comentários em português,
  ERB/CGI da stdlib, classes pequenas.

---

## Conclusão

- **Concluído em:** 2026-07-10
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 31 novos (admin_auth 7, admin_app 24) + ajuste do app_spec; 0 falhas (606 total)
- **Arquivos criados:** `server/admin_auth.rb`, `server/admin/app.rb`, 9 views ERB
  (`index/sessions/session/tasks/task/events/skills/plugins/not_found`),
  `spec/harness/server/admin_auth_spec.rb`, `spec/harness/server/admin_app_spec.rb`
- **Arquivos modificados:** `server/app.rb` (mount `/admin`: preflight/auth/CORS +
  `checkpoint_store:`), `config/wiring.rb` (admin_token/allowed_origins + CHECKPOINT_STORE),
  `spec/harness/server/app_spec.rb` (o `/admin` sem token agora é 503, não 404)
- **Observações / desvios:**
  - `App#initialize` ganhou `checkpoint_store:` (lacuna da assinatura do doc 07
    §2; leitura apenas — regra constitucional preservada).
  - Fonte da lista de plugins = `Entry#plugin` dos registries (evita canal novo
    wiring→App); agrupa tools/workflows por plugin (nil = "(sistema)").
  - `events.erb` usa `EventSource` → `/v1/events` (same-origin, sem header de
    auth — API do consumidor; auth de operador via curl/proxy é a "mínima" da
    Fase 1, doc 07 §1).
  - **Code review (fan-out, foco em segurança):** sem bug crítico. Aplicados 2
    hardenings: CSP + `nosniff` nas páginas (defense-in-depth) e `strip`/`reject`
    em `allowed_origins`. O preflight OPTIONS sempre-204 foi confirmado seguro
    pelo revisor (sem body, CORS só p/ origem permitida, GET ainda exige token).
