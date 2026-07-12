# Task 03 (P3B): `A2A::Http` (adapter async-http)

> **Techspec:** [P3B-01-a2a-client.md](../P3B-01-a2a-client.md) (§Http, D2, L6) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo

Criar `Harness::Server::A2A::Http`, o adapter de produção que o `A2A::Client`
(task 1/2) usa para falar HTTP de verdade com um agente remoto. É a ÚNICA
peça desta fatia que toca `async-http` — o `Client` é PURO (recebe `http:`
injetado) e nunca importa a gem diretamente (D2 do overview). `Http` expõe
só o que o `Client` consome: `post_json(url, body) -> Hash` (envelope
JSON-RPC já parseado, chaves string) e `close` para liberar conexões.

## Dependências

Nenhuma — pode começar já (não depende das tasks 1/2; o `Client` consome
`Http` só por duck-type `post_json`, nunca a task 1/2 não precisam da
classe concreta para rodar seus próprios testes com fake).

## Contexto

O P3B-01 (§Http, D2) é explícito: `Http` é **boundary**. Duas
consequências práticas:

1. **Require lazy.** `async-http` NÃO pode aparecer em `require_relative`
   no composition root (`lib/harness.rb`) nem em qualquer arquivo carregado
   no wiring-load (D9/D5 do overview — mesma disciplina que já existe para
   `ruby_llm`/`load_skill`, ver `lib/harness.rb`). O `require "async-http"`
   fica DENTRO de `server/a2a/http.rb`, só é executado quando alguém de fato
   instancia `Harness::Server::A2A::Http` (ou seja, quando o operador liga
   `HARNESS_A2A_REMOTES` — task 6). `require "json"` (stdlib) pode ficar no
   topo do arquivo, igual aos outros arquivos de `server/a2a/` (ver
   `server/a2a/protocol.rb:1-3`, que só requer `errors` no topo).
2. **Roda no reactor do turno.** `Http#post_json` é chamado de dentro do
   fiber do turno (via `Client`, chamado pela tool `A2ARemote` — task 4), já
   sob `Async` (o Executor sempre roda dentro de um reactor). Isso é o que
   permite usar `Async::HTTP::Internet` diretamente (ele não bloqueia a
   reactor) sem nenhum wrapper adicional de concorrência aqui.

A separação de teste é deliberada (L6): o `Client` (a LÓGICA — montar
envelope, parsear resposta, poll) é 100% testado com um `http` fake, nunca
com `Http` real. `Http` em si ganha só um teste LEVE que confirma que ele
monta a requisição certa (URL, headers, body serializado) e parseia a
resposta certa — para isso, o teste injeta um `internet` fake (não faz
request de rede nenhuma). A validação contra um endpoint HTTP real fica
para o smoke da task 7 e para verificação manual (ver Notas).

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| CREATE | `server/a2a/http.rb` | `Harness::Server::A2A::Http` |
| CREATE | `spec/harness/server/a2a/http_spec.rb` | teste leve com `internet` fake |

## Passo a passo

### Passo 1 — `server/a2a/http.rb`

**Padrão de referência (como `server/` faz require):** os arquivos de
`server/a2a/` hoje só requerem o que é PURO/stdlib no topo (ex.
`server/a2a/protocol.rb:1-3` requer só `"errors"`, um arquivo irmão). Nenhum
arquivo de `server/a2a/` hoje puxa uma gem externa — `Http` é o primeiro, e
por isso mesmo é o único onde o `require` da gem fica DENTRO da classe, não
no topo do arquivo (diferente do padrão dos irmãos, propositalmente: eles
não têm boundary, este tem).

**API do `Async::HTTP::Internet` (gem `async-http` 0.95.1, presente em
`Gemfile.lock` como dependência transitiva de `async-service`/`falcon`):**
`Internet#post(url, headers, body)` monta um `Protocol::HTTP::Request` e
devolve um objeto de resposta que também é um `Protocol::HTTP::Body::Reader`
— ou seja, tem `#read`, que bloco-a-bloco acumula e devolve o body inteiro
como **String** (não streaming manual necessário aqui; body pequeno de
JSON-RPC). `headers` aceita um `Hash`/array de pares
(`{"content-type" => "application/json", "accept" => "application/json"}`).
`Internet.new` não abre nada eagerly — só cria clients por host sob demanda
(por isso é seguro deixar `internet` lazy no `initialize`).

Esboço:

