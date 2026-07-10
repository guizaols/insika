# Techspec Fase 2 (fatia A) — Actor completo + Aprovação + Control UI de escrita

> Segue o mesmo processo da Fase 1 (HANDOFF-TECHSPEC.md): RFC = "o quê e porquê";
> este doc + os componentes `P2-01`–`P2-04` = "como, exatamente". A RFC-0001 é a
> constituição. Evolui o código da Fase 1 (`lib/harness/`, `server/`), não
> recomeça.
>
> **Fonte da verdade:** RFC-0002 §9 (faseamento do Actor), RFC-0007 (Control UI),
> BACKLOG "Fase 2 — Avançado".

## Escopo desta fatia

O BACKLOG lista a Fase 2 inteira (Actors, Capability Registry, Tool Search,
memória, MCP/webhook, observabilidade, policies de custo/tenant). Esta techspec
cobre **só a primeira fatia coesa**, escolhida por assentar diretamente sobre os
stubs que a Fase 1 deixou prontos:

**Faz:**
1. **Mailbox completa do Actor** (RFC-0002 §9): `approval`, `timeout`,
   `heartbeat`, `pause`, `resume` — hoje o `TaskActor` só tem `cancel`
   (`user_message` é reservado). Ativa os estados `:waiting`/`:paused` que o
   `TaskStore` já reserva.
