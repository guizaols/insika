# Task 05 (P3B): A2A::Remotes.parse (config de remotos)

> **Techspec:** [P3B-02-remote-tool-and-wiring.md](../P3B-02-remote-tool-and-wiring.md) (§Remotes, D6) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Low · **Etapa:** B

## Objetivo

Criar `Harness::Server::A2A::Remotes`, o módulo puro que traduz a string de
config `HARNESS_A2A_REMOTES` (formato `id=url,id=url,...`) numa lista de
`Remote` (`Data.define(:id, :url, :description)`). É a peça de config que a
task 6 (wiring) consome para registrar 1 tool `Tools::A2ARemote` por remoto no
Tool Registry — sem ela o wiring não tem de onde ler quais remotos existem.

Escopo estreito e deliberado: só parsing. Nenhuma validação de rede, nenhum
`require "ruby_llm"`, nenhum registro no Tool Registry — isso é da task 6.

## Dependências

Nenhuma — pode começar já.

## Contexto

D6 do overview da fatia B fixa a config como **opt-in**: sem
`HARNESS_A2A_REMOTES` (env ausente ou vazia), a lista de remotos é `[]` e o
wiring (task 6) não registra nenhuma tool `remote_*` — paridade com o resto do
harness (ausência de config nunca é erro, só "nada configurado").

O formato de entrada é uma lista separada por vírgula de pares `id=url`:
```
researcher=https://a.example/a2a,writer=https://b.example/a2a
```
Cada `id` vira o nome estável do remoto (a task 6 monta a tool com nome
`remote_<id>`); a `description`, quando o wiring quiser fornecer uma via
`descriptions:` (hoje não é usado, mas o parâmetro fica pronto — no wiring da
P3B-02 o `description:` da tool cai para um default quando `remote.description`
é `nil`, `remote.description || "Delega ao agente A2A remoto '#{remote.id}'"`),
vem de fora via `descriptions: { "researcher" => "..." }`; se ausente, `Remote#description`
fica `nil` e quem decide o texto default é o consumidor (task 6), não este módulo.

O parse é **defensivo e silencioso para o caller**: entradas malformadas
(sem `=`, ou com `url` vazia) são ignoradas com um `warn` (mesmo padrão de
`lib/harness/registry.rb:27` / `lib/harness/plugin/loader.rb` — `warn
"[tag] mensagem"` na stderr, sem levantar exceção) — um remoto mal configurado
não pode derrubar o boot inteiro do harness nem impedir que os outros remotos
válidos da mesma string sejam registrados.

Módulo **puro**: sem I/O, sem estado, sem `require` além do que a stdlib já dá
(`Data.define` é core desde Ruby 3.2, `Gemfile:5` já exige `>= 3.2`). Não entra
em `lib/harness.rb` (não é core do harness, é peça de `server/`) — é requerido
diretamente pelo wiring (task 6), igual aos outros `server/a2a/*.rb`.

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| CREATE | `server/a2a/remotes.rb` | `Harness::Server::A2A::Remotes` — `Remote` + `.parse` |
| CREATE | `spec/harness/server/a2a/remotes_spec.rb` | cobertura do parser |

## Passo a passo

### Passo 1 — esqueleto do módulo + `Remote`

Seguir o namespacing compacto já usado no snippet do techspec
(`P3B-02-remote-tool-and-wiring.md` linhas 65-73) e o padrão de doc-comment de
topo dos outros arquivos de `server/a2a/` (ex. `server/a2a/errors.rb:1-8`):

```ruby
# frozen_string_literal: true

module Harness::Server::A2A
  # Parse da config de remotos A2A outbound (P3B-02, D6): string
  # "id=url,id=url,.." (env HARNESS_A2A_REMOTES) -> [Remote]. Puro, sem I/O —
  # o wiring (task 6) usa o resultado pra registrar 1 tool `remote_<id>` por
  # remoto no Tool Registry.
  module Remotes
    Remote = Data.define(:id, :url, :description)
  end
end
```

### Passo 2 — `self.parse`

```ruby
module Remotes
  # ...

  # env_string: "researcher=https://a/a2a,writer=https://b/a2a" (ou nil/"").
  # descriptions: hash opcional { id => description } pra enriquecer o Remote
  # (default {} -> Remote#description fica nil; quem decide o texto default
  # exposto ao modelo é o caller, task 6).
  def self.parse(env_string, descriptions: {})
    return [] if env_string.nil? || env_string.strip.empty?

    env_string.split(",").filter_map do |entry|
      entry = entry.strip
      next if entry.empty?

      id, url = entry.split("=", 2) # limit 2: url pode ter '=' (query string)
      id = id&.strip
      url = url&.strip

      if id.nil? || id.empty? || url.nil? || url.empty?
        warn "[a2a] remoto malformado, ignorado: #{entry.inspect}"
        next
      end

      Remote.new(id: id, url: url, description: descriptions[id])
    end
  end
end
```

Pontos de atenção:
- `split("=", 2)` com limite — se o `id` tiver múltiplos `=` (não deveria, mas
  a url legitimamente pode ter `?a=1&b=2`), só o primeiro separa id/url.
- `entry.split("=", 2)` numa entrada sem `=` devolve um array de 1 elemento
  (`["researcher"]`) — `url` fica `nil`, cai no branch de malformado.
- `filter_map` (Ruby 2.7+) evita o `compact` separado depois de um `map` com
  `nil` nos casos ignorados.
