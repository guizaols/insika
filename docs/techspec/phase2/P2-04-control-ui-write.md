# P2-04 — Control UI de escrita (Hotwire/Turbo sobre o SSE)

> **RFC base:** 0007 §3-§6. **Evolui:** `server/admin/` (read-only da Fase 1),
> `server/app.rb`, `server/admin_auth.rb`. **Overview:** D5, D6, D7.

## Objetivo

Transformar o `/admin` read-only da Fase 1 em **read-write**: a tela Tasks ganha
pause/resume/cancel/approve; Config edita perfis/políticas; Chat testa o agente.
Server-rendered com **Hotwire/Turbo sobre o SSE existente** (RFC-0007 §4), auth
de operador para ações destrutivas e **evento de auditoria por ação** (§5).

## Estado atual (Fase 1)

- `Admin::App` (ERB stdlib, `render`, `nav`, `style`, `h` p/ escape XSS) — só
  GET; qualquer método ≠ GET → 404. Headers CSP + `nosniff`.
- `AdminAuth.check(config_token, header)` fail-closed (Bearer). CORS estrito por
  `allowed_origins`. Pipeline `handle_admin` no `Server::App` (preflight/auth/CORS).
- `events.erb` já consome `/v1/events` via `EventSource` (o canal de streaming).
- O painel é "só mais um cliente da API": as ações POSTarão os Commands já
  existentes na rota genérica `POST /v1/commands/:type` (Fase 1).

## Decisões

### L1 — Hotwire/Turbo vendored, SEM pipeline de build (fiel a L3 da Fase 1)
Turbo + Stimulus entram como **assets estáticos servidos pelo `harness-server`**
(arquivos JS vendored em `server/admin/assets/`, servidos por uma rota
`GET /admin/assets/*`). Zero npm/importmap-rails/build. Mantém o princípio "núcleo
pequeno, zero asset pipeline" — só troca ERB puro por ERB + Turbo. (Se vendored
pesar, a alternativa é `<script type="module">` de CDN — mas CDN externa colide
com a CSP; vendored local é a escolha, e a CSP ganha `script-src 'self'`.)

### L2 — Ações = POST de Command via `turbo_stream`, resposta = Turbo Stream
Cada botão (pause/resume/cancel/approve) é um `<form>` que POSTa para uma rota
`/admin/...` fina que **traduz para o Command** (mesma tradução que a rota legada
faz, Fase 1) e responde `text/vnd.turbo-stream.html` atualizando o fragmento da
task. Não é caminho de negócio novo: o `/admin` monta o Command e despacha no
mesmo bus. (Alternativa considerada: o form POSTar direto em `/v1/commands/:type`
— mas aí a resposta é JSON, não Turbo Stream; a rota fina do `/admin` existe só
para devolver HTML/Turbo ao browser.)

### L3 — Atualização ao vivo = Turbo Streams projetados do Event Stream
A tela Tasks/Chat abre um `turbo-stream` source apontando para
`/admin/events.turbo_stream` (um `SSEBody` que, em vez de `data: {json}`, emite
`data: <turbo-stream ...>` renderizado a partir de cada `Event`). Reusa o
`EventStream`/`SSEBody` (Fase 1) — o wire muda de JSON para markup Turbo. Sem
WebSocket, sem segundo canal (RFC-0007 §4).

### L4 — Auth de operador para MUTAÇÃO; leitura como na Fase 1
`AdminAuth` (Bearer) continua para todo o `/admin`. As rotas de **mutação**
(`POST /admin/...`) exigem o mesmo token — e, como são ações destrutivas,
**cada uma emite `:operator_action`** no Event Stream (D6): operador (do token/
proxy), ação, alvo, timestamp. Auditoria é observável em `/v1/events` e no painel.
CSRF: como a auth é Bearer (não cookie), não há CSRF de browser clássico; ainda
assim o `Origin` é checado (CORS estrito já barra cross-site).

### L5 — Config read-write com validação, escrevendo onde o wiring lê
Editar perfil/política escreve num store de config (ou no `AgentProfile` runtime,
conforme o wiring expõe). **Na fatia A**, Config edita o que é seguro em runtime
sem reboot: `approvals_required`, `tools_deny`, limites — via um `UpdateProfile`
Command (controle) validado. Perfis são `Data` imutáveis (Fase 1) → editar =
substituir a entrada no registro de perfis (composition root expõe um setter).
Mudança estrutural (novos perfis do zero) fica para fatia seguinte.

### L6 — Chat = `send_message` + render do stream
A tela Chat é um form que POSTa `send_message` (via a rota fina) e renderiza o
`/admin/events.turbo_stream` filtrado por `task_id`. É o "testar o agente no
painel" (RFC-0007 §3) reusando o pipeline inteiro — zero caminho especial.