2. **Human-in-the-loop / `ApproveAction`** (RFC-0007 §3, doc 00 §D "ApproveAction
   é Fase 2"): uma ação sensível pausa o turno em `:waiting`, registra um
   *Pending Action* durável, e o operador aprova/rejeita via Command. Fecha o elo
   que a `PolicyDenied` da Fase 1 só sabia negar.
3. **Sessions como Actors** (RFC-0002 §9): uma `Session` vira um Actor que
   **serializa os turnos** daquela sessão (fila FIFO), eliminando a corrida de
   dois `send_message` concorrentes no mesmo `session_id`.
4. **Control UI de escrita** (RFC-0007 §3-§5): a tela Tasks ganha
   pause/resume/cancel/approve; Config edita perfis/políticas; Chat testa o
   agente. Server-rendered com **Hotwire/Turbo sobre o SSE existente** (§4), auth
   de operador para ações destrutivas (§5) e **evento de auditoria** por ação.

**Não faz (fases/fatias seguintes):** Capability Registry (RFC-0004), Tool
Search, memória cross-session (RFC-0005 §6), tools externas MCP/webhook, bridge
de observabilidade, policies de custo/tenant, Postgres/lease-lock/GC. WebSocket
(o painel fica em SSE + POSTs de Command, RFC-0007 §4).

## Como esta fatia evolui a Fase 1 (costuras já prontas)

| Costura da Fase 1 | Onde | O que a Fase 2 faz |
|---|---|---|
| `TaskActor::MESSAGES = %i[cancel user_message]`, `drain!` só nas fronteiras | `lib/harness/task_actor.rb` | estende o enum + o `drain!` para `approval`/`pause`/`resume`/`timeout`/`heartbeat` |
| `TaskStore::STATUSES` já inclui `:waiting`/`:paused`; `TRANSITIONS` já permite `running→waiting/paused` | `lib/harness/task_store.rb` | passa a EMITIR essas transições (hoje nenhum caminho as usa) |
| Executor drena a mailbox só nas fronteiras de estágio (L2) | `lib/harness/executor.rb` | novos handlers de mensagem; ponto de suspensão em `:waiting`/`:paused` |
| Commands de controle (`CreateSession`, `CancelTask`) + turno (`SendMessage`, `ResumeTask`, `TriggerWorkflow`) | `lib/harness/commands/` | novos: `PauseTask`, `ResumeTask` (já existe — reusar), `ApproveAction` |
| `/admin` read-only (ERB stdlib, `AdminAuth` fail-closed, CORS) | `server/admin/` | vira read-**write** com Hotwire/Turbo; `AdminAuth` ganha ação destrutiva |
| Event Stream + SSE (`/v1/events`, `SSEBody`) | `lib/harness/event_stream.rb`, `server/` | Turbo Streams projetados sobre o mesmo SSE; eventos de auditoria novos (D5 estendido) |
| `supervised` (turnos filhos do supervisor de vida-longa, L4) | `lib/harness/executor.rb` | o `SessionActor` (Fase 2) roda no mesmo escopo supervisionado |

## Decisões globais desta fatia

### D1 — `:waiting` = "aguardando entrada/aprovação"; `:paused` = "suspenso por operador"
Dois estados distintos que a Fase 1 já reserva. `:waiting` é auto-induzido pelo
turno (pediu aprovação/input, vocabulário `INPUT_REQUIRED` do A2A, RFC-0002 §9);
`:paused` é induzido pelo operador (Command `PauseTask`). Ambos são
não-terminais e retomáveis pelo caminho do `ResumeTask` (D3 da Fase 1: recovery
e resume manual usam o mesmo caminho).

### D2 — Pending Action é um RECORD durável, não um booleano
Fiel ao princípio "estado como registro" (RFC-0001). Uma ação sensível cria um
`PendingAction` no store (quem pediu, qual tool/args, quando, turno) e a task vai
a `:waiting`. `ApproveAction` resolve o record (approved/rejected + operador +
timestamp) e posta `:approval` na mailbox. Sobrevive a `kill -9` (o operador
aprova depois do reboot — o recovery reidrata a task em `:waiting`).

### D3 — Aprovação é enforcement de POLICY, não caminho novo
A decisão "esta tool exige aprovação" nasce no estágio 3 (Policy Engine). Uma
nova builtin `ApprovalRequired` (allowlist por tool/agente) marca a tool; o
`ToolEnvelope` (Fase 1) passa a, antes de executar uma tool marcada, criar o
`PendingAction`, emitir `:approval_requested` e **suspender o turno** em
`:waiting`. Zero caminho paralelo — reusa Policy + Envelope + mailbox.

### D4 — Sessions como Actors: 1 fiber por sessão, fila FIFO de turnos
Hoje cada `send_message` vira uma Task com fiber próprio; dois no mesmo
`session_id` corriam no transcript. A Fase 2 introduz o `SessionActor`: o
`send_message` com `session_id` não spawna direto — **enfileira** no actor da
sessão, que executa um turno por vez (serialização). Sessão sem fila = comporta
igual à Fase 1. One-shot/history (sem `session_id`) continua Task avulsa, sem
actor. O `SessionActor` vive no escopo supervisionado (L4).

### D5 — Control UI de escrita: Hotwire/Turbo sobre o SSE, mesmos Commands
O painel é só mais um cliente da API (RFC-0007 §4): as ações POSTam os mesmos
Commands que qualquer consumidor (`PauseTask`/`ApproveAction`/...). As atualizações
ao vivo são **Turbo Streams renderizados a partir do Event Stream** (o mesmo
`/v1/events`), sem canal novo. Turbo/Stimulus entram como assets estáticos
servidos pelo `harness-server` (sem pipeline de build — importmap/CDN-vendored,
detalhado em P2-04). Sem SPA, sem WebSocket.

### D6 — Auth de operador reforçada + auditoria por ação (RFC-0007 §5)
`AdminAuth` fail-closed continua (Fase 1). Ações **destrutivas/mutantes** exigem
sessão de operador autenticada e **CADA uma emite um evento de auditoria** no
Event Stream (`:operator_action`, com operador + ação + alvo). `allowed_origins`
explícito permanece. O `/admin` continua separado da rota de API do consumidor.

### D7 — Catálogo de eventos (D5 da Fase 1) estendido, não reaberto arbitrariamente
Novos tipos: `:task_paused`, `:task_resumed`, `:approval_requested`,
`:approval_resolved`, `:operator_action`. Registrados no catálogo canônico
(00-overview D5 da Fase 1). `:waiting`/`:paused` viram estados terminais-parciais
observáveis em `GET /v1/tasks/:id`.

## Componentes (docs a detalhar)

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `P2-01-actor-mailbox.md` | Mailbox completa + estados `:waiting`/`:paused` + `PauseTask` + suspensão/retomada | 0002 §9 |
| `P2-02-approval.md` | `PendingAction` store + policy `ApprovalRequired` + `ToolEnvelope` gate + `ApproveAction` | 0002 §9, 0007 §3 |
| `P2-03-sessions-as-actors.md` | `SessionActor` (fila FIFO por sessão) + integração no `SendMessage`/Executor | 0002 §9 |
| `P2-04-control-ui-write.md` | Hotwire/Turbo write surface + operator auth + auditoria + Chat/Config | 0007 §3-§6 |

## Plano de tarefas (resumo — detalhe em `tasks/tasks.md`)

Ordem por dependência: mailbox → aprovação → sessions-actors → UI. A UI depende
de todo o resto (ela expõe pause/approve). Ver `tasks/tasks.md` para a tabela
completa, dependências e complexidade.

## Critério de conclusão da fatia

1. Um turno que aciona uma tool marcada `approval` **suspende em `:waiting`**,
   sobrevive a `kill -9`, e é **aprovado pelo operador** pós-reboot → a tool
   executa e o turno conclui (smoke E2E, análogo ao da Fase 1).
2. Dois `send_message` concorrentes no mesmo `session_id` são **serializados**
   (transcript consistente, sem entrelaçamento).
3. `PauseTask`/`ResumeTask` de um turno em voo transita `:paused`↔`:running`.
4. O `/admin` executa pause/approve/cancel e edita config, cada ação com evento
   de auditoria; ações destrutivas exigem auth de operador.
5. Suíte inteira verde sem chave de API (RubyLLM mockado só na integração) —
   herda o critério de testabilidade da Fase 1.