- `warn` vai pra stderr e NÃO levanta — mesma disciplina de
  `lib/harness/registry.rb:27` (`warn "[registry] ..."`) e
  `lib/harness/plugin/loader.rb` (`warn "[plugin ...] ..."`): más
  configurações são visíveis nos logs de boot, nunca derrubam o processo.

## Edge cases

- **Entrada sem `=`** (ex. `"researcher"` sozinho na lista, ou vírgula dupla
  sobrando tipo `"a=b,,c=d"` que gera um `entry` vazio após o split): tratado
  — `entry.empty?` pula silenciosamente entradas vazias (sem warn, não é bem
  "malformado", é só ruído de formatação); `id`/`url` ausentes gera warn +
  `next`.
- **`url` vazia** (ex. `"researcher="`): `split("=", 2)` devolve
  `["researcher", ""]` — `url.empty?` true -> warn + ignora essa entrada, as
  demais da mesma string continuam sendo processadas.
- **`id` vazio** (ex. `"=https://a/a2a"`): mesmo tratamento do `url` vazio —
  malformado, warn + ignora (não estava explicitado no techspec, mas segue a
  mesma disciplina: um `Remote` sem `id` não tem como virar `remote_<id>` no
  wiring).
- **`env_string` nil ou `""`/só espaços**: `[]` direto, sem warn (é o caso
  normal de "A2A outbound desligado", D6 — não é erro, é ausência de config).
  Cobre tanto o `ENV["HARNESS_A2A_REMOTES"]` nunca setado (`nil`) quanto o
  wiring chamando com `.to_s` (`""`) — o parser aceita os dois sem o caller
  precisar normalizar antes.
- **Múltiplos remotos válidos na mesma string**: `"researcher=https://a/a2a,writer=https://b/a2a"`
  -> 2 `Remote`s, ordem preservada (ordem de aparição na string).
- **`description:` opcional**: sem passar `descriptions:` (default `{}`),
  `Remote#description` fica `nil` para todo mundo — não é erro, é o
  `Remote.new(description: nil)` explícito do `Data.define`. Com
  `descriptions: { "researcher" => "faz pesquisa" }`, só o remoto com aquele
  `id` ganha a description; os demais ficam `nil`.
- **Espaços ao redor de `id`/`url`/vírgulas** (ex. `"researcher = https://a/a2a, writer=https://b/a2a"`):
  `entry.strip` + `id&.strip`/`url&.strip` toleram espaçamento acidental sem
  precisar de regex.

## Testes

**Arquivo:** `spec/harness/server/a2a/remotes_spec.rb`

| # | Cenário | Asserção |
|---|---|---|
| 1 | `"researcher=https://a/a2a,writer=https://b/a2a"` | `[Remote(id: "researcher", url: "https://a/a2a", description: nil), Remote(id: "writer", url: "https://b/a2a", description: nil)]` (ordem preservada) |
| 2 | 1 único par `"researcher=https://a/a2a"` | array com 1 `Remote` |
| 3 | entrada sem `=` misturada com uma válida (`"researcher,writer=https://b/a2a"`) | só o `Remote` de `writer` sobrevive; `researcher` ignorado |
| 4 | entrada com `url` vazia (`"researcher=,writer=https://b/a2a"`) | só `writer` sobrevive |
| 5 | entrada com `id` vazio (`"=https://a/a2a,writer=https://b/a2a"`) | só `writer` sobrevive |
| 6 | entrada malformada (# 3, 4 ou 5) | `Remotes.parse` emite `warn` (capturar via `expect { ... }.to output(/malformado/).to_stderr` ou mockar `Kernel#warn`) |
| 7 | `env_string` nil | `== []`, sem `warn` |
| 8 | `env_string` `""` | `== []`, sem `warn` |
| 9 | `env_string` só espaços (`"   "`) | `== []` |
| 10 | `descriptions: { "researcher" => "faz pesquisa" }` com `"researcher=https://a/a2a"` | `Remote#description == "faz pesquisa"` |
| 11 | `descriptions:` omitido | `Remote#description == nil` para todos |
| 12 | `url` com query string (`"researcher=https://a/a2a?x=1&y=2"`) | `Remote#url == "https://a/a2a?x=1&y=2"` (split limitado a 2, `=` interno preservado na url) |
| 13 | espaços ao redor (`" researcher = https://a/a2a , writer=https://b/a2a "`) | parseia igual ao caso sem espaços |

## Definition of Done

- [ ] `server/a2a/remotes.rb` criado: `Harness::Server::A2A::Remotes` com
      `Remote = Data.define(:id, :url, :description)` e `self.parse`
- [ ] Nenhum `require` externo à stdlib; nenhuma referência a `ruby_llm`,
      `Tool Registry` ou rede — módulo puro
- [ ] `spec/harness/server/a2a/remotes_spec.rb` cobrindo a tabela de testes
      acima (13 cenários)
- [ ] Suíte inteira verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task NÃO mexe em `config/wiring.rb` (task 6) nem em
  `lib/harness/tools/a2a_remote.rb` (task 4) — só produz a lista de `Remote`
  que a task 6 vai iterar para registrar as tools.
- Esta task NÃO requer o módulo em `lib/harness.rb` — `server/a2a/remotes.rb`
  é requerido diretamente pelo wiring (task 6), igual aos irmãos
  `server/a2a/{client,http,errors,...}.rb` que já existem hoje.
- `descriptions:` fica pronto desde já (kwarg com default `{}`) mesmo que
  nenhum caller da fatia B o popule ainda — evita reabrir a assinatura do
  método numa fase futura só para acrescentar um kwarg opcional; se nunca for
  usado, o comportamento observável (`description: nil`) é idêntico a não
  tê-lo.
</content>
