# Task 06 (P3B): Wiring dos tools remotos + catálogo D5

> **Techspec:** [P3B-02-remote-tool-and-wiring.md](../P3B-02-remote-tool-and-wiring.md) (§Wiring/§Catálogo, D5/D6/D7, L4-L5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Ligar o `Tools::A2ARemote` (task 5) e o parser `A2A::Remotes` (task 4) ao
composition root (`config/wiring.rb`): construir o `A2A_CLIENT` (client HTTP
de saída), iterar `A2A::Remotes.parse(ENV["HARNESS_A2A_REMOTES"])` e
registrar UM tool `remote_<id>` no `REGISTRY` por remoto configurado — via
bloco, com `require` **lazy** da gem `ruby_llm` dentro do bloco (D5/D9), para
que o load do wiring continue gem-free. Junto, fechar o catálogo canônico de
eventos D5 com `:a2a_call` (`00-overview.md` + doc-comment do `Event`) e
estender o guard de carga do wiring (`wiring_load_spec.rb`).

## Dependências

| Task | O que fornece |
|------|----------------|
| Task 03 | `Harness::Server::A2A::Client`/`Http` (client de saída — `server/a2a/client.rb`, `server/a2a/http.rb`) usado por `A2A_CLIENT` |
| Task 04 | `Harness::Server::A2A::Remotes.parse` (`server/a2a/remotes.rb`) — parse de `HARNESS_A2A_REMOTES` em `[Remote(id:, url:, description:)]` |
| Task 05 | `Harness::Tools::A2ARemote` (`lib/harness/tools/a2a_remote.rb`) — a tool que o bloco de registro instancia |

## Contexto

O composition root é único (`config/wiring.rb`, comentário de topo, linhas
1-15): dependências nascem por injeção aqui; constantes globais (`REGISTRY`,
`EVENT_STREAM`, ...) são atalho de leitura. Esta task segue o mesmo padrão
já estabelecido pela task 7 de P3A para o `A2A_APP` (inbound, opt-in) —
mas aqui é o lado **outbound**: em vez de um `if`/`nil`, o wiring itera uma
lista (0..N remotos) e chama `REGISTRY.register` uma vez por item.

**Require lazy no bloco = wiring-load gem-free (D9):** `require_relative
"../lib/harness/tools/a2a_remote"` e `require "ruby_llm"` vivem DENTRO do
bloco passado a `REGISTRY.register`, não no topo do arquivo. O `ToolRegistry`
(`lib/harness/tool_registry.rb`, que herda `Registry`) guarda o bloco como
factory e só o invoca na 1ª resolução/instanciação (turn time) — o mesmo
mecanismo que os builtins de fase 0/2 já usam para skills/tools opcionais.
Isso preserva a garantia (comentário de topo do `wiring.rb`, linha 14-15):
"Requerer este arquivo NÃO carrega `ruby_llm`". Os `require_relative` de
`server/a2a/{client,http,remotes}` NO TOPO do arquivo, por outro lado, são
seguros (não puxam `ruby_llm` — só o `Tools::A2ARemote` puxa, e só dentro do
bloco).

**Opt-in por config (D6):** sem `HARNESS_A2A_REMOTES` no ambiente,
`Remotes.parse("")` devolve `[]` — o `.each` não itera nenhuma vez — nenhum
tool `remote_*` é registrado. Paridade com deployments que não usam a fatia
outbound (mesmo espírito do `A2A_APP` nil da task 7 de P3A para o inbound).

**Nome `remote_<id>`:** evita colisão com tools locais/builtins já
registrados no `REGISTRY` (nenhum builtin hoje usa esse prefixo). `plugin:
"a2a"` no `register` dá rastreio/rollback por plugin (mesmo campo que os
builtins de skill/tool usam).

## Arquivos

| Arquivo | Ação |
|---------|------|
| `config/wiring.rb` | MODIFY — `require_relative` de `server/a2a/{client,http,remotes}` no topo (perto do `server/app`); constrói `A2A_CLIENT`; itera `Remotes.parse(ENV["HARNESS_A2A_REMOTES"])` registrando `remote_<id>` no `REGISTRY` |
| `docs/techspec/00-overview.md` | MODIFY — tabela D5: adiciona linha `:a2a_call` |
| `lib/harness/event.rb` | MODIFY — doc-comment do `Event` (catálogo fechado) menciona a extensão P3B |
| `spec/harness/wiring_load_spec.rb` | MODIFY — novos exemplos: `A2A_CLIENT` construído; sem `HARNESS_A2A_REMOTES` → nenhum `remote_*` em `REGISTRY.names` |

## Passo a passo

### Passo 1 — `require_relative` de `server/a2a/{client,http,remotes}` no topo

Junto do `require_relative "../server/app"` já existente (linha ~18 do
wiring atual). Estes 3 arquivos NÃO puxam `ruby_llm` (confirmar nas tasks
3/4 — só o `Tools::A2ARemote`, task 5, puxa, e só dentro do bloco do Passo
3). Se alguma dessas classes tiver `require "ruby_llm"` no topo do próprio
arquivo, é sinal de que a task correspondente (3 ou 4) não seguiu D5/D9 —
sinalizar no code review, não contornar aqui.

### Passo 2 — Construir `A2A_CLIENT`

Inserir numa seção nova, próxima de onde a task 7 de P3A construiu o
`A2A_APP` (entre `CONFIG` e `APP`, ou em qualquer ponto após os
`require_relative` do Passo 1 — não depende de `CONFIG`/`BUS`/etc., então
pode subir mais cedo se preferir manter as seções por assunto):

```ruby
# --- A2A outbound (P3B) — federação de saída, OPT-IN ------------------------
A2A_CLIENT = Harness::Server::A2A::Client.new(http: Harness::Server::A2A::Http.new)
```

### Passo 3 — Registrar um tool por remoto configurado

Logo em seguida:

```ruby
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

**Padrão de referência (codebase):** é o mesmo formato de bloco que outros
tools opcionais/plugin já usam com `REGISTRY.register(name, plugin: ...) {
... }` (ver builtins registrados via bloco em fatias anteriores) — nada
novo no mecanismo do `ToolRegistry#register` (`lib/harness/tool_registry.rb`
linha 22, que apenas repassa `plugin:`/`optional:`/`side_effect:` normalizados
ao `Registry` genérico e guarda o bloco como factory).

