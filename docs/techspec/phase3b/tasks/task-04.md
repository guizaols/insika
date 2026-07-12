# Task 04 (P3B): Tools::A2ARemote (delega a agente remoto)

> **Techspec:** [P3B-02-remote-tool-and-wiring.md](../P3B-02-remote-tool-and-wiring.md) (§Tools::A2ARemote, D1/D4, L1-L3) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Criar `Harness::Tools::A2ARemote`: a `RubyLLM::Tool` que o modelo chama para
delegar uma mensagem a UM agente A2A remoto específico. Cada remoto configurado
(`server/a2a/remotes.rb`, task 5) vira UMA instância desta classe com seu
próprio `url`/`tool_name`/`description` — esta task cria só a classe e o spec
isolado (client fake); o registro real por remoto no `Tool Registry`
(`config/wiring.rb`, gated por `HARNESS_A2A_REMOTES`) é a **task 6**.

## Dependências

| Task | Componente | Motivo |
|---|---|---|
| Task 02 | `A2A::Client#call` (`server/a2a/client.rb`) | fornece `call(url, text)` → `{ text:, state:, id: }` (sucesso/`input-required`) OU `{ error:, state:, id: }` (falha) — o único método que `A2ARemote#execute` chama. Sem `#call` (send + poll até terminal) não há o que delegar. |

Não depende da task 5 (`Remotes.parse`) nem da task 6 (wiring/registro): os
specs desta task constroem `A2ARemote` isoladamente, com um `client` FAKE
(double que responde `{ text: }`/`{ error: }` a `call`) e um `event_stream`
fake mínimo — sem precisar do `A2A::Client` real, de rede, nem do
`Tool Registry`.

## Contexto

### Tool NORMAL do Tool Registry — não é builtin de sistema (D1)

Diferente de `Tools::Remember`/`Tools::ToolSearch` (builtins sempre presentes,
gate por `profile.memory`/deferred), `A2ARemote` é uma tool de NEGÓCIO comum:
quem decide se um agente pode chamá-la é a **allowlist do agente** (o
`Tool Registry` registra `remote_<id>` só se `HARNESS_A2A_REMOTES` estiver
setado — task 6 — e o profile precisa listá-la como qualquer outra tool). Esta
task não mexe em allowlist/profile; só na classe.

### `require "ruby_llm"` fica no arquivo — lazy, fora de `lib/harness.rb`

Mesma disciplina D9 já estabelecida em `load_skill.rb`/`tool_search.rb`/
`remember.rb`: a classe herda `RubyLLM::Tool`, então `require "ruby_llm"` mora
NESTE arquivo. `A2ARemote` **não** entra em `lib/harness.rb` — quem a carrega é
o bloco de registro do wiring (`REGISTRY.register("remote_#{remote.id}", ...) do
... require "ruby_llm" ; require_relative ... end`, task 6, D5), na 1ª
instanciação (turn time). Isso mantém o núcleo gem-free para quem não usa A2A
outbound (paridade, D6).

### `name`/`description` por INSTÂNCIA, não por classe (L1)

`RubyLLM::Tool#name` deriva de `self.class.name` quando não sobrescrito — para
`Harness::Tools::A2ARemote` isso produziria `"harness--tools--a2a_remote"`
(mesmo defeito de classe aninhada já corrigido em `LoadSkill`/`ToolSearch`/
`Remember`, P2B-02 L7). Aqui o problema é mais sério que nos builtins: CADA
remoto configurado (`researcher`, `writer`, ...) precisa de um `name`
(`remote_<id>`) e uma `description` PRÓPRIOS — não dá para fixar um único
`def name = "..."` de classe. Por isso `name`/`description` são recebidos no
`initialize` (`tool_name:`/`description:`) e expostos como métodos de
instância (`def name = @tool_name`), não via a DSL `description "..."` de
classe (que é compartilhada por todas as instâncias). `param :message` continua
de classe — é o único elemento igual entre todos os remotos.

### Erro remoto vira `{ error: }` para o MODELO, nunca uma exceção (D4/L2)

`A2A::Client#call` (task 2) já encapsula toda falha remota — `RemoteError`
(envelope JSON-RPC com `"error"`), estado terminal `failed`/`canceled`/
`rejected`, ou poll estourado — em `{ error:, state:, id: }`. `A2ARemote#execute`
NUNCA levanta por causa disso: só repassa o `error` como retorno de tool
(`{ error: result[:error] }`). O turno do orchestrator segue normalmente (o
único jeito de um turno terminar por causa de A2A é o timeout do próprio
Envelope/profile, não um erro remoto).

### `require lazy` no bloco de registro (D5) — antecipado aqui, cabeado na task 6