## Interfaces / Rotas novas (`/admin`, todas server-rendered)

| Rota | Ação | Resposta |
|------|------|----------|
| `POST /admin/tasks/:id/pause` | Command `pause_task` | turbo_stream do card da task |
| `POST /admin/tasks/:id/resume` | Command `resume_task` | idem |
| `POST /admin/tasks/:id/cancel` | Command `cancel_task` | idem |
| `POST /admin/approvals/:pending_id` | Command `approve_action` (`decision`) | turbo_stream da pendência |
| `POST /admin/config/profiles/:id` | Command `update_profile` | turbo_stream do form de config |
| `POST /admin/chat` | Command `send_message` | turbo_stream + abre stream filtrado |
| `GET  /admin/events.turbo_stream` | projeção Turbo do Event Stream | SSE de `<turbo-stream>` |
| `GET  /admin/assets/*` | Turbo/Stimulus vendored | JS estático (`content-type` js; cache) |

As rotas de mutação são **read-write** (só POST); GET nelas → 404. Continuam sob
`AdminAuth` + CORS (pipeline `handle_admin` estendido para aceitar POST em
`/admin/*`).

## Files to Touch

| Ação | Arquivo | Descrição |
|------|---------|-----------|
| MODIFY | `server/app.rb` | `handle_admin` aceita POST em `/admin/*`; injeta `command_bus` no `Admin::App` (via wiring); auditoria |
| MODIFY | `server/admin/app.rb` | roteamento read-write; render de turbo_stream; rota de assets; projeção `events.turbo_stream` |
| MODIFY | `server/admin_auth.rb` | (se preciso) helper p/ extrair identidade do operador p/ o `:operator_action` |
| CREATE | `server/admin/assets/turbo.min.js`, `stimulus.min.js` | vendored (L1) |
| CREATE | `server/admin/views/tasks.erb` (evolui) | botões pause/resume/cancel; card com `turbo-stream` target |
| CREATE | `server/admin/views/task.erb` (evolui) | aprovar/rejeitar pendências; executions ao vivo |
| CREATE | `server/admin/views/chat.erb`, `config.erb` | Chat + Config (L5/L6) |
| CREATE | `server/admin/views/_task_card.turbo_stream.erb` etc. | parciais de turbo_stream |
| CREATE | `lib/harness/commands/update_profile.rb` | Command de config (L5) |
| MODIFY | `config/wiring.rb` | expor setter de perfil; injetar `command_bus` no Admin; `:operator_action` |
| MODIFY | catálogo D5 | `:operator_action` |
| CREATE | `spec/harness/server/admin_write_spec.rb` | cada ação → Command certo + turbo_stream + `:operator_action`; auth destrutivo; GET nas rotas de mutação → 404 |
| CREATE | `spec/harness/server/admin_events_turbo_spec.rb` | projeção Turbo do Event Stream |

## Edge Cases

1. **POST de mutação sem token** → 503/401 (fail-closed, como a Fase 1); nunca
   executa a ação.
2. **Aprovar/pausar task inexistente** → o Command levanta NotFound → mapeado
   pelo `handle_admin` (turbo_stream de erro ou 404 HTML).
3. **XSS** → todo valor dinâmico nas views e nos turbo_streams por `h()` (Fase 1);
   os assets vendored são estáticos (CSP `script-src 'self'`, sem inline novo).
4. **Ação destrutiva sem auditoria** → proibido: `handle_admin` emite
   `:operator_action` ANTES de responder (D6), mesmo em falha do Command
   (registra a tentativa).
5. **Cliente sem JS/Turbo** → os forms são `<form method=post>` normais; sem
   Turbo o POST recarrega a página (degradação graciosa) — o painel continua
   funcional, só sem live-update.
6. **CSP vs assets** → `script-src 'self'` (não `'unsafe-inline'` para scripts de
   app); o Stimulus controller vive em arquivo vendored, não inline.

## Testing (resumo)
- Cada rota de mutação: POSTa → bus recebe o Command certo → responde
  `text/vnd.turbo-stream.html` → emite `:operator_action`. GET nelas → 404.
- Auth: mutação sem token → 503/401; com token → 200/turbo.
- `events.turbo_stream`: cada `Event` vira um `<turbo-stream>` no wire.
- Config: `update_profile` valida e substitui a entrada; inválido → erro sem
  corromper o perfil corrente.
- Rack::MockRequest + duplos (como `admin_app_spec` da Fase 1). Sem `ruby_llm`/chave.
