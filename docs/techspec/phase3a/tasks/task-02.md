# Task 02 (P3A): `A2A::Message` (parts ↔ texto)

> **Techspec:** [P3A-01-a2a-protocol-and-projection.md](../P3A-01-a2a-protocol-and-projection.md) (§Message, D4/L3) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo

Criar `Harness::Server::A2A::Message`: o módulo puro que traduz entre o
`Message` do wire A2A (Hash com `parts`, cada part um TextPart/FilePart/
DataPart) e o `String` que o núcleo entende. Duas funções, sem estado, sem
I/O:

1. `text_from(a2a_message)` — extrai o texto de uma Message A2A recebida
   (`message/send` de um cliente A2A), concatenando os `TextPart`. Nesta
   fatia só `TextPart` existe (D4/L3 do P3A-01); qualquer outro tipo de part
   é ignorado silenciosamente.
2. `agent_message(text)` — monta a Message A2A que o servidor DEVOLVE (usada
   pela `TaskProjection`, task 3, para popular `status.message` de uma Task
   `completed`/`failed`), sempre como um único `TextPart`.

Task pequena e isolada (Etapa A, "sem dependência forte de arquivo
compartilhado" por design — `server/a2a/*` são arquivos novos e exclusivos por
task) para poder nascer em paralelo com as tasks 1, 3 e 4.

## Dependências

Nenhuma — pode começar já.

## Contexto

O P3A-01 (§Message) define o módulo como uma das quatro peças PURAS que
compõem a camada de tradução A2A (`server/a2a/*`), sem tocar servidor nem
stores — o `A2A::App` (P3A-02, task 5) as compõe depois. `Message` é a peça
mais estreita das quatro: só sabe ler/escrever o campo `parts` de uma Message
A2A, sem saber nada de Task, estado ou envelope JSON-RPC.

Duas armadilhas de compatibilidade que o techspec já resolveu e que este
módulo precisa encarnar (L3):

- **Discriminador de tipo do part**: o spec A2A ~v0.2+ usa `kind: "text"`
  para identificar um TextPart; specs mais antigos usavam `type: "text"`.
  `text_from` precisa tolerar AMBOS na leitura — normaliza checando `kind` e,
  na ausência dela, `type`. Na escrita (`agent_message`), o formato é sempre
  o atual: `kind: "text"`.
- **Só `TextPart` nesta fatia**: `FilePart`/`DataPart` (partes com
  binário/estruturado em vez de texto) são ignorados na leitura — não geram
  erro, simplesmente não contribuem para a String resultante. Suporte a eles
  é evolução fora de escopo (ver §Notas do P3A-01 "Fora de escopo").

Este módulo não tem análogo direto já existente no codebase (é tradução de
wire A2A, um formato novo nesta fase), mas o ESTILO de módulo funcional puro
(sem classe, sem estado, `def self.foo`) já aparece em `Harness::Server::A2A::Protocol`
e `Harness::Server::A2A::Errors` (tasks irmãs desta mesma etapa) — mesma
convenção de nomeação e de namespace.

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| CREATE | `server/a2a/message.rb` | `Harness::Server::A2A::Message` — `text_from`/`agent_message` |
| CREATE | `spec/harness/server/a2a/message_spec.rb` | contrato das duas funções |

## Passo a passo

### Passo 1 — esqueleto do módulo

Criar `server/a2a/message.rb`. Segue o padrão `Server::A2A::*` já definido no
techspec (módulo com métodos de classe, sem estado, `frozen_string_literal`).

**Padrão de referência (codebase, forma dos irmãos `Protocol`/`Errors` no
próprio techspec, P3A-01):**
```ruby
module Harness
  module Server
    module A2A
      module Protocol
        def self.parse(body)
          # ...
        end
      end
    end
  end
end
```

```ruby
# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Tradução PURA entre `parts` de uma A2A Message (wire) e o `String` que
      # o núcleo entende (P3A-01 §Message, D4/L3). Sem HTTP, sem stores, sem
      # RubyLLM — só Hash/Array/String. Composto pelo A2A::App (P3A-02, task
      # 5): `text_from` na entrada (message/send), `agent_message` na saída
      # (TaskProjection, task 3, para status.message).
      module Message
      end
    end
  end
end
```

### Passo 2 — `text_from`

A2A Message de entrada: `{ role: "user", parts: [{kind: "text", text: "oi"},
...] }` (chaves podem vir como String ou Symbol dependendo de quem já fez o
`JSON.parse` — o `Protocol.parse`/servidor entrega Hash com chaves String
neste projeto; ver `parse_body` do `Server::App`). Implementar tolerando
AMBAS as formas de chave (String/Symbol) nas próprias parts, já que este
módulo é chamado isoladamente nos testes com Hashes literais Ruby (Symbol) e,
em produção, com o resultado de `JSON.parse` (String) — não assumir qual dos
dois o caller usa.