Esta task não escreve o bloco de registro (isso é a task 6), mas o desenho da
classe já pressupõe esse padrão: `A2ARemote.new(client:, url:, tool_name:,
description:, event_stream:)` é chamado DENTRO do bloco `REGISTRY.register(...)
do ... end`, então o `require_relative "../lib/harness/tools/a2a_remote"`
também é lazy — só roda se houver ao menos um remoto configurado.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/tools/a2a_remote.rb` | CREATE | `Harness::Tools::A2ARemote < RubyLLM::Tool` — delega a `client.call`, emite `:a2a_call`, `name`/`description` por instância |
| `spec/harness/tools/a2a_remote_spec.rb` | CREATE | specs unitários: client fake (`{text:}`/`{error:}`), evento `:a2a_call`, `name`/`description` por instância, delegação de `url`/`message` |

## Passo a passo

**Padrão de referência (codebase) — `lib/harness/tools/remember.rb` e
`lib/harness/tools/tool_search.rb` inteiros** (mesmo esqueleto: `require
"ruby_llm"` no topo do arquivo, DSL `description`/`param` de classe, `def name`
explícito, dependências recebidas via `initialize` com kwargs, evento emitido
pela PRÓPRIA tool via `event_stream:` no construtor — `tool_search.rb` mostra
exatamente esse padrão de emissão, embora com `state:`/correlação; `a2a_remote`
usa o mesmo padrão mas SEM `state:`, ver Edge cases). Leia os dois arquivos
inteiros antes de escrever esta classe — não reinventar a estrutura.

### Passo 1 — esqueleto: `require`, `param` de classe, `initialize`, `name`/`description` de instância

```ruby
# lib/harness/tools/a2a_remote.rb
# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Delega a um agente A2A remoto (P3B, D1). Tool NORMAL do Tool Registry (a
    # allowlist do agente governa quem delega) — NÃO é builtin de sistema.
    # require lazy da gem (D9): NÃO entra em lib/harness.rb; carregado no
    # bloco de registro do wiring (task 6) na 1ª instância de cada remoto.
    class A2ARemote < RubyLLM::Tool
      param :message, desc: "A mensagem/tarefa para o agente remoto"

      def initialize(client:, url:, tool_name:, description:, event_stream:)
        @client = client
        @url = url
        @tool_name = tool_name
        @description = description
        @event_stream = event_stream
        super()
      end

      # name/description por INSTÂNCIA (não de classe, L1): cada remoto
      # configurado (researcher, writer, ...) tem seu próprio id/descrição —
      # sem o override, RubyLLM derivaria "harness--tools--a2a_remote" da
      # classe (mesmo defeito de LoadSkill/ToolSearch/Remember, P2B-02 L7),
      # igual para TODOS os remotos, o que colidiria no Tool Registry.
      def name = @tool_name
      def description = @description
    end
  end
end
```

### Passo 2 — `execute`: delega a `client.call`, decide `{ error: }` vs texto (D4)

```ruby
def execute(message:)
  result = @client.call(@url, message.to_s)
  emit(result)
  result[:error] ? { error: result[:error] } : result[:text]
end
```

`message.to_s` normaliza símbolo/nil como o resto do sistema já faz (mesma
disciplina de `value.to_s`/`key.to_s` em `Remember#execute`). Nada mais é
validado aqui — a validação de "isso é uma mensagem sensata" é do
modelo/prompt, não desta tool.

### Passo 3 — evento `:a2a_call` (meta `{}`, L3)

```ruby
private

def emit(result)
  @event_stream&.emit(Harness::Event.new(
                        type: :a2a_call,
                        data: { agent: @tool_name, remote_task_id: result[:id], state: result[:state] },
                        meta: {} # tool de registry não recebe o TurnState — ver Edge cases
                      ))
end
```

`@event_stream&.` (safe navigation): assim como `remember.rb`/`tool_search.rb`
recebem sempre um `event_stream` real no fluxo de produção, mas os specs desta
task usam um fake mínimo — usar `&.` custa nada e evita depender de um double
obrigatório em todo teste que não se importa com o evento (ver Testes).

## Edge cases

- **Erro remoto (`result[:error]` presente) → `{ error: result[:error] }` para
  o modelo (D4).** A tool não levanta; `execute` sempre retorna um Hash (texto
  puro no sucesso — `result[:text]`, não um Hash `{ text: }` — vs. `{ error: }`
  no caminho de falha). Cobrir os dois formatos de retorno explicitamente no
  spec, não só o de sucesso.
- **`:a2a_call` sai com `meta: {}` (L3), não `{ task_id:, session_id: }`.**
  Tools do Tool Registry (diferente das builtins `remember`/`tool_search`) não
  recebem o `TurnState` no construtor — não há `@state.task.id` para
  correlacionar. Isso é uma limitação DOCUMENTADA (P3B-02 L3, "Concerns" em
  `tasks.md`), não um bug desta task: o `:tool_call` do `wire_callbacks` já
  correlaciona a chamada de tool ao turno; `:a2a_call` complementa com o
  estado remoto (`agent`/`remote_task_id`/`state`), sem tentar duplicar a
  correlação.
