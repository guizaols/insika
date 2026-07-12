# Task 04 (P2B): Ativar `contracts.capabilities` no PluginLoader

> **Techspec:** [P2B-01-capability-registry.md](../P2B-01-capability-registry.md) (L6, §Interfaces) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** A

## Objetivo

Fechar a costura que a Fase 1 deixou pronta (`warn_reserved` em
`plugin/loader.rb:109-113`, que hoje só avisa "reservado (Fase 2) — ignorado" e
descarta): `contracts.capabilities` do manifesto vira parsing real, e o
`StagingApi` (`RegistrationAPI`) ganha `register_capability` — entry API
simétrica a `register_tool`/`register_workflow`, mas que efetiva no
`CapabilityRegistry` (Task 1) em vez de `ToolRegistry`/`WorkflowRegistry`.
Plugins que não usam `contracts.capabilities` continuam se comportando
EXATAMENTE como hoje (bloco opcional, zero regressão).

## Dependências

| # | Task | Componente | Status |
|---|------|-----------|--------|
| 1 | `CapabilityRegistry` + `Provider` + resolução determinística | P2B-01 | ⬜ TODO |

O `CapabilityRegistry` precisa existir (`lib/harness/capability_registry.rb`,
interface `register(capability, impl_name:, kind:, plugin:, priority:,
available:)` / `deregister_plugin(plugin_id)`) antes desta task poder ser
implementada — o Loader só chama essa API, não a define.

## Contexto

- **A costura pronta:** `warn_reserved` (loader.rb:109-113) é chamada em
  `load_all` logo após o manifesto ser lido e SEMPRE avisa quando
  `contracts.capabilities` existe, independente do que o plugin faça depois —
  não há staging, não há registro, é só ruído. Esta task substitui esse warn
  por um parsing real e por uma entry API funcional.
- **RFC-0003 §5 (precedência de plugin):** os registries "de conteúdo"
  (`Registry`, usado por `tools`/`workflows`/`policies`) aplicam "primeiro
  vence" em duplicata (`Registry#register`, doc `registry.rb:20-30`). O
  `CapabilityRegistry` **não** segue essa regra — por design (P2B-01 L1/L4),
  MÚLTIPLOS plugins podem registrar providers para a MESMA capability (é assim
  que a resolução por `priority`/ambiguidade faz sentido). O Loader não impõe
  dedup nenhum: só valida a declaração no manifesto e repassa ao registry, que
  decide sozinho como acumular candidatos.
- **RFC-0004 §3 (declaração via manifesto):** a disciplina é a MESMA de
  `contracts.tools`/`contracts.workflows` (doc 06 §2-§3, já implementada em
  `register_tool`/`register_workflow`): o manifesto declara os NOMES que o
  plugin pretende expor; a entry API valida cada `register_*` contra essa
  lista — nome fora da lista é erro de configuração silenciável (warn +
  ignora), nunca uma exceção que derruba o boot (fail-closed *por plugin*, não
  por processo).

## Arquivos

| Ação | Arquivo | O quê |
|------|---------|-------|
| MODIFY | `lib/harness/plugin/loader.rb` | remove `warn_reserved`; `Discovered` ganha `capability_names`; `build_discovered` parseia `contracts.capabilities`; `RegistrationAPI` ganha `capability_names:`/`@staged_capabilities`, `register_capability`, efetivação em `commit!`; `rollback` limpa capabilities |
| MODIFY | `spec/harness/plugin/loader_spec.rb` | remove/substitui o teste de warn reservado; helper `registries` ganha a chave `capabilities:`; novos exemplos de `register_capability` (declarada/não declarada, tool:/workflow:, kind: workflow sem consumidor, rollback) |

## Passo a passo

### Passo 1 — Remover `warn_reserved`

Hoje `load_all` chama isso incondicionalmente para todo manifesto com
`contracts.capabilities`:

```ruby
# ANTES (loader.rb:49 dentro de load_all)
warn_reserved(manifest, id)

# ANTES (loader.rb:109-113)
def warn_reserved(manifest, id)
  return unless manifest.dig("contracts", "capabilities")

  warn "[plugin #{id}] contracts.capabilities é reservado (Fase 2) — ignorado"
end
```