```ruby
# A2A Message (Hash) -> String (concatena os TextPart, na ordem em que
# aparecem em `parts`). Ignora qualquer part que não seja TextPart (D4/L3:
# só TextPart nesta fatia). "" se `parts` ausente, vazio, ou nenhuma part for
# TextPart.
def self.text_from(a2a_message)
  parts = a2a_message[:parts] || a2a_message["parts"] || []
  parts.filter_map { |part| text_part_text(part) }.join
end

# Extrai o `text` de uma part SE ela for TextPart (kind/type == "text");
# nil caso contrário (part sem texto, ou FilePart/DataPart) -> filter_map
# acima descarta.
def self.text_part_text(part)
  kind = part[:kind] || part["kind"] || part[:type] || part["type"]
  return nil unless kind == "text"

  part[:text] || part["text"]
end
private_class_method :text_part_text
```

Pontos de atenção:
- `filter_map` (não `map` + `compact`) descarta `nil` E `false` de uma vez —
  aqui só importa o `nil` (não-TextPart), mas `filter_map` é a forma idiomática
  e mais curta.
- `.join` sem separador: concatenação direta (múltiplos TextPart formam UMA
  string contínua — não é junção com espaço/quebra de linha; é o
  comportamento mais simples e o que o techspec pede, "concatena").
- `text_part_text` privado: é detalhe de implementação de `text_from`, não
  parte do contrato público do módulo (só `text_from`/`agent_message` são
  chamados de fora, pela `App`/`TaskProjection`).

### Passo 3 — `agent_message`

```ruby
# String -> A2A Message { role: "agent", parts: [TextPart] }. Sempre um
# único TextPart, sempre `kind: "text"` (formato atual do wire, D4/L3 — a
# tolerância a `type` é só na LEITURA via text_from).
def self.agent_message(text)
  { role: "agent", parts: [{ kind: "text", text: text }] }
end
```

Não há normalização/validação de `text` aqui (ex.: `text.to_s`) — quem chama
(`TaskProjection`, task 3) já garante que passa uma `String` (o `content`/
`error` da Task); esta função não precisa adivinhar o tipo do argumento.

## Edge cases

- **Só `TextPart` é lido**: uma part `{kind: "file", ...}` ou
  `{kind: "data", ...}` no meio de `parts` não quebra `text_from` nem
  contribui para a String — é simplesmente pulada (`text_part_text` devolve
  `nil` para ela).
- **Tolera `type` (spec antigo) além de `kind` (spec atual)**: `text_from`
  aceita `{type: "text", text: "oi"}` OU `{kind: "text", text: "oi"}`
  igualmente. `kind` tem precedência se, por algum motivo, uma part tiver
  as duas chaves (não deveria acontecer no wire real, mas a ordem de checagem
  no `||` já resolve isso sem caso especial).
- **`parts` ausente ou `[]`**: `a2a_message[:parts]`/`["parts"]` nil vira
  `[]` (o `|| []`), `filter_map` sobre array vazio devolve `[]`,
  `.join` de `[]` é `""`. Nenhum `NoMethodError`.
- **Nenhuma part é TextPart** (só File/Data): mesmo resultado do caso acima,
  `""` — não é tratado como erro, é o comportamento documentado no techspec
  ("'' se nenhum texto").
- **Múltiplos `TextPart` concatenam SEM separador**: `parts: [{kind: "text",
  text: "oi "}, {kind: "text", text: "tudo bem?"}]` -> `"oi tudo bem?"` (a
  concatenação preserva espaços que já estiverem dentro de cada `text`; o
  módulo não insere nada entre as parts).
- **Chaves String vs Symbol na Message/parts**: `text_from` funciona igual
  para `{"parts" => [{"kind" => "text", "text" => "oi"}]}` (JSON já
  parseado) e para `{parts: [{kind: "text", text: "oi"}]}` (Hash literal nos
  testes) — nenhuma das duas formas é privilegiada além da ordem de checagem
  no `||`.
- **`agent_message` não filtra/normaliza a Task de origem**: se `content`/
  `error` vierem `nil` de quem chama (não deveria, é bug de quem chama), o
  resultado é `{role: "agent", parts: [{kind: "text", text: nil}]}` — este
  módulo não valida isso; é responsabilidade de quem popula `content:`/
  `error:` na `TaskProjection` (task 3) nunca passar `nil` para
  `agent_message`.

## Testes

**Arquivo:** `spec/harness/server/a2a/message_spec.rb`

