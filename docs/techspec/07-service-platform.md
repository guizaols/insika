# Techspec 07 — Service Platform (HTTP/SSE formal) + esqueleto do Control UI

> Formaliza o Service Platform (RFC-0001 §4: transportes só traduzem
> requisições em Commands) e o esqueleto do Control UI (RFC-0007). O endpoint
> SSE da Fase 0 vira uma rota do contrato formal, preservando o consumidor
> atual. O Control UI completo é Fase 2/3 — aqui entra só o esqueleto
> read-only (handoff §3.7).

## 1. Objetivo e fronteira

**Faz:** tabela de rotas formal; tradução request→Command (nenhuma lógica no
transporte); SSE como projeção do Event Stream; endpoint legado da Fase 0
mantido; boot sequenciado (plugins → recovery → listen); esqueleto `/admin`
(Sessions, Tasks, Events ao vivo — **read-only**); auth mínima de operador.

**Não faz:** WebSocket (RFC-0007 §4: só se o painel precisar — não precisa na
Fase 1); CLI/SDKs (Fase 3); Control UI de escrita (pause/approve/config —
Fase 2, depende de `ApproveAction`); multi-tenant no painel (RFC-0007 §7.2);
auth do endpoint de consumidor além de token estático (operacionalizado no
deploy — o Harness não conhece canais).

## 2. Interfaces públicas

### Rotas — API do consumidor

| Rota | Command/leitura | Resposta |
|------|-----------------|----------|
| `POST /v1/commands/:type` | genérica: body → `Command.build(type, payload, transport: :http)` → bus | controle: 200 JSON; turno: 202 `{task_id}` |
| `POST /v1/sessions` | açúcar p/ `create_session` | 201 `{session}` |
| `POST /v1/messages` | açúcar p/ `send_message`; `?stream=true` (default) | SSE de eventos da task; `stream=false` → 200 JSON agregado no `:done` |
| `GET  /v1/sessions/:id` | leitura direta SessionStore (não é Command — D3) | 200 `{session}` |
| `GET  /v1/tasks/:id` | leitura TaskStore | 200 `{task}` |
| `GET  /v1/events?task_id=&session_id=` | `EventStream.subscribe` | SSE contínuo |
| `POST /agent/messages` | **legado Fase 0** → traduz p/ `send_message` | SSE idêntico à Fase 0 |

### Rotas — admin surface (RFC-0007)

| Rota | Conteúdo (Fase 1, read-only) |
|------|------------------------------|
| `GET /admin` | índice |
| `GET /admin/sessions[/:id]` | lista/transcript (SessionStore) |
| `GET /admin/tasks[/:id]` | lista/status/executions/checkpoints |
| `GET /admin/events` | Event Stream ao vivo (a mesma `/v1/events` renderizada) |
| `GET /admin/skills` | Skill Catalog (nível 1 + corpo) |
| `GET /admin/plugins` | plugins carregados + tools/workflows por registry |

```ruby
module Harness
  module Server
    class App                       # Rack app (evolui app/server.rb)
      def initialize(command_bus:, event_stream:, session_store:, task_store:,
                     checkpoint_store:, catalogs:, registries:, config:)
      # checkpoint_store: leitura em /admin/tasks/:id (checkpoints da task)
      def call(env)                 # roteamento explícito; sem framework (L1)
    end

    class SSEBody                   # evolui SSEStream
      def initialize(subscription:, heartbeat: 15)
      def each(&blk)                # "data: {json}\n\n"; heartbeat ": ping\n\n"
    end

    class Boot
      def initialize(wiring)
      def call                      # plugins → stores → recovery.run → listen
    end

    module AdminAuth                # RFC-0007 §5
      # Bearer token de HARNESS_ADMIN_TOKEN (obrigatório p/ /admin).
      # Sem token configurado → /admin responde 503 "admin disabled"
      # (nunca aberto por omissão — fail-closed).
    end
  end
end
```

## 3. Modelos de dados / schemas

- **Wire de evento (SSE):** `data: {"type":"content","delta":"...","meta":{"task_id":"t-1","seq":7,"at":"..."}}\n\n`
  — exatamente `Event#to_h` (D5). O legado `/agent/messages` emite o mesmo
  shape (o `meta` é aditivo; consumidor Fase 0 ignora chaves novas).
- **Erros HTTP:** `{"error": {"class": "Harness::ValidationError", "message": "..."}}`
  com status: `ValidationError`→422, `NotFoundError`→404, demais→500. Apenas
  erros **síncronos** (antes do fiber, doc 03 §6) viram status HTTP;
  `PolicyDenied` acontece dentro do fiber, após o 202/SSE aberto, e portanto
  viaja como evento `:policy_denied`/`:task_failed` no stream (e fica em
  `GET /v1/tasks/:id`) — nunca como 403. O mapeamento 403 fica **reservado**
  para um eventual dispatch síncrono futuro.
- **`stream=false`:** o transporte assina os eventos da task e agrega:
  responde no `:done`/`:task_failed` com
  `{content:, task_id:, events: [...opcional...]}`.
- Config do servidor: `{ bind:, port:, admin_token:, allowed_origins: [] }` —
  `allowed_origins` aplicado como CORS estrito em `/admin` (RFC-0007 §5).

## 4. Fluxo de controle