Remova a chamada em `load_all` e o método inteiro. Não sobra nenhum warn
genérico de "reservado" — a partir de agora, capability não declarada é
tratada exatamente como tool/workflow não declarado (warn específico dentro de
`register_capability`, Passo 4), não mais um warn de descoberta do manifesto.

### Passo 2 — `Discovered` ganha `capability_names`; `build_discovered` parseia

Espelhe `tool_names`/`workflow_names` (mesmo padrão `Array(...).map(&:to_s)`):

```ruby
# ANTES
Discovered = Data.define(:id, :name, :root, :tool_names, :workflow_names,
                         :skill_dirs, :prompt_dirs, :config)
...
def build_discovered(manifest, root, config)
  Discovered.new(
    id: manifest["id"].to_s, name: manifest["name"].to_s, root: root,
    tool_names: Array(manifest.dig("contracts", "tools")).map(&:to_s),
    workflow_names: Array(manifest.dig("contracts", "workflows")).map(&:to_s),
    skill_dirs: Array(manifest["skills"]).map { |d| File.join(root, d) },
    prompt_dirs: Array(manifest["prompts"]).map { |d| File.join(root, d) },
    config: config
  )
end
```

```ruby
# DEPOIS
Discovered = Data.define(:id, :name, :root, :tool_names, :workflow_names,
                         :capability_names, :skill_dirs, :prompt_dirs, :config)
...
def build_discovered(manifest, root, config)
  Discovered.new(
    id: manifest["id"].to_s, name: manifest["name"].to_s, root: root,
    tool_names: Array(manifest.dig("contracts", "tools")).map(&:to_s),
    workflow_names: Array(manifest.dig("contracts", "workflows")).map(&:to_s),
    capability_names: Array(manifest.dig("contracts", "capabilities")).map(&:to_s),
    skill_dirs: Array(manifest["skills"]).map { |d| File.join(root, d) },
    prompt_dirs: Array(manifest["prompts"]).map { |d| File.join(root, d) },
    config: config
  )
end
```

Aproveite para atualizar `SUPPORTED_CONTRACTS = %w[tools workflows].freeze`
(loader.rb:19) para `%w[tools workflows capabilities].freeze` — a constante
não é lida em nenhum outro lugar do código hoje (dead-ish, é documentação de
quais chaves de `contracts.*` o Loader entende), mas deixá-la desatualizada
depois desta task seria enganoso para quem ler o arquivo.

### Passo 3 — `RegistrationAPI` recebe `capability_names:` e o staging

`load_entry` monta o `RegistrationAPI` com os nomes descobertos — acrescente
`capability_names:` ao construtor, igual `tool_names:`/`workflow_names:`:

```ruby
# ANTES (load_entry)
api = RegistrationAPI.new(
  registries: @registries, plugin_id: discovered.id,
  tool_names: discovered.tool_names, workflow_names: discovered.workflow_names,
  tool_metadata: manifest["tool_metadata"] || {}, config: discovered.config
)
```

```ruby
# DEPOIS
api = RegistrationAPI.new(
  registries: @registries, plugin_id: discovered.id,
  tool_names: discovered.tool_names, workflow_names: discovered.workflow_names,
  capability_names: discovered.capability_names,
  tool_metadata: manifest["tool_metadata"] || {}, config: discovered.config
)
```

No `initialize` do `RegistrationAPI`, guarde `@capability_names` e some
`@staged_capabilities = []` ao lado de `@staged_middleware`/`@staged_providers`/
`@staged_hooks` (mesma disciplina de staging — nada é efetivado antes do
`commit!`, L3 do doc 06: um `register(api)` que levanta no meio não deve deixar
capability parcial registrada).

### Passo 4 — `register_capability`: validação + staging

Espelhe `register_tool` (padrão "não declarada → warn + ignora"), acrescentando
a validação de exclusividade `tool:`/`workflow:` e o warn L5 para
`kind: :workflow`:

```ruby
# Padrão de referência (codebase) — register_tool atual, loader.rb:192-202
def register_tool(name, klass = nil, &block)
  name = name.to_s
  unless @tool_names.include?(name)
    warn "[plugin #{@plugin_id}] tool '#{name}' não declarada em contracts.tools — ignorada"
    return
  end
  meta = @tool_metadata[name] || {}
  @registries[:tools].register(name, klass, plugin: @plugin_id,
                                            optional: !!meta["optional"],
                                            side_effect: !!meta["side_effect"], &block)
end
```

