# Techspec Fase 3 (fatia A) — Adapter A2A de borda (federação inbound)

> Segue o processo das fatias anteriores. RFC = "o quê e porquê"; este doc +
> `P3A-01`/`P3A-02` = "como, exatamente". A RFC-0001 é a constituição. Evolui o
> Service Platform (`server/`) e o composition root (`config/wiring.rb`), não
> recomeça.
>
> **Fonte da verdade:** RFC-0002 §1 ("Todo transporte … e protocolos futuros como
> A2A converge para a MESMA pipeline"), §8 ("federação A2A **estende estágios
> existentes**"), RFC-0007 (Service Platform), BACKLOG "Fase 3 — Ecossistema"
> ("adapter A2A de borda para federação").

## Escopo desta fatia

A Fase 2 fechou o runtime avançado. A Fase 3 abre o **ecossistema**. Esta fatia
entrega o primeiro pilar de federação: expor o harness como um **agente A2A**
(Agent2Agent) — um transporte de borda que traduz o protocolo A2A na pipeline de
Commands existente e projeta o modelo Task/Event de volta como Tasks A2A. É
**inbound** (o harness É um agente A2A que outros chamam), sobre a MESMA costura
do servidor HTTP/SSE (RFC-0002 §1: todo transporte vira Command).

**Faz (entrada):**
1. **Envelope JSON-RPC 2.0** — parse/validação da request A2A, construção de
   result/error, mapeamento de erros do núcleo → códigos A2A.
2. **Métodos A2A core:** `message/send` (→ `send_message` Command),
   `tasks/get` (→ leitura de Task projetada), `tasks/cancel` (→ `cancel_task`).
3. **Projeção Task → A2A Task** — mapeamento de estado
   (`queued`→`submitted`, `running`→`working`, `waiting`→`input-required`, … ),
   `contextId` = `session_id`, conteúdo final → `status.message`/artifact.
4. **Tradução de message parts** — `TextPart` (A2A) ↔ string de mensagem
   (núcleo). Só texto nesta fatia.
5. **AgentCard** — `GET /.well-known/agent-card.json`: nome, capabilities, skills,
   input/output modes do agente exposto.
6. **Rota + wiring** — `POST /a2a` e o AgentCard no `Server::App`; `Server::A2A::App`
   injetado com o MESMO `command_bus`/stores (o adapter não tem lógica de
   negócio — só traduz, como o resto do servidor).

**Não faz (fatias/evolução seguintes):** `message/stream` (SSE JSON-RPC) e
`tasks/resubscribe`; `tasks/pushNotificationConfig/*` (push); `securitySchemes`/
auth no protocolo; `FilePart`/`DataPart`; **cliente A2A outbound** (chamar OUTROS
agentes A2A como tool/capability — federação de saída, fatia seguinte); registry
multi-agente. Sem modelo real — traduções são determinísticas e testáveis mockado.

## Como esta fatia evolui a Fase 1/2 (costuras já prontas)

| Costura existente | Onde | O que a fatia faz |
|---|---|---|
| `Server::App` traduz transporte→Command, projeta Event→SSE (roteador `route`) | `server/app.rb` | + rota `POST /a2a` e `GET /.well-known/agent-card.json` → `A2A::App` |
| Sub-app injetado (`Admin::App` recebe bus/stores, nunca escreve store direto) | `server/admin/app.rb` | `Server::A2A::App` segue o MESMO padrão de injeção |
| `Command.build(type, payload, transport:)` (transporte é metadado) | `lib/harness/command.rb` | `message/send`→`send_message`, `tasks/cancel`→`cancel_task` com `transport: :a2a` |
| Estados de Task (`queued/running/waiting/paused/completed/failed/cancelled`) | `lib/harness/task_store.rb` | mapeados 1:1 para `TaskState` do A2A (D2) |
| `:waiting` = INPUT_REQUIRED (A2A já é a referência, RFC-0002 §9) | fatia 2-A | `waiting` → `input-required` cai natural |
| `GET /v1/tasks/:id` (leitura direta, projeção `task_to_h`) | `server/app.rb` | `tasks/get` reusa a leitura, projeta em shape A2A |
| Catálogo de skills (name+description) do perfil | `skill_catalog.rb` | alimenta os `skills` do AgentCard |

## Decisões globais desta fatia

### D1 — A2A é TRANSPORTE, não caminho novo (RFC-0002 §1/§8)
O `A2A::App` não executa nada: parseia JSON-RPC, monta o Command certo, despacha
no MESMO `command_bus`, e projeta o resultado/Task de volta no shape A2A. Zero
lógica de negócio — idêntico em espírito ao roteador HTTP e ao `/admin`. Uma
pipeline só.

### D2 — Modelo de Task assíncrono; `message/send` devolve a Task, cliente faz `tasks/get`
Nosso `send_message` é assíncrono (cria a Task, ela completa em background). O
A2A modela Tasks com estados — encaixe natural: `message/send` despacha e devolve
a **A2A Task** (`submitted`/`working`) imediatamente; o cliente acompanha por
`tasks/get` (polling) até um estado terminal. **Sem bloquear, sem SSE** nesta
fatia (streaming é evolução). Mapeamento de estado:

| Task (núcleo) | TaskState (A2A) |
|---|---|
| `queued` | `submitted` |
| `running` | `working` |
| `waiting` | `input-required` |
| `paused` | `working` (suspensão de operador ≠ input do usuário; documentado) |
| `completed` | `completed` |
| `failed` | `failed` |
| `cancelled` | `canceled` |

### D3 — `contextId` A2A = `session_id`; conteúdo final = `status.message`
O `contextId` do A2A (agrupa mensagens de uma conversa) mapeia direto para o
nosso `session_id`. Ausente na request → cria sessão nova (como o `/v1/messages`).
O conteúdo final da Task (`:task_completed` content) vira `status.message` (role
`agent`, um `TextPart`) quando `completed`; erro vira `status.message` quando
`failed`. Artifacts ricos ficam para evolução.

### D4 — Só `TextPart`; erros mapeados a códigos A2A
Message parts: apenas `TextPart` (concatena/emite texto). `FilePart`/`DataPart` →
evolução. Erros do núcleo mapeiam a JSON-RPC/A2A: `ValidationError` → `-32602`
(Invalid params), `NotFoundError` de task → `-32001` (TaskNotFound A2A),
`NotFoundError` de agente → `-32602`, JSON malformado → `-32700` (Parse error),
método desconhecido → `-32601` (Method not found), qualquer outro → `-32603`
(Internal error). O `A2A::App` **nunca** vaza exceção — sempre um error object.

### D5 — Um agente exposto por deployment (config `a2a_agent`); auth = evolução
O AgentCard é por-agente (A2A). Nesta fatia o adapter expõe **um** agente
configurado (`a2a_agent` no CONFIG); `message/send` monta o Command com esse
`agent`. Multi-agente/registry = evolução. O protocolo A2A entrada é
**não-autenticado** (como o `/v1`, ≠ `/admin`); `securitySchemes`/auth é evolução.

### D6 — `Server::A2A::App` é sub-app injetado, sob `server/a2a/`
Espelha o `Admin::App` (sub-app com bus/stores injetados, montado pelo
`Server::App`). Vive em `server/a2a/` (fora do namespace `/admin`). O `Server::App`
delega `POST /a2a` e o AgentCard a ele; leituras (`tasks/get`) usam os stores
injetados (leitura direta, não-Command, como `GET /v1/tasks/:id`, D3 da Fase 1).

## Componentes (docs a detalhar)

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `P3A-01-a2a-protocol-and-projection.md` | Envelope JSON-RPC + `TaskState` mapping + projeção Task→A2A + message parts + mapa de erros | 0002 §1/§8 |
| `P3A-02-agent-card-and-wiring.md` | `AgentCard` + `Server::A2A::App` (handlers) + rotas no `Server::App` + wiring | 0007, 0002 §1 |

## Plano de tarefas (resumo — detalhe em `tasks/tasks.md`)

Ordem: tipos/envelope + projeção + parts + handler (Etapa A); AgentCard + rotas +
wiring + smoke E2E (Etapa B). Ver `tasks/tasks.md`.

## Critério de conclusão da fatia

1. `POST /a2a` com `{"jsonrpc":"2.0","method":"message/send","params":{message:
   {role:"user", parts:[{kind:"text", text:"oi"}]}}}` cria uma Task (via
   `send_message` no MESMO bus) e devolve uma **A2A Task** `submitted`/`working`
   com `id` e `contextId`.
2. `tasks/get` do mesmo `id` projeta o estado corrente; ao completar, traz
   `status.state == "completed"` e `status.message` com o conteúdo (TextPart).
3. `tasks/cancel` transiciona e projeta `canceled`.
4. `GET /.well-known/agent-card.json` devolve o AgentCard do agente configurado
   (nome, capabilities `streaming:false`, skills, modes `text/plain`).
5. Erros mapeados: task inexistente → `-32001`; método desconhecido → `-32601`;
   params inválidos → `-32602`; o adapter nunca vaza exceção (sempre error object).
6. Suíte inteira verde sem chave de API (traduções determinísticas; RubyLLM
   mockado só onde a Task de fato roda).

## Questão em aberto (revisão humana)

- **Versão do A2A:** os nomes de método (`message/send`), o path do AgentCard
  (`/.well-known/agent-card.json`) e os códigos de erro seguem o A2A ~v0.2/v0.3.
  **Confirmar contra a versão-alvo do spec A2A** antes de anunciar compatibilidade
  pública (o protocolo evolui; esta fatia fixa o SUBCONJUNTO core e o adapter
  isola o resto do sistema de qualquer mudança de wire).
