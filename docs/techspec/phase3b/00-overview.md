# Techspec Fase 3 (fatia B) — A2A outbound (federação de saída)

> Segue o processo das fatias anteriores. RFC = "o quê e porquê"; este doc +
> `P3B-01`/`P3B-02` = "como". Evolui a camada A2A (`server/a2a/`), o Tool Registry
> e o wiring — reusa a fatia A (inbound), não recomeça.
>
> **Fonte da verdade:** RFC-0002 §1/§8 (A2A estende a pipeline), RFC-0004
> (capabilities/tools), BACKLOG "Fase 3 — adapter A2A de borda para federação".

## Escopo desta fatia

A fatia A (P3A) fez o harness SER um agente A2A (inbound). Esta fecha a federação:
o harness passa a **chamar** agentes A2A remotos — um agente do harness delega a
outro agente (nosso ou de terceiros) via A2A. A integração natural: expor um
agente remoto como **tool** que o modelo chama.

**Faz (entrada):**
1. **`A2A::Client`** — cliente de borda: monta `message/send`/`tasks/get`
   (JSON-RPC, reusando `Protocol`/`Message` da fatia A), parseia a resposta,
   lê a A2A Task remota (inverso da projeção), e o helper `call(url, text)` =
   send + **poll** `tasks/get` até terminal → texto final.
2. **`A2A::Http`** — adapter HTTP de produção (`async-http`) que implementa o
   duck-type `post_json(url, body) -> Hash`. Injetável — o `Client` não conhece a
   lib (puro/testável).
3. **`Tools::A2ARemote`** — um `RubyLLM::Tool` por agente remoto configurado:
   `execute(message:)` → `client.call(url, message)` → texto; emite `:a2a_call`.
   Registrado no Tool Registry (governado pela allowlist do agente, como qualquer
   tool).
4. **Config + registro** — lista de agentes remotos (`HARNESS_A2A_REMOTES`,
   `id=url`); o wiring registra um tool por remoto (com require lazy, D9).
5. **Smoke loopback** — o outbound chama o **inbound** `A2A::App` (mesmo processo)
   via um http fake → federação completa, determinística, sem rede.

**Não faz (evolução):** `message/stream` do lado cliente (consumir SSE do
remoto); descoberta dinâmica via AgentCard remoto (fetch + cache — usamos config
estática); auth/`securitySchemes` no cliente; retry/circuit-breaker; remoto como
**capability** (RFC-0004) em vez de tool direta; FilePart/DataPart.

## Como esta fatia evolui a Fase 1/2/3-A (costuras já prontas)

| Costura existente | Onde | O que a fatia faz |
|---|---|---|
| `A2A::Protocol`/`A2A::Message` (envelope + parts↔texto) | `server/a2a/*` (P3A) | reusados p/ MONTAR requests e PARSEAR respostas remotas |
| `A2A::App` inbound (recebe JSON-RPC, roda o turno) | `server/a2a/app.rb` (P3A) | vira o "remoto" no smoke loopback |
| Tool Registry + factory por bloco (lazy) | `lib/harness/tool_registry.rb` | registra 1 tool por agente remoto, require lazy no bloco (D9) |
| builtin RubyLLM::Tool (require lazy, `def name`) | `tools/load_skill.rb` etc. | `Tools::A2ARemote` segue o padrão |
| `ToolEnvelope` (timeout por call, side-effect) | `lib/harness/tool_envelope.rb` | a tool remota é envelopada como qualquer tool (timeout do turno protege o poll) |
| Event Stream (catálogo D5) | `event.rb` | + `:a2a_call` |

## Decisões globais desta fatia

### D1 — Agente remoto exposto como TOOL (governado pela allowlist)
O modelo chama `remote_<id>(message: "...")`. É uma tool normal do Tool Registry
(não system-tool): a allowlist do agente (`tools_allow`) decide quem pode
delegar. Um tool por remoto, nome estável = `id` do remoto, description da config.
Expor como **capability** (RFC-0004) é evolução.

### D2 — HTTP injetado (duck-type); `Client` puro; smoke loopback
`A2A::Client` recebe um `http` com `post_json(url, body_hash) -> Hash` (envelope
JSON-RPC já parseado). Produção: `A2A::Http` (`async-http`). Testes: fake que
devolve envelopes canned. **Smoke:** um http de **loopback** que roteia
`post_json` para o nosso `A2A::App#rpc` inbound — o outbound chama o inbound
in-process, provando a federação sem rede. O `Client` nunca conhece a lib HTTP.

### D3 — `call` faz send + poll até terminal, com teto
`client.call(url, text)`: `message/send` → obtém o `id` da task remota → `tasks/get`
em loop até estado terminal (`completed`/`failed`/`canceled`), com um teto de
tentativas/tempo (config). `completed` → texto do `status.message`; `failed`/erro
remoto → resultado de erro. A tool é **envelopada** (ToolEnvelope): o timeout do
turno já limita o poll; o teto do client é a segunda linha.

### D4 — Erro remoto volta ao MODELO como erro de tool (turno não falha)
Envelope JSON-RPC `error`, task remota `failed`/`canceled`, ou HTTP falho → a tool
devolve `{ error: "..." }` ao modelo (mesmo protocolo do timeout de tool, Fase 1),
não derruba o turno. Só o timeout do Envelope leva a estado terminal.

### D5 — Require lazy no bloco de registro (respeita D9)
`Tools::A2ARemote` herda de `RubyLLM::Tool` (require a gem). O wiring registra com
um **bloco** que faz `require` da gem + do arquivo na PRIMEIRA instância (turn
time) — o wiring-load continua gem-free (D9). `require` é idempotente.

### D6 — Opt-in por config; sem remotos → nada registrado (paridade)
Sem `HARNESS_A2A_REMOTES` → nenhum tool remoto → comportamento idêntico. Cada
remoto é `id=url` (ex.: `researcher=https://other.example/a2a`).

### D7 — Catálogo de eventos estendido
`:a2a_call { agent, remote_task_id, state }`. Registrado no catálogo D5.

## Componentes (docs a detalhar)

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `P3B-01-a2a-client.md` | `A2A::Client` (send/get/call + parse da Task remota) + `A2A::Http` adapter | 0002 §1 |
| `P3B-02-remote-tool-and-wiring.md` | `Tools::A2ARemote` + config/registro de remotos + wiring + `:a2a_call` + smoke loopback | 0002 §1, 0006 |

## Plano de tarefas (resumo — detalhe em `tasks/tasks.md`)

Ordem: client + parse + http (Etapa A); tool + config/registro + wiring + smoke
loopback (Etapa B). Ver `tasks/tasks.md`.

## Critério de conclusão da fatia

1. Um agente `orchestrator` com a tool `remote_worker` na allowlist chama-a; o
   `A2A::Client` faz `message/send` + poll no endpoint remoto e devolve o texto
   final do agente remoto ao modelo; `:a2a_call` é emitido.
2. **Loopback:** o "remoto" é o nosso `A2A::App` inbound (agente `worker`); um
   turno do `orchestrator` obtém a resposta do `worker` — federação ponta a ponta
   in-process.
3. Erro remoto (envelope `error` ou task `failed`) → a tool devolve `{ error: }`
   ao modelo; o turno do orchestrator segue.
4. Sem `HARNESS_A2A_REMOTES` → nenhum tool remoto registrado (paridade Fase 1).
5. Suíte inteira verde sem chave de API (o `Client` é testado com http fake;
   RubyLLM mockado só onde o turno roda).