| # | Cenário | Asserção |
|---|---|---|
| 1 | `text_from` com um único TextPart (`kind: "text"`) | devolve o `text` da part |
| 2 | `text_from` com múltiplos TextPart | concatena na ordem, sem separador |
| 3 | `text_from` com part usando `type: "text"` (spec antigo) | mesmo resultado do `kind` |
| 4 | `text_from` com mistura de TextPart + part não-text (`kind: "file"`) | ignora a não-text, concatena só as TextPart |
| 5 | `text_from` com `parts: []` | `""` |
| 6 | `text_from` sem chave `parts` (Hash vazio ou só `role`) | `""` |
| 7 | `text_from` só com parts não-text (nenhum TextPart) | `""` |
| 8 | `text_from` com chaves String (simulando `JSON.parse`) | mesmo resultado do Hash com Symbol |
| 9 | `agent_message("oi")` | `{ role: "agent", parts: [{ kind: "text", text: "oi" }] }` (shape exato, incl. `role: "agent"`) |
| 10 | `agent_message("")` | `{ role: "agent", parts: [{ kind: "text", text: "" }] }` — string vazia não é tratada como ausência |

```ruby
# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../../server/a2a/message"

RSpec.describe Harness::Server::A2A::Message do
  describe ".text_from" do
    it "extrai o texto de um único TextPart" do
      msg = { parts: [{ kind: "text", text: "oi" }] }
      expect(described_class.text_from(msg)).to eq("oi")
    end

    it "concatena múltiplos TextPart sem separador" do
      msg = { parts: [{ kind: "text", text: "oi " }, { kind: "text", text: "tudo bem?" }] }
      expect(described_class.text_from(msg)).to eq("oi tudo bem?")
    end

    it "tolera a chave type (spec A2A mais antigo)" do
      msg = { parts: [{ type: "text", text: "oi" }] }
      expect(described_class.text_from(msg)).to eq("oi")
    end

    it "ignora parts não-text (FilePart/DataPart)" do
      msg = { parts: [{ kind: "text", text: "a" }, { kind: "file", uri: "x" }, { kind: "text", text: "b" }] }
      expect(described_class.text_from(msg)).to eq("ab")
    end

    it "devolve string vazia se parts for []" do
      expect(described_class.text_from({ parts: [] })).to eq("")
    end

    it "devolve string vazia se parts estiver ausente" do
      expect(described_class.text_from({ role: "user" })).to eq("")
    end

    it "devolve string vazia se nenhuma part for TextPart" do
      msg = { parts: [{ kind: "file", uri: "x" }] }
      expect(described_class.text_from(msg)).to eq("")
    end

    it "funciona com chaves String (Hash de JSON.parse)" do
      msg = { "parts" => [{ "kind" => "text", "text" => "oi" }] }
      expect(described_class.text_from(msg)).to eq("oi")
    end
  end

  describe ".agent_message" do
    it "monta a Message com role agent e um TextPart" do
      expect(described_class.agent_message("oi")).to eq(
        { role: "agent", parts: [{ kind: "text", text: "oi" }] }
      )
    end

    it "aceita string vazia sem tratar como ausência" do
      expect(described_class.agent_message("")).to eq(
        { role: "agent", parts: [{ kind: "text", text: "" }] }
      )
    end
  end
end
```

## Definition of Done

- [ ] `server/a2a/message.rb` criado, `Harness::Server::A2A::Message` com
      `text_from`/`agent_message` conforme P3A-01 §Message
- [ ] `text_from` tolera `kind` E `type`, ignora parts não-text, devolve `""`
      quando não há texto (parts ausente/vazio/só não-text)
- [ ] `agent_message` sempre devolve `{role: "agent", parts: [{kind: "text",
      text:}]}`
- [ ] `spec/harness/server/a2a/message_spec.rb` criado, cobrindo a tabela de
      testes acima
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Este módulo NÃO é requerido em nenhum composition root ainda — nem
  `lib/harness.rb` (que é o composition root do NÚCLEO, não de `server/`),
  nem `config/wiring.rb`. O wiring de `server/a2a/*` inteiro é escopo da task
  7 (Etapa B); até lá, o arquivo só é carregado diretamente pelo spec
  (`require_relative`) e, depois, pela task 5 (`A2A::App`) quando ela compuser
  as quatro peças puras.
- `FilePart`/`DataPart` (partes com conteúdo binário/estruturado em vez de
  texto puro) ficam de fora desta fatia por design — é evolução futura
  listada no "Fora de escopo" do P3A-01, junto com `message/stream` e batch
  JSON-RPC. Quando chegar a hora, `text_from` provavelmente ganha um segundo
  modo de retorno (lista de parts tipadas) em vez de só concatenar texto —
  não antecipar essa forma aqui.
- Diretório `server/a2a/` é novo — junto com as tasks irmãs (1, 3, 4) desta
  mesma etapa, cada uma cria seu próprio arquivo ali sem conflito (nenhuma
  edita arquivo de outra). O diretório de spec espelha:
  `spec/harness/server/a2a/`.