> **Cuidado de ordem:** o `.each` referencia `A2A_CLIENT` e `EVENT_STREAM` —
> garantir que ambos já estão definidos ANTES deste bloco (`EVENT_STREAM` já
> existe bem cedo no arquivo; `A2A_CLIENT` é construído no Passo 2, logo
> antes). Mesma classe de edge case já registrada na task 11 de P2B.

### Passo 4 — Catálogo D5 (`docs/techspec/00-overview.md`)

Na tabela do D5 (linhas ~171-190), adicionar a linha nova logo após
`:memory_written` e antes de `:done` (mesmo padrão usado pelas fatias 2-B/2-C
para estender o catálogo):

```markdown
| `:a2a_call` | `{ agent, remote_task_id, state }` | Tools::A2ARemote (P3B) |
```

Opcionalmente, um parágrafo curto após a nota da fatia 2-B (linhas 196-199)
registrando que a fatia 3-B estendeu o catálogo com `:a2a_call` (mesma
convenção).

### Passo 5 — Doc-comment do `Event` (`lib/harness/event.rb`)

O comentário de topo do `Data.define` já lista as extensões por fatia
(`:capability_resolved`/`:tool_search` da 2-B, `:memory_written` da 2-C).
Adicionar `:a2a_call` da fatia 3-B ao mesmo comentário, referenciando este
doc (`P3B-02`).

## Edge cases

- **Sem `HARNESS_A2A_REMOTES` no ambiente:** `ENV[...].to_s` é `""` →
  `Remotes.parse("")` devolve `[]` (task 4) → o `.each` não itera nenhuma
  vez → nenhum tool `remote_*` é registrado no `REGISTRY` — paridade com
  deployments que não usam a fatia outbound (D6).
- **`HARNESS_A2A_REMOTES` com entradas malformadas:** já é responsabilidade
  do `Remotes.parse` (task 4) ignorá-las com warn; esta task não valida
  novamente — só itera o que `parse` devolveu.
- **Require lazy idempotente:** `require "ruby_llm"` e `require_relative
  "../lib/harness/tools/a2a_remote"` rodam a cada `.call` do bloco factory
  SE o `ToolRegistry`/`Registry` não fizer memoização de instância — `require`
  em Ruby é idempotente por si (não recarrega o arquivo já carregado), então
  chamadas repetidas são seguras e baratas (checagem de `$LOADED_FEATURES`).
- **`server/a2a/{client,http,remotes}` não devem puxar `ruby_llm` no load:**
  é a garantia central de D9 — se alguma dessas classes (tasks 3/4)
  acidentalmente tiver `require "ruby_llm"` no topo do arquivo (fora de
  bloco), o `require_relative` do Passo 1 (que roda no topo do
  `config/wiring.rb`, fora de qualquer bloco) já carregaria a gem no load do
  wiring — quebrando o contrato "requerer este arquivo NÃO carrega
  `ruby_llm`" (comentário de topo do `wiring.rb`). Validar isso é parte do
  code review desta task, não só das tasks 3/4.