- **`def name`/`def description` evitam `"harness--tools--a2a_remote"`** — sem
  o override, TODAS as instâncias (um remoto ou dez) colidiriam no mesmo nome
  derivado da classe, quebrando o registro de mais de um remoto no Tool
  Registry. Coberto por spec explícito com DUAS instâncias de `name`/
  `tool_name` diferentes, não só uma.
- **`message` vazia (`""`) ou ausente (`nil`)** — não é erro desta tool:
  `message.to_s` normaliza `nil` para `""` e repassa como texto vazio a
  `@client.call`; validar "faz sentido delegar uma mensagem vazia" é
  responsabilidade do modelo/prompt (mesma postura de `Remember` quanto a
  `value` vazio), não desta tool determinística de delegação.
- **`@client.call` recebe exatamente `(@url, message.to_s)`** — o spec deve
  assertar os ARGUMENTOS passados ao fake, não só o retorno, para pegar um
  `url`/`message` trocados ou mal-fiados no construtor.

## Testes

**Arquivo:** `spec/harness/tools/a2a_remote_spec.rb`

Client é um FAKE (double simples que responde a `call(url, text)` — não o
`A2A::Client` real; a lógica de poll/parse é responsabilidade da task 2, já
testada lá). `event_stream` pode ser um fake mínimo (objeto com `emit(e)` que
empilha num Array), mesmo padrão de `spec/harness/tools/tool_search_spec.rb`.

| Cenário | Expectativa |
|---|---|
| client fake retorna `{ text: "42", state: "completed", id: "t1" }` | `execute(message: "oi")` delega a `client.call(url, "oi")` e retorna `"42"` (texto puro, não Hash) |
| client fake retorna `{ error: "boom", state: "failed", id: "t1" }` | `execute` retorna `{ error: "boom" }` (não levanta) |
| sucesso ou erro, em ambos | `event_stream` recebe um `Harness::Event` `:a2a_call` com `data: { agent: <tool_name>, remote_task_id: "t1", state: <state> }` e `meta == {}` |
| `A2ARemote.new(tool_name: "remote_a", ...)` vs `A2ARemote.new(tool_name: "remote_b", ...)` | `#name` reflete `tool_name` de CADA instância (não um valor fixo de classe); idem para `description` |
| `execute(message: :oi)` / `execute(message: nil)` | `client.call` recebe `"oi"`/`""` (String, via `to_s`) — sem levantar |
| `param :message` | presente na definição da tool (`described_class.new(...).parameters` inclui `:message`) — de classe, igual em todas as instâncias |

## Definition of Done

- [ ] `Tools::A2ARemote` criada em `lib/harness/tools/a2a_remote.rb`, herdando
      `RubyLLM::Tool`, com `require "ruby_llm"` NESTE arquivo (não em
      `lib/harness.rb`)
- [ ] `name`/`description` por INSTÂNCIA (via `@tool_name`/`@description` do
      construtor), cobertos por spec com duas instâncias distintas
- [ ] `execute` delega a `@client.call(@url, message.to_s)`; sucesso → texto
      puro (`result[:text]`); erro (`result[:error]` presente) → `{ error: }`
      (D4) — nunca levanta por erro remoto
- [ ] `:a2a_call` emitido em AMBOS os caminhos (sucesso/erro) com
      `data: { agent:, remote_task_id:, state: }` e `meta: {}` (L3)
- [ ] Suíte verde sem chave de API nem rede (client/event_stream fakes)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**Coordenação com a task 6:** esta task só cria a classe e o spec isolado. O
bloco de registro real (`REGISTRY.register("remote_#{remote.id}", plugin: "a2a")
do require "ruby_llm" ; require_relative ... ; A2ARemote.new(...) end`) dentro
de `config/wiring.rb`, iterando sobre `A2A::Remotes.parse(ENV[...])` (task 5),
é responsabilidade da task 6 — não adiantar esse cabeamento aqui para não
colidir no mesmo arquivo (`config/wiring.rb`) que as tasks 5/6 também tocam.

**Sem `ToolEnvelope`/resume-safety nesta task:** ao contrário das tools
promovidas por `Tools::ToolSearch` (embrulhadas em `ToolEnvelope` com
`skip_side_effects`), `A2ARemote` em si não decide se é envelopada — isso é
decisão do `Tool Registry`/`Executor` no momento em que a tool é RESOLVIDA para
uso no chat (fora do escopo desta task, que só constrói a classe). O
`A2A::Client#call` (task 2) já é idempotente por natureza de poll (repetir
`get_task` não duplica o remoto); uma resubmissão de `send_message` por resume
é um concern de nível Envelope/Client, não desta tool.