```ruby
# NOVO — register_capability, mesmo espírito
def register_capability(name, tool: nil, workflow: nil, priority: nil, available: nil)
  name = name.to_s
  unless @capability_names.include?(name)
    warn "[plugin #{@plugin_id}] capability '#{name}' não declarada em contracts.capabilities — ignorada"
    return
  end

  if tool && workflow
    warn "[plugin #{@plugin_id}] capability '#{name}': informe apenas tool: OU workflow:, não os dois — ignorada"
    return
  end

  impl_name, kind =
    if tool then [tool.to_s, :tool]
    elsif workflow then [workflow.to_s, :workflow]
    end

  if impl_name.nil?
    warn "[plugin #{@plugin_id}] capability '#{name}': informe tool: ou workflow: — ignorada"
    return
  end

  if kind == :workflow
    warn "[plugin #{@plugin_id}] capability '#{name}' (kind: workflow) registrada sem consumidor " \
         "nesta fatia — exposição ao agente é follow-up (P2B-01 L5)"
  end

  @staged_capabilities << { capability: name, impl_name: impl_name, kind: kind,
                            priority: priority, available: available }
end
```

Note que o warn de `kind: :workflow` NÃO é "ignora" — a capability continua
staged e vai para o `commit!` normalmente (o registry guarda e resolve
`:workflow` igual a `:tool`, só a exposição ao loop do agente é que fica de
fora nesta fatia, per L5).

### Passo 5 — `commit!` efetiva no `CapabilityRegistry`

```ruby
# ANTES
def commit!
  @staged_middleware.each { |m| @registries[:middleware] << m }
  @staged_providers.each { |p| @registries[:context_providers] << p }
  @staged_hooks.each { |pair, before, after| @registries[:hooks].register(pair, before: before, after: after) }
end
```

```ruby
# DEPOIS
def commit!
  @staged_middleware.each { |m| @registries[:middleware] << m }
  @staged_providers.each { |p| @registries[:context_providers] << p }
  @staged_hooks.each { |pair, before, after| @registries[:hooks].register(pair, before: before, after: after) }
  @staged_capabilities.each do |c|
    @registries[:capabilities].register(c[:capability], impl_name: c[:impl_name], kind: c[:kind],
                                        plugin: @plugin_id, priority: c[:priority], available: c[:available])
  end
end
```

O Loader não resolve `priority: nil`/`available: nil` para um default aqui —
isso é responsabilidade do `CapabilityRegistry#register` (Task 1, já descrito
no `Provider` Data.define de P2B-01 §Interfaces). O Loader só repassa o que o
plugin informou.

### Passo 6 — `rollback` limpa capabilities

```ruby
# ANTES
def rollback(id)
  %i[tools workflows policies].each { |kind| @registries[kind]&.deregister_plugin(id) }
end
```

```ruby
# DEPOIS
def rollback(id)
  %i[tools workflows policies capabilities].each { |kind| @registries[kind]&.deregister_plugin(id) }
end
```

O `&.` já protege chamadores que ainda não passam `registries[:capabilities]`
(nenhuma exceção, só no-op) — mas o objetivo desta task é que o composition
root SEMPRE passe a chave (é o wiring da Task 11 que vai atualizar
`config/wiring.rb`; aqui só garantimos que o Loader aceita e usa a chave
quando presente).

## Edge cases

- **Capability não declarada no manifesto:** `register_capability` chamado
  para um nome fora de `contracts.capabilities` → warn específico, staging
  descartado, nada chega no `CapabilityRegistry`.
- **`tool:` e `workflow:` ambos informados:** warn + ignora (erro de
  configuração do plugin — a API é `Data.define`-like, exatamente um `kind`).