```ruby
# frozen_string_literal: true

require "json"

module Harness
  module Server
    module A2A
      # Adapter HTTP de produção sobre async-http (P3B-01 §Http, D2/L6).
      # BOUNDARY: é o único arquivo desta fatia que toca a gem async-http —
      # require lazy aqui dentro, nunca no composition root (D9/D5 do
      # overview). O Client (task 1/2) é PURO e recebe isto injetado como
      # `http:`; nunca instancia Http nem conhece async-http.
      #
      # Roda no reactor do turno (chamado de dentro do fiber do Executor via
      # Client -> tool A2ARemote), por isso pode usar Async::HTTP::Internet
      # direto sem wrapper de concorrência adicional.
      class Http
        def initialize(internet: nil)
          require "async/http/internet"
          @internet = internet || Async::HTTP::Internet.new
        end

        # -> Hash (envelope JSON-RPC parseado, chaves STRING — mesmo
        # contrato de parse que Client espera, P3B-01 L2).
        def post_json(url, body)
          headers = { "content-type" => "application/json", "accept" => "application/json" }
          response = @internet.post(url, headers, JSON.generate(body))
          JSON.parse(response.read)
        end

        # Best-effort: fecha os clients cacheados do internet. Chamado no
        # shutdown do processo (wiring — task 6), nunca no meio de um turno.
        def close
          @internet&.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
```

Pontos de atenção na implementação real:
- Confirmar o nome exato do require da gem (`"async/http/internet"` é o
  caminho do arquivo dentro de `async-http`; alternativa mais ampla e
  também válida é `require "async/http"` — checar no `Gemfile.lock`/gem
  instalada qual convenção o resto do projeto já usa, se houver, antes de
  travar um dos dois).
- `initialize(internet: nil)` só faz `require` quando `internet` é `nil`
  (o `nil` é o caminho de produção real; um `internet:` explícito — sempre
  o caso nos testes — nunca dispara o require, então o spec deste arquivo
  não precisa da gem instalada para rodar).

### Passo 2 — `spec/harness/server/a2a/http_spec.rb`

Teste leve (L6): fake `internet` que responde à interface mínima usada por
`post_json` (`#post(url, headers, body) -> objeto com #read`) e grava a
chamada recebida para asserção.

```ruby
# frozen_string_literal: true

require "harness/server/a2a/http" # ajustar path conforme require real do arquivo

RSpec.describe Harness::Server::A2A::Http do
  FakeResponse = Struct.new(:body) do
    def read = body
  end

  class FakeInternet
    attr_reader :calls

    def initialize(response_body)
      @response_body = response_body
      @calls = []
    end

    def post(url, headers, body)
      @calls << { url: url, headers: headers, body: body }
      FakeResponse.new(@response_body)
    end
  end

  it "serializa o body em JSON e envia content-type/accept" do
    internet = FakeInternet.new('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}')
    http = described_class.new(internet: internet)

    result = http.post_json("http://remote/a2a", { jsonrpc: "2.0", id: 1, method: "tasks/get" })

    call = internet.calls.first
    expect(call[:url]).to eq("http://remote/a2a")
    expect(call[:headers]["content-type"]).to eq("application/json")
    expect(call[:headers]["accept"]).to eq("application/json")
    expect(JSON.parse(call[:body])).to eq({ "jsonrpc" => "2.0", "id" => 1, "method" => "tasks/get" })
  end

  it "parseia a resposta com chaves STRING" do
    internet = FakeInternet.new('{"jsonrpc":"2.0","id":1,"result":{"state":"completed"}}')
    http = described_class.new(internet: internet)

    result = http.post_json("http://remote/a2a", { id: 1 })

    expect(result).to eq({ "jsonrpc" => "2.0", "id" => 1, "result" => { "state" => "completed" } })
  end

  it "#close é best-effort (não levanta mesmo se o internet falhar)" do
    internet = FakeInternet.new("{}")
    def internet.close = raise("boom")
    http = described_class.new(internet: internet)

    expect { http.close }.not_to raise_error
  end
end
```

## Edge cases

- **JSON malformado na resposta remota:** `JSON.parse` levanta
  `JSON::ParserError` — `post_json` NÃO faz rescue (não é papel do adapter
  decidir o que significa uma resposta ilegível; quem trata é o `Client`
  ou, na falta de tratamento explícito, propaga até o `rescue StandardError`
  genérico do turno). Documentar isso no comentário do método para quem for
  ler o `Client` depois e se perguntar onde esse erro é pego.