- **Nome `remote_<id>` colidindo com um tool local já registrado:** fora de
  escopo desta task tratar colisão (nenhum builtin hoje usa esse prefixo);
  se um deployment concreto registrar um plugin com esse nome, é
  responsabilidade do operador escolher outro `id` — mesmo espírito de
  "não inventar validação nova" já visto em tasks de wiring anteriores.

## Testes

**Arquivo:** `spec/harness/wiring_load_spec.rb`

| Cenário | Verificação |
|---|---|
| Carga do composition root sem `HARNESS_A2A_REMOTES` (base, sem mexer em ENV) | `Harness::Wiring::A2A_CLIENT` é `Harness::Server::A2A::Client` |
| Mesma carga, sem a env | `described_class::REGISTRY.names` NÃO inclui nenhum nome começando com `"remote_"` |

```ruby
it "A2A_CLIENT é construído (P3B, outbound)" do
  expect(described_class::A2A_CLIENT).to be_a(Harness::Server::A2A::Client)
end

it "sem HARNESS_A2A_REMOTES, nenhum tool remote_* é registrado" do
  expect(described_class::REGISTRY.names).to be_none { |n| n.start_with?("remote_") }
end
```

> Não é preciso (nem dá, sem setar `HARNESS_A2A_REMOTES`) testar aqui o
> caminho "com remotos configurados, 1 tool por remoto" — isso é coberto
> pelo spec dedicado do `A2ARemote`/`Remotes.parse` (tasks 4/5) e pelo smoke
> loopback (`spec/e2e/smoke_phase3b_spec.rb`, cenário 3: "sem remotos →
> nenhum tool `remote_*`" também cabe aqui, mas o caminho positivo
> "com remotos" precisa setar `ENV["HARNESS_A2A_REMOTES"]` ANTES do
> `require_relative "../../config/wiring"` do spec — fora do escopo mínimo
> desta task, que garante o caminho default/opt-out).

## Definition of Done

- [ ] `config/wiring.rb`: `require_relative` de `server/a2a/{client,http,remotes}` no topo, perto do `server/app`
- [ ] `A2A_CLIENT = Harness::Server::A2A::Client.new(http: Harness::Server::A2A::Http.new)` construído
- [ ] `Remotes.parse(ENV["HARNESS_A2A_REMOTES"].to_s).each` registra `REGISTRY.register("remote_#{remote.id}", plugin: "a2a") { ... }` com `require "ruby_llm"` e `require_relative "../lib/harness/tools/a2a_remote"` LAZY dentro do bloco
- [ ] Sem `HARNESS_A2A_REMOTES`, nenhum tool `remote_*` registrado (loop vazio)
- [ ] `docs/techspec/00-overview.md`: linha `:a2a_call` adicionada à tabela D5
- [ ] `lib/harness/event.rb`: doc-comment do `Event` menciona a extensão P3B (`:a2a_call`)
- [ ] `spec/harness/wiring_load_spec.rb` estendido com os 2 exemplos novos (`A2A_CLIENT`; nenhum `remote_*` sem env)
- [ ] Suíte verde sem chave de API e sem `HARNESS_A2A_REMOTES` setado (confirma que o load do wiring continua gem-free — nenhum `require "ruby_llm"` disparado fora do bloco)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task é 100% wiring — nenhuma classe nova, nenhum método novo. Toda a
  lógica do A2A outbound (`Client`, `Http`, `Remotes.parse`, `Tools::A2ARemote`)
  já foi entregue pelas tasks 3-5; aqui só se liga o fio final ao composition
  root, no mesmo espírito da task 7 de P3A ("100% de fiação — nenhuma lógica
  nova") e da task 11 de P2B.
- O padrão de require lazy dentro do bloco de `REGISTRY.register` é o
  mecanismo central de D5/D9 desta fatia: garante que ambientes que não
  configuram `HARNESS_A2A_REMOTES` (a maioria, hoje) nunca pagam o custo de
  carregar `ruby_llm` só por causa do wiring de tools A2A outbound.
- O smoke E2E loopback (`spec/e2e/smoke_phase3b_spec.rb`, fora do escopo
  desta task — ver P3B-02 §Smoke) é quem prova o caminho positivo ponta a
  ponta (outbound chamando inbound in-process); esta task só garante que o
  fio de wiring existe e que o caminho default (sem env) não registra nada.