- **Nenhum dos dois informado:** warn + ignora (mesma mensagem final "informe
  tool: ou workflow:").
- **Plugin sem o bloco `contracts.capabilities`:** `capability_names` fica
  `[]`; se o plugin nunca chama `register_capability`, comportamento IDÊNTICO
  à Fase 1 (nenhum warn, nenhuma capability registrada, nenhuma mudança em
  `tools`/`workflows`/skills/prompts).
- **`kind: :workflow` sem consumidor:** registra normalmente (staged +
  efetivado no commit!), mas emite warn não-bloqueante (L5) — a diferença para
  os outros warns desta task é que este NÃO descarta o staging.
- **Rollback:** entry registra 1+ capability e depois levanta no meio do
  `register(api)` → `load_entry` cai no `rescue`, chama `rollback(id)`, que
  agora inclui `capabilities` → nada fica staged (nunca chegou a `commit!`) E
  nada residual no `CapabilityRegistry` mesmo que um commit parcial de outro
  plugin já tivesse rodado antes (idempotente por `plugin_id`).
- **Duplicata entre plugins na MESMA capability:** fora do escopo desta task
  validar/alertar — o Loader não tem opinião sobre quantos providers uma
  capability tem; isso é resolvido em `CapabilityRegistry#resolve` (Task 1/5).
  Não implemente dedup "primeiro vence" aqui — seria uma regressão em relação
  ao design de P2B-01 L1/L4.

## Testes

**Arquivo:** `spec/harness/plugin/loader_spec.rb`

| Cenário | Verifica |
|---------|----------|
| Helper `registries` ganha `capabilities:` | novo `let(:capabilities) { Harness::CapabilityRegistry.new }`; todos os exemplos existentes continuam verdes sem alteração de asserts |
| Substituir "contracts.capabilities: warn reservado" | o teste antigo (linha ~271) que esperava `/capabilities é reservado/` deixa de fazer sentido — remova/reescreva para `contracts: { tools: [t], capabilities: [foo] }` SEM `register_capability` no entry → plugin carrega normalmente, SEM warn nenhum |
| `register_capability` com capability declarada + `tool:` | `capabilities.providers(:foo)` (ou nome equivalente da API do registry) traz 1 `Provider` com `kind: :tool`, `impl_name`, `plugin: "id-do-plugin"` |
| `register_capability` com capability declarada + `workflow:` | provider com `kind: :workflow`; **e** warn de "sem consumidor" no stderr |
| `register_capability` com nome NÃO declarado em `contracts.capabilities` | warn "não declarada em contracts.capabilities"; nada registrado no `CapabilityRegistry` |
| `register_capability` com `tool:` e `workflow:` juntos | warn "informe apenas tool: OU workflow:"; nada registrado |
| `register_capability` sem `tool:` nem `workflow:` | warn "informe tool: ou workflow:"; nada registrado |
| Plugin sem `contracts.capabilities` | nenhuma mudança de comportamento (sem warn, `capability_names` vazio, demais registries intocados) — reusa um teste já existente como baseline |
| Rollback com capability | entry registra `t1` + 1 capability e levanta no meio → `tools.names` reverte (já coberto) **e** `capabilities.providers(...)` fica vazio após o rollback |
| `Discovered#capability_names` | manifesto com `contracts: { capabilities: [a, b] }` → `result[:plugins].first` (ou acesso equivalente) expõe `["a", "b"]` |

## Definition of Done

- [ ] `warn_reserved` removido (chamada e método)
- [ ] `Discovered` com `capability_names`; `build_discovered` parseando `contracts.capabilities`
- [ ] `RegistrationAPI#register_capability` implementado (validação de declaração + exclusividade tool:/workflow: + warn L5 para workflow)
- [ ] `commit!` efetivando no `CapabilityRegistry`
- [ ] `rollback` limpando capabilities
- [ ] Plugins sem `contracts.capabilities` comprovadamente inalterados (teste dedicado)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- Esta task NÃO mexe em `config/wiring.rb` — o composition root passar
  `capabilities: CAPABILITY_REGISTRY` de verdade no `registries:` do Loader de
  produção é escopo da Task 11 (wiring). Aqui só garantimos que o Loader e o
  `RegistrationAPI` sabem usar a chave quando ela existe.
- Esta task também NÃO expõe capability nenhuma ao agente/loop de tools —
  isso é Executor (Task 5). O `CapabilityRegistry` só acumula providers; quem
  resolve e decide o que o modelo vê é a Task 5.
- Dependência dura de Task 1: sem `CapabilityRegistry#register`/
  `#deregister_plugin` existindo, esta task não compila os testes novos (os
  testes já existentes do Loader continuam passando isoladamente, mas a task
  como um todo só fecha com Task 1 mergeada antes ou em conjunto).