- **Content-type da resposta:** o adapter NÃO valida o `content-type` da
  resposta antes de parsear — só tenta `JSON.parse` do body cru. Um remoto
  que devolva HTML de erro (ex. 502 de um proxy) estoura `JSON::ParserError`
  aqui mesmo, o que é aceitável (mesmo raciocínio do item acima).
- **`close` é best-effort:** `internet&.close` deve nunca levantar — envolto
  em `rescue StandardError; nil; end` (ou equivalente). Motivo: `close` é
  chamado no shutdown do processo (task 6, wiring), onde uma exceção não
  pode derrubar o encerramento gracioso do servidor.
- **`internet` lazy:** se `internet:` não for passado, só é instanciado
  (com o require lazy da gem) dentro do `initialize` — nunca em load-time
  de `server/a2a/http.rb`. Isso é o que garante que simplesmente REQUERER
  este arquivo (ex. num teste que só quer a constante, sem instanciar)
  nunca puxa `async-http` para dentro do processo.
- **`post_json` chamado antes de qualquer request de rede em testes:**
  como o require da gem só acontece se `internet` for `nil`, os testes
  deste arquivo (que sempre passam um fake) rodam sem `async-http`
  instalada/carregada — mantém o spec rápido e sem dependência de rede
  mesmo que a gem não esteja disponível no ambiente de CI.

## Testes

**Arquivo:** `spec/harness/server/a2a/http_spec.rb`

| # | Cenário | Asserção |
|---|---|---|
| 1 | `post_json(url, body)` com `internet` fake | fake recebe `POST` com a URL certa, headers `content-type`/`accept` = `application/json`, body = `JSON.generate(body)` |
| 2 | `internet` fake devolve JSON com `result` | `post_json` devolve `Hash` com chaves STRING (não symbolizadas) |
| 3 | `internet` fake devolve JSON com `error` (envelope JSON-RPC de erro) | `post_json` devolve o `Hash` cru (não interpreta `error`/`result` — quem interpreta é o `Client`, L2) |
| 4 | `close` com `internet` fake cujo `#close` levanta | não propaga a exceção (best-effort) |
| 5 | `Http.new` sem `internet:` (produção) | fora do escopo deste spec leve — não testado aqui (exigiria a gem real/rede); coberto indiretamente pelo smoke da task 7 |

## Definition of Done

- [ ] `Harness::Server::A2A::Http` criado em `server/a2a/http.rb`
- [ ] `require "json"` no topo; `require` de `async-http` LAZY, dentro do
      `initialize`, só quando `internet:` não é passado
- [ ] `post_json(url, body)` serializa `body` com `JSON.generate`, envia
      headers `content-type`/`accept: application/json`, lê a resposta
      (`#read`) e devolve `JSON.parse` (chaves string)
- [ ] `close` fecha o `internet` de forma best-effort (nunca levanta)
- [ ] `spec/harness/server/a2a/http_spec.rb` cobre a tabela de testes acima,
      usando um `internet` fake (sem tocar rede)
- [ ] Suíte inteira verde sem chave de API e sem `async-http` real sendo
      exercitada (spec roda só com o fake)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task NÃO integra `Http` a lugar nenhum — nem o `Client` (task 1/2)
  nem o wiring (task 6) instanciam `Http` ainda; aqui ele só nasce e é
  testado isoladamente, exatamente como o `Client` nasce testado com fake
  na task 1/2.
- **De-risk explícito (nota do overview, L6):** o teste leve com `internet`
  fake garante que a MONTAGEM da requisição e o PARSE da resposta estão
  corretos, mas não prova que `Async::HTTP::Internet#post` de verdade se
  comporta como o fake assume. Antes de considerar a fatia B (wiring +
  smoke, tasks 5-7) fechada, vale rodar `Http` uma vez contra um endpoint
  HTTP real (ex. o próprio `A2A::App` da fatia A subindo em loopback, ou um
  `httpbin`/echo local) para confirmar que a API do `async-http` 0.95.1
  realmente é `post(url, headers, body) -> resposta com #read` como
  documentado aqui — se a assinatura real divergir (ex. a gem exigir um
  objeto `Body` em vez de `String` cru para `body`, ou headers como array
  de pares em vez de `Hash`), ajustar o adapter então, sem reabrir o
  `Client` (que não conhece esses detalhes).
