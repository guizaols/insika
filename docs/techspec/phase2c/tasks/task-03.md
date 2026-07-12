# Task 03 (P2C): Threading de tenant no Executor (`ContextRequest` + `TurnState`)

> **Techspec:** [P2C-01-memory-store-and-read.md](../P2C-01-memory-store-and-read.md) (§Threading de tenant, D6) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Fazer o `tenant` chegar de fato aos Context Providers e ao `TurnState`. Hoje o
`Command` já carrega `meta[:tenant]` (`command.rb:21`) e o provider `Request`
(`lib/harness/context/providers/request.rb:12`) já chama `request.tenant` —
mas o objeto que os providers REALMENTE recebem, o `Executor::ContextRequest`
(Struct interno, `executor.rb:326`), não tem esse campo hoje: qualquer chamada
a `request.tenant` levanta `NoMethodError` em produção (só não estoura porque
nenhum provider real chama isso ainda — é um seam morto da Fase 1, task-14/15
de débito registrado no `00-overview.md`). Sem esta task, o read provider de
memória (task 4) e a tool `remember` (P2C-02, task 5/6) não têm de onde ler o
tenant do turno — a fatia C inteira fica sem escopo multi-tenant.

Esta task fecha só essa costura: `ContextRequest` ganha `:tenant`,
`build_context_request` o popula a partir do `Command`, e o mesmo valor é
espelhado em `TurnState#tenant` para o write path (`remember`, task 6) usar
exatamente o mesmo scope que o read path.

## Dependências

Nenhuma — pode começar já.

## Contexto

O `Executor::ContextRequest` (`executor.rb:326`) é um `Struct.new(...,
keyword_init: true)` **interno e privado** ao Executor — não confundir com um
possível "contract" `Data.define` de request documentado em outro lugar da
techspec. É este Struct, e só ele, que `@context_builder.call(request)`
recebe e que cada `ContextProvider#call(request)` (Skill, ToolSearch, Session,
Request, e agora Memory) enxerga. Adicionar um campo aqui é o único jeito de
um provider "ver" tenant — não há atalho por fora do Struct.

O `Command` (`lib/harness/command.rb:21-30`) já resolve isso do lado da
escrita: `Command.build(type, payload, transport:, tenant:)` sempre grava
`meta[:tenant]` (`nil` se não informado). A Task persiste o Command como Hash
(`task.command`), e o Executor já tem um helper que reconstrói um `Command`
real a partir desse Hash — `rebuild_command(task)`
(`executor.rb:508-515`) — usado hoje só pelo `policy_request` (para a
`WorkflowAllowlist`). Esta task reusa esse MESMO helper para extrair o
tenant, em vez de duplicar a leitura de `task.command["meta"]`/`task.command[:meta]`.

O provider `Request` (`context/providers/request.rb:12`) já lê
`request.tenant` — essa linha já existe no código, plantada como seam da Fase
1 para este exato momento. Depois desta task, ela deixa de ser dead code: com
um Command que carrega `tenant`, o fragmento `<request_context>` passa a
incluir a linha `tenant: <valor>` quando presente (comportamento observável
novo, mas estritamente aditivo — sem tenant, `lines` continua vazio nesse
ponto e nada muda).

**Não** mexemos no seam `vars` (`request.vars`, chamado em
`context/providers/request.rb:13` e `context/providers/session.rb:48`, mas
ausente do Struct `ContextRequest` do mesmo jeito que `tenant` estava) — é
outro pedaço do mesmo débito da Fase 1, fora do escopo D6 desta fatia
(reabri-lo exigiria decidir de onde `vars` viria, o que não está especificado
aqui). Só `tenant` é tocado.

## Arquivos

| Arquivo | Ação | Razão |
|---|---|---|
| `lib/harness/executor.rb` | MODIFY | `ContextRequest` Struct ganha `:tenant`; `build_context_request` popula `tenant: command_tenant(task)`; novo helper privado `command_tenant(task)`; `run_pipeline` seta `state.tenant = command_tenant(task)` |
| `lib/harness/turn_state.rb` | MODIFY | novo `attr_accessor :tenant` (padrão dos campos "internos" já documentados: `capability_names`, `skip_side_effects`) |
| `spec/harness/executor_pipeline_spec.rb` | MODIFY | testes de integração: `build_context_request` popula `tenant` no request que chega ao `FakeContextBuilder`; `state.tenant` setado no `run_pipeline`; tenant ausente → `nil` em ambos, sem quebrar o turno |
| `spec/harness/executor_spec.rb` | MODIFY (opcional) | teste unitário direto de `command_tenant` via `send`, se for mais simples que subir o pipeline inteiro para os casos de string vs symbol key |

## Passo a passo