```
requisição ─► App#call
   ├─ rota de Command → parse JSON → Command.build → bus.dispatch
   │     ├─ controle → serializa resultado (síncrono)
   │     └─ turno    → {task_id} 202  OU  SSE:
   │           subscription = event_stream.subscribe(task_id:)
   │           bus.dispatch (fiber da task começa)
   │           SSEBody drena a subscription até evento terminal
   ├─ rota de leitura → store.find → serializa (nunca vira Command — D3)
   └─ /admin → AdminAuth → render server-side (ERB puro, L3) / SSE de eventos

boot (ordem obrigatória):
  wiring (plugins/registries/catalogs) → stores → Recovery.run (doc 02 §4)
  → Falcon listen                        # nunca aceita request antes do recovery
```

O transporte contém **zero lógica de negócio**: valida JSON bem-formado e
traduz; validação de payload é do handler (doc 03 §3). Regra constitucional
"transportes só traduzem" auditável: `server/` não importa Executor, stores de
escrita além de leitura, nem RubyLLM.

## 5. Concorrência

- Falcon: um fiber por conexão (D9). SSE de longa duração = fiber parqueado
  na `Async::Queue` da subscription — perfil para o qual o Falcon existe
  (README da Fase 0).
- `SSEBody` com heartbeat de 15s (comentário SSE `: ping`) mantém proxies e
  detecta cliente morto → fecha a subscription (senão a fila do subscriber
  vaza — doc 03 L4).
- Um cliente lento acumula na própria fila; cap de 1000 eventos por
  subscription → estourou, a subscription fecha com evento `:error` local
  (o turno da task **nunca** espera transporte).
- Boot single-fiber (doc 06 §5).

## 6. Erros e timeouts

- Mapeamento HTTP em §3. JSON malformado → 400 antes de qualquer dispatch.
- Task de turno que falha após o 202/SSE aberto: o erro chega por
  `:task_failed`/`:error` no stream ou via `GET /v1/tasks/:id` (o estado
  terminal fica no Task Store — nada se perde se o cliente desconectou).
- Desconexão do cliente durante SSE: fecha subscription; a task **continua**
  (a execução pertence ao runtime, não à conexão — é isso que os stores
  compram; o cliente reconecta em `/v1/events?task_id=`).
- `/admin` sem token configurado → 503 (fail-closed, RFC-0007 §5); token
  errado → 401.
- Timeout de request síncrono (controle): 10s → 504 (não deveria acontecer;
  indica store travado).

## 7. Estratégia de testes

- **Contrato de rotas** com `Rack::MockRequest` + bus/stores duplos: cada
  rota traduz para o Command certo com o payload certo; leituras não passam
  pelo bus; mapeamento de erro→status completo.
- **Contrato do legado (regressão Fase 0):** `POST /agent/messages` com
  `{agent, message, history}` → mesma sequência de tipos de evento da Fase 0
  (`:content`* → `:done`), shape compatível.
- **SSE:** eventos na ordem, heartbeat presente, fechamento no terminal;
  cliente desconecta → subscription fechada, task segue (spy no executor
  duplo); cap de fila.
- **Boot:** ordem plugins→recovery→listen (spies); request antes do fim do
  recovery é impossível por construção (listen é o último passo — teste de
  integração com Falcon em porta efêmera).
- **AdminAuth:** sem token→503, errado→401, certo→200.
- Smoke E2E (CI, sem API key): subir Falcon + backend **SQLite em tmpdir**
  (Memory não sobrevive a kill — é o ponto do teste) + RubyLLM mockado;
  `POST /v1/messages` com `session_id`; `kill -9` no meio de um turno; subir
  de novo apontando o mesmo arquivo; verificar task retomada (nova Execution,
  transcript íntegro) — o critério de conclusão da fase (doc 00 §6).

## 8. Evolução a partir da Fase 0

- `app/server.rb` → `server/app.rb`: o lambda de rota única vira roteamento
  explícito; `SSEStream` → `SSEBody` (agora drena o EventStream em vez de
  receber o bloco do Runner); a rota legada preserva o contrato.
- `config.ru` → chama `Server::Boot` (que executa o recovery antes do `run`).
- `config/wiring.rb` → continua o único composition root; `APP` passa a ser
  construído com as dependências injetadas (hoje usa constantes globais —
  mantidas como atalho, mas a classe aceita injeção para teste).

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Rack puro com roteamento explícito (sem Sinatra/Roda) | são ~10 rotas; uma dependência de framework no `harness-server` compra pouco e o núcleo pequeno é princípio; revisitar se o Control UI da Fase 2 crescer |
| L2 | `POST /v1/commands/:type` genérica + rotas de açúcar | a genérica garante que TODO Command novo já tem transporte (D3: transporte não conhece semântica); as de açúcar dão ergonomia aos dois fluxos quentes |
| L3 | ERB da stdlib para o /admin (sem Hotwire ainda) | RFC-0007 §4 decide Hotwire/Turbo para o painel completo (Fase 2); o esqueleto read-only da Fase 1 não justifica o asset pipeline — SSE + ERB entregam o "Events ao vivo" com zero deps |
| L4 | Task sobrevive à desconexão do cliente | é a materialização do valor dos stores; ligar execução à conexão reintroduziria o acoplamento que a RFC-0006 elimina |
| L5 | Rota legada mantida por (pelo menos) toda a Fase 1 | o Agent.Shop consome hoje; migração de consumidor é assíncrona da migração de runtime |
| L6 | Heartbeat SSE de 15s | menor valor que atravessa os idle timeouts comuns (ALB 60s, nginx 60s) com folga; comentário SSE não polui o consumidor |
