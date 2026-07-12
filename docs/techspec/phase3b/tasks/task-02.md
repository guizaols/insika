# Task 02 (P3B): A2A::Client#call (send + poll)

> **Techspec:** [P3B-01-a2a-client.md](../P3B-01-a2a-client.md) (§Client, D3, L4-L5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Entregar o método de alto nível `A2A::Client#call(url, text, context_id: nil)`:
o "send + poll" completo que esconde de quem chama (a Task 4, `Tools::A2ARemote`)
toda a dança JSON-RPC de `send_message`/`get_task` e devolve SEMPRE um `Hash`
simples — nunca levanta. É a peça que fecha D3 do overview ("`call` faz poll
até terminal") e L5 ("`RemoteError` em `call` vira `{ error: }`, o `call` NÃO
levanta"): sem ela, `Tools::A2ARemote#execute` (Task 4) teria que reimplementar
o loop de poll e o `rescue` dentro de cada tool remota, duplicando a lógica por
remoto.

## Dependências

Task 01 (`A2A::Client` — `send_message`/`get_task` + `RemoteError`). Esta task
só ADICIONA o método `call` ao MESMO arquivo/classe que a Task 01 cria —
depende de:
- `TERMINAL` (constante já definida na Task 01);
- `send_message(url, text, context_id:)` → Task remota (`Hash`) ou `raise RemoteError`;
- `get_task(url, task_id)` → idem;
- `remote_state(task)` / `remote_text(task)` / `remote_id(task)` (leitores da
  Task remota, inverso da projeção `TaskProjection` da fatia A);
- `@poll_max` e `@sleeper` já resolvidos no `initialize` da Task 01 (default do
  `sleeper`: `Async::Task.current.sleep(seconds)`; testes injetam no-op).

## Contexto

O `Client` é PURO (http injetado, D2 do overview) — `call` não foge disso: só
orquestra `send_message`/`get_task`/os leitores, sem tocar rede diretamente.
O poll (D3) existe porque `message/send` pode devolver a Task já em estado
não-terminal (`submitted`/`working`) quando o agente remoto processa
assíncrono; `call` reconsulta via `tasks/get` até ela virar terminal
(`TERMINAL = completed/failed/canceled/rejected/input-required`) ou até
`poll_max` tentativas se esgotarem.

**Decisão de implementação não fixada literalmente no bloco de assinatura do
techspec** (que só declara `initialize(http:, poll_max: 30, sleeper: nil)`,
sem parâmetro de delay): o "quanto" dormir entre tentativas (o `delay` de
`sleeper.(delay)`, L4) precisa de um valor concreto. Como esse valor só é
consumido pelo loop que esta task introduz, adicionar aqui uma constante
privada `POLL_DELAY_SECONDS` (frozen, ex. `0.5`) é a decisão mais estreita
possível — não reabre o `initialize` da Task 01 nem exige um novo kwarg
público (a Task 01 e o techspec não previram configurar isso por fora; se
isso mudar no futuro, é uma evolução separada, ver Notas).

A regra de encapsulamento de erro (L5) é o ponto mais delicado: `send_message`
e `get_task`, usados DIRETAMENTE (uso avançado/testes), continuam levantando
`RemoteError` normalmente — só `call` (o helper de alto nível que a Task 4 vai
chamar de dentro de uma tool exposta ao modelo) precisa da garantia de nunca
estourar exceção para fora, porque o RubyLLM não tem como recuperar
graciosamente uma tool que levanta no meio do turno.

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| MODIFY | `server/a2a/client.rb` | + constante `POLL_DELAY_SECONDS` + método `#call(url, text, context_id: nil)` |
| MODIFY | `spec/harness/server/a2a/client_spec.rb` | + `describe "#call"` (poll até completed, failed, envelope error, poll estourado, input-required) |

## Passo a passo

### Passo 1 — constante de delay do poll

**Padrão de referência (techspec P3B-01, `TERMINAL` já na Task 01):**
```ruby
module Harness::Server::A2A
  class Client
    TERMINAL = %w[completed failed canceled rejected input-required].freeze
```

Acrescentar logo abaixo, mesmo estilo (constante de classe, frozen implícito
por ser `Float`):
```ruby
    # Delay entre tentativas de poll (D3). Não configurável via initialize
    # nesta fatia — só a Task 4 (Tools::A2ARemote) consome `call`, e ela não
    # precisa ajustar isso; testes injetam `sleeper` no-op e ignoram o valor.
    POLL_DELAY_SECONDS = 0.5
```

### Passo 2 — `#call`

**Padrão de referência (leitores da Task 01, assumidos já implementados —
conferir o `client.rb` real após a Task 01 mesclar; a assinatura abaixo é a
do techspec, fonte de verdade até lá):**
```ruby
def remote_state(task) = task.dig("status", "state")
def remote_text(task)  = Message.text_from(task.dig("status", "message"))
def remote_id(task)    = task["id"]
```

Implementação de `call` (mesma classe, logo após `get_task`):
```ruby
# Alto nível (D3): send + poll `tasks/get` até terminal. NUNCA levanta (L5).
# -> { text:, state:, id: } (completed/input-required) | { error:, state:, id: } (falha).
def call(url, text, context_id: nil)
  t = send_message(url, text, context_id: context_id)
  attempts = 0
  until TERMINAL.include?(remote_state(t)) || attempts >= @poll_max
    @sleeper.call(POLL_DELAY_SECONDS)
    t = get_task(url, remote_id(t))
    attempts += 1
  end

  state = remote_state(t)
  id = remote_id(t)

  case state
  when "completed", "input-required"
    { text: remote_text(t), state: state, id: id }
  when "failed", "canceled", "rejected"
    { error: remote_text(t) || state, state: state, id: id }
  else
    # attempts esgotou sem chegar a um estado terminal (ex. ainda "working"/"submitted").
    { error: "remote task não concluiu", state: state, id: id }
  end
rescue RemoteError => e
  { error: e.message, state: "failed", id: nil }
end
```

Pontos de atenção da implementação:
- O `case` cobre o "poll estourou" SEM flag extra: se o `until` sair por
  `attempts >= @poll_max` (não por estado terminal), `state` continua sendo
  algo como `"working"`/`"submitted"` — cai naturalmente no `else`. Não criar
  uma variável `exhausted`/`timed_out` separada; o estado em si já carrega a
  informação.
- `attempts` só conta chamadas de `get_task` (o poll), não a chamada inicial
  de `send_message` — se `send_message` já devolver estado terminal (ex.
  `completed` síncrono), o `until` nem entra no corpo e não há `sleep`
  nenhum.
- O `rescue RemoteError` envolve o método INTEIRO (`send_message` E os
  `get_task` do loop) — um erro de envelope no meio do poll é encapsulado
  igual a um erro na primeira chamada.
- `id: nil` no branch do `rescue`: se `RemoteError` estourou, não há Task
  remota parseada com sucesso — não inventar um `id` a partir de dado
  parcial.

## Edge cases

- **Poll até terminal**: `send_message` devolve `working`; 1+ `get_task`
  devolvem `working` de novo; o último devolve `completed` — `call` só para
  de fazer poll quando `remote_state(t)` entra em `TERMINAL`.
- **`completed` → `{ text: }`**: `remote_text(t)` (via `Message.text_from`)
  vira o `text:` da resposta; `error:` ausente.
- **`failed`/`canceled`/`rejected` → `{ error: }`**: usa
  `remote_text(t) || state` — se a Task remota trouxer uma mensagem de erro
  no `status.message`, ela vence; se não trouxer nada (`status.message`
  ausente → `remote_text` devolve `""`, que é falsy-ish só se vazio — ver
  nota abaixo), cai no próprio nome do estado como fallback.
  ⚠️ Atenção: `Message.text_from` devolve `""` (string vazia), não `nil`,
  quando não há `parts` — `"" || state` NÃO cai no fallback porque `""` é
  truthy em Ruby. Se o teste de "failed sem mensagem" for necessário, ou o
  fallback usa `remote_text(t).then { |s| s.empty? ? nil : s } || state`, ou
  aceita-se `error: ""` como comportamento e o teste cobre só o caso COM
  mensagem (mais realista — um agente remoto que falha normalmente explica
  por quê). Documentar a escolha feita no PR se divergir do pseudocódigo
  acima.
- **`input-required` → `{ text: }`**: é estado TERMINAL para fins de poll
  (está em `TERMINAL`) mas semanticamente "sucesso parcial" — cai no MESMO
  branch de `completed` (ambos trazem `text:`, não `error:`), porque o agente
  remoto está pedindo mais input, não relatando falha.
- **Poll estoura (`attempts >= poll_max`)**: com `poll_max` pequeno nos testes
  (ex. `2`) e um fake http que SEMPRE devolve `working`, `call` devolve
  `{ error: "remote task não concluiu", state: "working", id: ... }` — nunca
  trava em loop infinito nem estoura exceção.
- **`RemoteError` (envelope `"error"`) encapsulado**: tanto na chamada inicial
  (`send_message`) quanto em qualquer `get_task` do meio do poll, `call`
  NUNCA deixa a exceção escapar — sempre devolve
  `{ error: message, state: "failed", id: nil }`. `send_message`/`get_task`
  usados DIRETAMENTE (fora de `call`) continuam levantando normalmente — só
  o helper de alto nível encapsula.
- **`sleeper` injetável**: em produção, default é o sleep real do reactor
  Async (já resolvido pela Task 01 no `initialize`); nos testes, um `sleeper`
  no-op (`->(_seconds) {}`) evita qualquer espera real — `call` não deve
  assumir nada sobre quanto tempo o `sleeper` de fato dorme, só que ele É
  chamado uma vez por iteração do poll.

## Testes

**Arquivo:** `spec/harness/server/a2a/client_spec.rb` (estende a suíte da
Task 01 — reaproveitar o mesmo fake de `http` já usado para `send_message`/
`get_task`, ajustado para devolver respostas EM SEQUÊNCIA, uma por chamada de
`post_json`, já que `call` faz múltiplas chamadas HTTP em ordem).

Fake sugerido (mesmo espírito dos duplos de `spec/support/server_doubles.rb`
— fila de respostas roteirizadas, sem mock framework):
```ruby
class FakeA2AHttp
  def initialize(responses)
    @responses = responses.dup
  end

  def post_json(_url, _body)
    @responses.size > 1 ? @responses.shift : @responses.first
  end
end
```

| # | Cenário | Setup | Asserção |
|---|---|---|---|
| 1 | `send_message` já devolve `completed` (sem poll) | fake com 1 resposta `completed` | `call` devolve `{ text:, state: "completed", id: }`; `sleeper` NUNCA chamado |
| 2 | poll: `working` → `working` → `completed` | fake com 3 respostas em sequência; `sleeper` no-op | `call` devolve `{ text:, state: "completed", id: }`; `sleeper` chamado 2x |
| 3 | remoto termina `failed` (com `status.message`) | fake devolve `failed` com mensagem | `call` devolve `{ error: <mensagem>, state: "failed", id: }` |
| 4 | envelope com `"error"` (na chamada inicial) | fake `post_json` devolve `{"error": {...}}` | `call` devolve `{ error: <message>, state: "failed", id: nil }`; NÃO levanta |
| 5 | envelope com `"error"` no MEIO do poll (2ª chamada) | 1ª resposta `working`, 2ª é envelope de erro | mesma asserção do #4 — encapsulado igual, mesmo não sendo a 1ª chamada |
| 6 | poll estoura (`poll_max: 2`, fake sempre `working`) | `Client.new(http: fake, poll_max: 2, sleeper: ->(_) {})` | `call` devolve `{ error: "remote task não concluiu", state: "working", id: }`; `sleeper` chamado exatamente 2x (não 3+) |
| 7 | remoto pede mais input (`input-required`) | fake devolve `input-required` direto | `call` devolve `{ text:, state: "input-required", id: }` (NÃO `error:`) |

Todos os testes injetam `sleeper: ->(_seconds) {}` (ou um spy que só conta
chamadas) — nenhum teste deve realmente dormir.

## Definition of Done

- [ ] `POLL_DELAY_SECONDS` + `#call(url, text, context_id: nil)` adicionados a
      `server/a2a/client.rb` (mesma classe da Task 01, sem duplicar
      `TERMINAL`/`initialize`)
- [ ] `call` NUNCA levanta — `RemoteError` sempre encapsulado em
      `{ error:, state: "failed", id: nil }`
- [ ] `completed`/`input-required` → `{ text:, state:, id: }`;
      `failed`/`canceled`/`rejected` → `{ error:, state:, id: }`; poll
      estourado → `{ error: "remote task não concluiu", state:, id: }`
- [ ] `spec/harness/server/a2a/client_spec.rb` cobre a tabela de testes acima
      (poll multi-tentativa, terminal imediato, erro de envelope na 1ª E na
      N-ésima chamada, poll estourado, `input-required`)
- [ ] Nenhum teste dorme de verdade (`sleeper` sempre injetado como no-op/spy)
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task NÃO mexe em `server/a2a/http.rb` (Task 03, adapter real de rede)
  nem em `lib/harness/tools/a2a_remote.rb` (Task 04, que vai CHAMAR
  `client.call` de dentro de `execute`) — só fecha a lógica pura do `Client`.
- `POLL_DELAY_SECONDS` fixo (não configurável) é deliberado nesta fatia: o
  overview D3 só exige QUE haja poll com backoff simples, não elasticidade de
  delay por remoto; se um remoto precisar de outro intervalo no futuro, isso
  vira um kwarg em `initialize` — fora de escopo aqui, para não expandir a
  superfície pública além do que a Task 4/6 realmente consomem.
- Confirmar ao implementar que os leitores `remote_state`/`remote_text`/
  `remote_id` da Task 01 batem EXATAMENTE com as assinaturas usadas acima
  (`task.dig("status", "state")` etc. — chaves STRING do wire, L2 do
  techspec); se a Task 01 divergir nominalmente, ajustar as chamadas em
  `call`, não reintroduzir a leitura duplicada aqui.
- O caso "`failed` sem `status.message`" (fallback `remote_text(t) || state`)
  tem uma armadilha de Ruby documentada no Edge case acima
  (`""` é truthy) — decidir e testar explicitamente o comportamento
  desejado ao implementar, em vez de deixar implícito.