### Passo 1 — `ContextRequest` Struct ganha `:tenant`

**Padrão de referência (codebase)** — Struct atual (`lib/harness/executor.rb:326-327`):

```ruby
# Correlação call<->execução p/ side-effects/skip (interno; doc 03 §3 Notes).
ContextRequest = Struct.new(:task, :profile, :message, :session, :history, :checkpoint,
                            keyword_init: true)
```

Acrescentar `:tenant` à lista de membros:

```ruby
# Correlação call<->execução p/ side-effects/skip (interno; doc 03 §3 Notes).
# :tenant (P2C, D6): do Command (command_tenant), reconcilia o débito Fase 1 —
# o provider Request (context/providers/request.rb) já chamava request.tenant.
ContextRequest = Struct.new(:task, :profile, :message, :session, :history, :checkpoint, :tenant,
                            keyword_init: true)
```

`Struct.new(..., keyword_init: true)` não exige que todo keyword seja
passado na construção — quem já chama `ContextRequest.new(...)` sem
`tenant:` continua funcionando, com `tenant` = `nil` por default de Struct.
Nenhum call site existente quebra.

### Passo 2 — `build_context_request` popula `tenant:`

**Padrão de referência (codebase)** — método atual (`lib/harness/executor.rb:486-491`):

```ruby
def build_context_request(task, profile, state, resume_from)
  session = task.session_id ? @session_store.find(task.session_id) : nil
  ContextRequest.new(task: task, profile: profile, message: state.message,
                     session: session, history: command_history(task),
                     checkpoint: resume_from)
end
```

Vira:

```ruby
def build_context_request(task, profile, state, resume_from)
  session = task.session_id ? @session_store.find(task.session_id) : nil
  ContextRequest.new(task: task, profile: profile, message: state.message,
                     session: session, history: command_history(task),
                     checkpoint: resume_from, tenant: command_tenant(task))
end
```

### Passo 3 — novo helper privado `command_tenant(task)`

Colocar perto de `rebuild_command` (mesma vizinhança — reusa o método,
não duplica a leitura de `task.command`):

```ruby
# tenant do turno (P2C, D6): vem do Command (Command.build(..., tenant:) ->
# meta[:tenant], command.rb:21). Reusa rebuild_command (já reconstrói um
# Command real a partir do Hash persistido na Task — mesmo helper que o
# policy_request usa) em vez de duplicar a leitura de task.command["meta"].
# meta pode chegar com chave string OU symbol (Task persiste como Hash "cru";
# Command#meta em si sempre usa symbol na escrita via build, mas um Command
# reidratado de JSON/Hash externo pode ter string) — checa as duas. Ausente
# -> nil (o MemoryStore, P2C-01, aplica DEFAULT_TENANT = "_default"; não é
# responsabilidade do Executor decidir esse fallback).
def command_tenant(task)
  meta = rebuild_command(task).meta
  meta["tenant"] || meta[:tenant]
end
```

**Padrão de referência (codebase)** — `rebuild_command` atual
(`lib/harness/executor.rb:508-515`), que este helper reusa sem alterar:

```ruby
def rebuild_command(task)
  cmd = task.command
  Harness::Command.new(
    type: (cmd["type"] || cmd[:type]).to_s.to_sym,
    payload: cmd["payload"] || cmd[:payload] || {},
    meta: cmd["meta"] || cmd[:meta] || {}
  )
end
```

Note que `rebuild_command` já resolve `meta` como `cmd["meta"] ||
cmd[:meta] || {}` — ou seja, `meta` em si nunca é `nil` (na pior das
hipóteses é `{}`), mas as CHAVES **dentro** de `meta` (`tenant`) podem estar
como string ou symbol dependendo de como a Task foi persistida — por isso o
`command_tenant` checa as duas (`meta["tenant"] || meta[:tenant]`), o mesmo
padrão defensivo que `rebuild_command` já usa para `type`/`payload`.

### Passo 4 — `run_pipeline` seta `state.tenant`

**Padrão de referência (codebase)** — trecho atual de `run_pipeline`
(`lib/harness/executor.rb:355-370`), logo após montar o `ContextRequest` e
ANTES do sub-passo `resolve_capabilities` (P2B, já presente):

```ruby
request = build_context_request(task, profile, state, resume_from)
state.context = @context_builder.call(request)
drain_and_maybe_suspend(task, actor)

save_initial_checkpoint(task, profile, state)

# sub-passo de resolução de capability (P2B D3): ENTRE Context e Policy.
state.capability_names = resolve_capabilities(profile, state.context)
```

Acrescentar a atribuição de `state.tenant` logo após montar o `request`
(mesmo turno, mesmo valor que já foi para o `ContextRequest` — não recalcula,
não pode divergir):

