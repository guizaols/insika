# P3B-02 — `Tools::A2ARemote` + config/registro de remotos + wiring

> **RFC base:** 0002 §1, 0006 (registries). **Novo:** `lib/harness/tools/a2a_remote.rb`,
> `server/a2a/remotes.rb`. **Evolui:** `config/wiring.rb`, `event.rb`, `00-overview` D5.
> **Overview:** D1, D4, D5, D6, D7.

## Objetivo

A tool que o modelo chama para delegar a um agente A2A remoto, + a config/registro
que a liga ao Tool Registry, + o wiring, + o smoke loopback. Aqui mora a
integração com o Executor (via Tool Registry) e o event.

## `Tools::A2ARemote` (`lib/harness/tools/a2a_remote.rb`)

```ruby
require "ruby_llm"

module Harness::Tools
  # Delega a um agente A2A remoto (P3B, D1). Tool NORMAL do Tool Registry (a
  # allowlist do agente governa quem delega). require lazy da gem (D9): NÃO entra
  # em lib/harness.rb; carregado no bloco de registro (wiring) na 1ª instância.
  class A2ARemote < RubyLLM::Tool
    param :message, desc: "A mensagem/tarefa para o agente remoto"

    def initialize(client:, url:, tool_name:, description:, event_stream:)
      @client = client ; @url = url ; @tool_name = tool_name
      @description = description ; @event_stream = event_stream ; super()
    end

    def name = @tool_name              # nome estável (senão "harness--tools--a2a_remote")
    def description = @description      # por-instância (cada remoto tem a sua)

    def execute(message:)
      result = @client.call(@url, message.to_s)
      emit(result)
      result[:error] ? { error: result[:error] } : result[:text]   # D4
    end

    private

    def emit(result)
      @event_stream&.emit(Harness::Event.new(
        type: :a2a_call,
        data: { agent: @tool_name, remote_task_id: result[:id], state: result[:state] },
        meta: {} # sem task_id/session_id: a tool não recebe o TurnState (registry tool)
      ))
    end
  end
end
```

- **L1 — name/description por instância:** `RubyLLM::Tool` deriva name/description
  da classe; sobrescrevemos por instância (cada remoto = 1 instância com id/desc
  próprios). `param :message` é de classe (compartilhado, ok).
- **L2 — erro remoto → `{ error: }` ao modelo (D4):** `call` encapsula falhas; a
  tool nunca levanta por erro remoto (só o timeout do Envelope termina o turno).
- **L3 — `:a2a_call` sem correlação de task:** tools de registry não recebem o
  `TurnState`; o event sai com `meta: {}` (como `:provider_warning` do Builder).
  Correlacionar exigiria passar state à tool — fora de escopo (o `:tool_call` do
  `wire_callbacks` já correlaciona a chamada).

## `A2A::Remotes` (`server/a2a/remotes.rb`) — parse da config

```ruby
module Harness::Server::A2A
  module Remotes
    Remote = Data.define(:id, :url, :description)
    # "researcher=https://a/a2a,writer=https://b/a2a" -> [Remote]. Ignora entradas
    # malformadas (sem '=' ou url vazia) com warn.
    def self.parse(env_string, descriptions: {})
  end
end
```

## Wiring (`config/wiring.rb`)

```ruby
# --- A2A outbound (P3B) — federação de saída, OPT-IN ------------------------
A2A_CLIENT = Harness::Server::A2A::Client.new(http: Harness::Server::A2A::Http.new)
Harness::Server::A2A::Remotes.parse(ENV["HARNESS_A2A_REMOTES"].to_s).each do |remote|
  # require LAZY no bloco (D5/D9): wiring-load fica gem-free; a gem carrega na
  # 1ª instanciação (turn time). require é idempotente.
  REGISTRY.register("remote_#{remote.id}", plugin: "a2a") do
    require "ruby_llm"
    require_relative "../lib/harness/tools/a2a_remote"
    Harness::Tools::A2ARemote.new(
      client: A2A_CLIENT, url: remote.url, tool_name: "remote_#{remote.id}",
      description: remote.description || "Delega ao agente A2A remoto '#{remote.id}'",
      event_stream: EVENT_STREAM
    )
  end
end
```

- **L4 — nome `remote_<id>`** evita colisão com tools locais. `plugin: "a2a"`
  (rastreio/rollback). Sem `HARNESS_A2A_REMOTES` → o loop não roda → nada
  registrado (paridade, D6).
- **L5 — require dos `server/a2a/{client,http,remotes}`** no wiring (topo, junto
  do `server/app`) — esses NÃO puxam ruby_llm (só o bloco do tool puxa).

## Catálogo de eventos D5 (D7)

`docs/techspec/00-overview.md` + doc-comment do `Event`:
```markdown
| `:a2a_call` | `{ agent, remote_task_id, state }` | Tools::A2ARemote (P3B) |
```

## Smoke E2E loopback (`spec/e2e/smoke_phase3b_spec.rb`)

O "remoto" é o nosso próprio `A2A::App` inbound (fatia A) — um **http de
loopback** roteia `post_json(url, body)` para `inbound_app.rpc(body)`:

```ruby
LoopbackHttp = Struct.new(:inbound) do
  def post_json(_url, body) = inbound.rpc(body)   # in-process, sem rede
end
```

- Monta 2 wirings in-process: o `worker` (inbound `A2A::App` + Executor + FakeChat
  que responde "42") e o `orchestrator` (Executor com a tool `remote_worker`
  cujo client usa `LoopbackHttp` apontando ao inbound do worker).
- Cenários (critérios): (1) o `orchestrator` chama `remote_worker(message:)`, o
  turno do `worker` roda no inbound, e o texto "42" volta ao modelo do
  orchestrator; `:a2a_call` emitido. (2) worker que falha → a tool devolve
  `{ error: }` e o orchestrator segue. (3) sem remotos → nenhum tool `remote_*`.

> Prova a federação **ponta a ponta nos dois sentidos** (outbound→inbound) sem
> rede nem chave de API.

## Testes

- **`A2ARemote`** (client fake): execute → client.call → text; erro → `{ error: }`;
  `:a2a_call` emitido; `def name`/`description` por instância.
- **`Remotes.parse`**: "id=url,.." → [Remote]; malformado ignorado (warn).
- **Wiring**: sem env → nenhum `remote_*` no REGISTRY; com env → 1 tool por remoto.
- **Smoke loopback**: os 3 cenários.

## Fora de escopo (evolução)

Remoto como capability (RFC-0004); streaming client; descoberta via AgentCard;
auth; retry.