```ruby
request = build_context_request(task, profile, state, resume_from)
state.context = @context_builder.call(request)
# P2C, D6: mesmo tenant que já foi ao ContextRequest (Passo 2) — o write path
# (Tools::Remember, P2C-02 task 6) lê state.tenant para gravar no MESMO scope
# que o read provider (Context::Providers::Memory, task 4) consultou.
state.tenant = request.tenant
drain_and_maybe_suspend(task, actor)

save_initial_checkpoint(task, profile, state)

state.capability_names = resolve_capabilities(profile, state.context)
```

`state.tenant = request.tenant` (em vez de chamar `command_tenant(task)` de
novo) evita computar o mesmo valor duas vezes e garante por construção que
`ContextRequest#tenant` e `TurnState#tenant` nunca divergem no mesmo turno.

### Passo 5 — `TurnState` ganha `attr_accessor :tenant`

**Padrão de referência (codebase)** — campos "internos" já documentados em
`lib/harness/turn_state.rb:19-30` (mesmo estilo de comentário: quem seta,
quando, o que significa vazio/nil):

```ruby
# Interno (P2B, D4): impl_name(String) -> nome ESTÁVEL da capability que o
# resolveu, calculado por resolve_capabilities ANTES do policy_request e
# consultado DEPOIS de @policy_engine.decide, na junção pós-Policy, para
# decidir quais impls entram como Capability::ResolvedTool. {} = sem
# capability_registry ou profile.capabilities vazio (paridade Fase 1).
attr_accessor :capability_names

# Interno (P2B, Tool Search): ids de side-effects já concluídos no turno
# interrompido, propagados às tools PROMOVIDAS pelo tool_search (mesmo `skip`
# que o wrap_tools das eager recebe). Setado no run_pipeline pela task 10;
# nil = turno novo (Array(nil) => []).
attr_accessor :skip_side_effects
```

Acrescentar, no mesmo bloco de campos internos:

```ruby
# Interno (P2C, D6): tenant do Command do turno, setado no run_pipeline logo
# após montar o ContextRequest (mesmo valor, nunca recalculado) — o write
# path (Tools::Remember, P2C-02) lê state.tenant para gravar no MESMO scope
# que o read provider (Context::Providers::Memory) consultou. nil = sem
# tenant no Command (o MemoryStore aplica DEFAULT_TENANT = "_default").
attr_accessor :tenant
```

Não precisa de default explícito no `initialize` (`nil` é o comportamento
correto de "sem tenant" — diferente de `capability_names`, que precisa de
`{}` porque código existente já chama `.key?`/`.empty?` nele sem checar
`respond_to?`; nenhum consumidor de `state.tenant` faz isso ainda nesta
task).

## Edge cases

- **Command sem tenant** (`Command.build(type, payload)` sem `tenant:`, ou
  Task antiga persistida antes desta fatia) → `meta[:tenant]` é `nil` →
  `command_tenant` devolve `nil` → `ContextRequest#tenant` e
  `TurnState#tenant` são ambos `nil`. Não é erro — é o caso documentado em
  D2 do overview: o `MemoryStore` (P2C-01, fora desta task) decide o
  fallback (`DEFAULT_TENANT = "_default"`), o Executor não aplica default
  nenhum, só repassa `nil`.
- **`meta` com chave string vs symbol.** `task.command` é persistido como
  Hash "cru" (JSON-like); dependendo do backend de Store, `meta["tenant"]`
  pode vir como string-key e `meta[:tenant]` como symbol-key (o próprio
  `rebuild_command` já trata isso do mesmo jeito para `type`/`payload`).
  `command_tenant` testa as duas, na mesma ordem (string primeiro) que o
  resto do arquivo usa.
- **Provider `Request` recebendo tenant agora não-nil.** Antes desta task,
  `request.tenant` em `context/providers/request.rb:12` sempre estourava
  `NoMethodError` se chamado (Struct sem esse membro) — mas nada chamava,
  porque nenhum request real chegava lá com esse método ausente sendo
  testado (specs cobriam só `vars`, que também está ausente e é debt à
  parte). Depois desta task, o método existe e devolve `nil` OU o tenant —
  o provider passa a incluir a linha `tenant: <valor>` no fragmento quando
  presente. Efeito colateral esperado e aditivo, não regressão: cobrir com
  um teste de não-regressão do fragmento (linha 6 do "Testes" abaixo).
- **`ContextRequest.new(...)` sem `tenant:` em call sites que não sejam o
  `build_context_request`** (não deveria haver outros em produção, mas specs
  antigas podem instanciar `ContextRequest` diretamente): `Struct` com
  `keyword_init: true` aceita omitir qualquer membro — `tenant` vira `nil`
  automaticamente, sem `ArgumentError`. Nenhuma spec existente quebra.
- **Não reabrir o seam `vars`.** `request.vars` continua ausente do Struct
  (fora do escopo D6) — qualquer código que dependa de `vars` continua
  quebrado do jeito que já estava; esta task não muda esse estado.
- **`state.tenant` derivado de `request.tenant`, não recomputado.** Se
  algum dia `build_context_request` mudar a lógica de resolução de tenant,
  `run_pipeline` automaticamente segue o mesmo valor (Passo 4 lê do
  `request` já montado) — não há dois pontos de verdade para o mesmo turno.

## Testes

**Arquivo:** `spec/harness/executor_pipeline_spec.rb` (integração via
`run_pipeline`/`spawn`, usando o `FakeContextBuilder` de
`spec/support/fakes.rb` para capturar o `request` recebido) + opcionalmente
`spec/harness/executor_spec.rb` (unit de `command_tenant` via `send`, se for
mais simples isolar string-vs-symbol sem subir o pipeline inteiro).

| # | Cenário | Asserção |
|---|---|---|
| 1 | Command criado com `tenant: "acme"` (`Command.build(..., tenant: "acme")` ou Task com `meta: { tenant: "acme" }`) | `build_context_request` produz um `ContextRequest` com `tenant == "acme"` (capturar via `FakeContextBuilder` espião, ou chamar `executor.send(:build_context_request, ...)` diretamente) |
| 2 | Command sem tenant (`meta: {}`) | `command_tenant(task) == nil`; `ContextRequest#tenant == nil`; turno completa normalmente (sem erro) |
| 3 | `task.command["meta"]` com chave STRING `"tenant"` | `command_tenant` extrai corretamente (`meta["tenant"]` vence) |
| 4 | `task.command[:meta]` com chave SYMBOL `:tenant` (sem a string) | `command_tenant` extrai via `meta[:tenant]` (fallback) |
| 5 | Turno completo (`spawn` + `run_pipeline`) com tenant presente | `state.tenant == "acme"` no `TurnState` que chega ao `@middleware`/`persist_turn` (inspecionar via spy no middleware, como outros testes do pipeline já fazem) |
| 6 | Fragmento do provider `Request` (`context/providers/request.rb`) com tenant presente | `<request_context>` inclui a linha `tenant: acme` (não-regressão: confirma que o seam da Fase 1 passou a funcionar) |
| 7 | `ContextRequest.new(...)` sem `tenant:` (spec antiga que instancia direto) | não levanta `ArgumentError`; `.tenant == nil` |

## Definition of Done

- [ ] `ContextRequest` Struct com `:tenant`, `build_context_request` populando via `command_tenant(task)`
- [ ] `command_tenant` trata `meta` com chave string OU symbol, ausência de tenant → `nil`
- [ ] `run_pipeline` seta `state.tenant = request.tenant` (mesmo valor do `ContextRequest`, sem recomputar) logo após montar o `request`
- [ ] `TurnState#tenant` (`attr_accessor`) documentado no mesmo estilo dos demais campos internos (`capability_names`, `skip_side_effects`)
- [ ] Provider `Request` (`context/providers/request.rb`) passa a incluir `tenant:` no fragmento quando presente — coberto por teste de não-regressão
- [ ] Suíte verde sem chave de API (tudo determinístico — Command/TurnState/Struct puros)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **COORDENAÇÃO:** a task 6 (Etapa B, P2C-02) edita `configure_chat`/`create_chat`
  em `lib/harness/executor.rb` e **lê `state.tenant`** para decidir o scope
  que a tool `remember` usa no write path. Sequenciar **task 3 antes da task
  6** (já refletido no `tasks.md` da fatia: task 6 depende de 3 e 5). Se as
  duas forem trabalhadas em paralelo em branches separadas, o merge da task 6
  precisa vir DEPOIS do merge desta task — caso contrário `state.tenant`
  não existe ainda quando a task 6 tentar lê-lo.
- **NÃO reabrir o seam `vars`** (`request.vars`, chamado em
  `context/providers/request.rb:13` e `context/providers/session.rb:48`,
  igualmente ausente do Struct `ContextRequest`) — é outro pedaço do mesmo
  débito da Fase 1, fora do escopo D6 desta fatia. Só `tenant` é tocado
  aqui; `vars` fica para uma task/fatia futura que decida explicitamente de
  onde esse valor viria.
- Esta task reconcilia literalmente a frase do `00-overview.md` (D6): "o
  `Executor::ContextRequest` ganha `:tenant`, populado do Command (reconcilia
  parte do débito)" — é fechamento de débito documentado, não feature nova
  de comportamento (o único efeito observável novo é a linha `tenant:` no
  fragmento do provider `Request`, que já esperava por esse dado).
