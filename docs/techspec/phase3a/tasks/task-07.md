# Task 07 (P3A): Wiring do `A2A_APP` (opt-in)

> **Techspec:** [P3A-02-agent-card-and-wiring.md](../P3A-02-agent-card-and-wiring.md) (§Wiring, L7) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** B

## Objetivo

Ligar o `Server::A2A::App` (task 5) ao composition root (`config/wiring.rb`,
doc 07 §8/RFC-0001 §4): construir a constante `A2A_APP` de forma **opt-in**
por variável de ambiente (`HARNESS_A2A_AGENT`) e injetá-la no `Server::App.new`
já existente (`a2a:`, kwarg que a task 6 adiciona com default `nil`). Task
100% de fiação — nenhuma lógica nova. Sem a env (ou com um agente que não
existe em `PROFILES`), `A2A_APP` fica `nil` e o servidor não expõe nenhuma
rota A2A — paridade com deployments que não usam a fatia (L6/L7 do
P3A-02).

## Dependências

| Task | O que fornece |
|------|----------------|
| Task 06 | `Server::App` já aceita `a2a:` no construtor (default `nil` → rotas A2A respondem 404) e faz `require_relative` de `server/a2a/*` (`App`, `AgentCard`, e transitivamente `Protocol`/`Errors`/`Message`/`TaskProjection` das tasks 1-4) |

## Contexto

O composition root é único (`config/wiring.rb` — comentário de topo do
arquivo, linhas 1-15): é o único lugar onde dependências são construídas e
injetadas; constantes globais (`BUS`, `PROFILES`, `CATALOG`, ...) são atalho
de leitura, não fonte de verdade para teste (as classes aceitam injeção
direta). Esta task não inventa wiring novo: segue o padrão já estabelecido
para `APP = Harness::Server::App.new(...)` (linhas ~148-156) — constrói a
constante nova ANTES do `APP` (porque `APP` passa a depender dela) e adiciona
UM kwarg a mais na chamada existente.

**Opt-in por config (D6 do overview da fatia, L7 do P3A-02):** o A2A é "um
agente por deployment" — `HARNESS_A2A_AGENT` aponta o `id` do perfil exposto.
Hoje, na Fase 1/2 base, `PROFILES = {}.freeze` (linha 99 do wiring atual) — ou
seja, **mesmo que alguém defina `HARNESS_A2A_AGENT` no ambiente de
desenvolvimento deste repo, `PROFILES[a2a_agent]` será sempre `nil`** e
`A2A_APP` continuará `nil`. Isso é o comportamento CORRETO e esperado: esta
task deixa o fio pronto e documentado, mas só um deployment concreto (que
registra perfis reais em `PROFILES`, débito da task 26 — mesma observação já
feita pela task 11 de P2B sobre o `PluginLoader`) ou o wiring de teste do
smoke (task 8) é que populam `PROFILES` e ativam o A2A de fato. Não é bug
desta task nem motivo para inventar um perfil fake aqui.

`base_url`: reaproveita `CONFIG[:public_url]` se existir (chave nova,
opcional — `CONFIG` hoje não a define; `ENV["HARNESS_PUBLIC_URL"]` é a forma
natural de setá-la, mas fica fora do escopo mínimo desta task exigir isso: um
fallback derivado de `CONFIG[:port]` cobre o caso ausente).

## Arquivos

| Arquivo | Ação |
|---------|------|
| `config/wiring.rb` | MODIFY — constrói `A2A_APP` (bloco `if`/`nil` opt-in) logo antes do `APP = Harness::Server::App.new(...)`; adiciona `a2a: A2A_APP` à chamada |
| `spec/harness/wiring_load_spec.rb` | MODIFY — novos exemplos: `A2A_APP` é `nil` por default (PROFILES vazio); `Server::App`/`APP` constrói normalmente com `a2a: nil` |

## Passo a passo

### Passo 1 — Construir `A2A_APP` no composition root

Inserir o bloco imediatamente ANTES da construção do `CONFIG`/`APP` (mesma
seção "Transporte (task 24)"), depois de `BUS`/`PROFILES`/`CATALOG` já
existirem (todos são dependências do construtor do `A2A::App`).

**Padrão de referência (codebase) — bloco atual em `config/wiring.rb`
(linhas ~139-156):**
```ruby
# --- Transporte (task 24) -------------------------------------------------
CONFIG = {
  bind: ENV.fetch("HARNESS_BIND", "http://0.0.0.0"),
  port: Integer(ENV.fetch("HARNESS_PORT", "9292")),
  admin_token: ENV["HARNESS_ADMIN_TOKEN"], # fail-closed: sem token -> /admin 503
  # CORS estrito: strip/reject evita footgun de "a.com, b.com" virar " b.com"
  allowed_origins: ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
}.freeze

APP = Harness::Server::App.new(
  command_bus: BUS, event_stream: EVENT_STREAM,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  checkpoint_store: CHECKPOINT_STORE, # leitura p/ /admin/tasks/:id
  pending_action_store: PENDING_ACTION_STORE, # aprovações no /admin + read
  catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
  registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
  config: CONFIG
)
```

**Depois (bloco novo entre `CONFIG` e `APP`, e `a2a: A2A_APP` na chamada):**
```ruby
# --- Transporte (task 24) -------------------------------------------------
CONFIG = {
  bind: ENV.fetch("HARNESS_BIND", "http://0.0.0.0"),
  port: Integer(ENV.fetch("HARNESS_PORT", "9292")),
  admin_token: ENV["HARNESS_ADMIN_TOKEN"], # fail-closed: sem token -> /admin 503
  # CORS estrito: strip/reject evita footgun de "a.com, b.com" virar " b.com"
  allowed_origins: ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
}.freeze

# --- A2A edge (P3A, RFC-0002 §1) — inbound federation (opt-in) ------------
# Um agente por deployment (D6 do overview da fatia): HARNESS_A2A_AGENT
# aponta o id do perfil exposto via A2A. PROFILES é {} na base do wiring
# (linha ~99) -> A2A_APP é SEMPRE nil aqui, mesmo com a env setada; só um
# deployment concreto (ou o wiring de teste do smoke, task 8) que registra
# perfis reais em PROFILES ativa o A2A de fato (débito task 26, mesmo padrão
# já documentado pela task 11 de P2B para o PluginLoader). Sem a env (ou com
# um agente inexistente em PROFILES) -> nil -> Server::App não expõe rotas
# A2A (paridade, L6/L7 do P3A-02).
A2A_APP =
  if (a2a_agent = ENV["HARNESS_A2A_AGENT"]) && PROFILES[a2a_agent]
    Harness::Server::A2A::App.new(
      command_bus: BUS, task_store: TASK_STORE, session_store: SESSION_STORE,
      profiles: PROFILES, skill_catalog: CATALOG,
      config: { a2a_agent: a2a_agent,
                base_url: CONFIG[:public_url] || "http://localhost:#{CONFIG[:port]}" }
    )
  end

APP = Harness::Server::App.new(
  command_bus: BUS, event_stream: EVENT_STREAM,
  session_store: SESSION_STORE, task_store: TASK_STORE,
  checkpoint_store: CHECKPOINT_STORE, # leitura p/ /admin/tasks/:id
  pending_action_store: PENDING_ACTION_STORE, # aprovações no /admin + read
  catalogs: { skills: CATALOG, prompts: PROMPT_CATALOG },
  registries: { tools: REGISTRY, workflows: WORKFLOW_REGISTRY, policies: POLICY_REGISTRY },
  config: CONFIG,
  a2a: A2A_APP
)
```

> **Cuidado de ordem:** `A2A_APP` referencia `CONFIG[:port]`, então o bloco
> entra DEPOIS de `CONFIG` ser construído (não antes) — `A2A_APP` sobe para
> antes do `APP`, mas depois do `CONFIG`. Reordenar ao contrário quebra por
> `NameError` (mesma classe de edge case já registrada na task 11 de P2B para
> `TOOL_CATALOG`/`REGISTRY`).

### Passo 2 — Confirmar que os `require`s de `server/a2a/*` já resolvem `Harness::Server::A2A::App`

Esta task NÃO adiciona `require_relative` novo em `config/wiring.rb` — o
P3A-02 (§Wiring, nota da L7) atribui isso à task 6, via
`server/app.rb` (que já é `require_relative`d no topo do próprio
`config/wiring.rb`, linha 18). Validar (leitura, não edição) que, depois da
task 6 mesclada, `Harness::Server::A2A::App` já está definida no momento em
que `config/wiring.rb` roda o `if` do Passo 1 — se não estiver, é sinal de
que a task 6 não fechou o require corretamente (bloqueia esta task, sinalizar
no code review em vez de adicionar um require solto aqui, que duplicaria a
responsabilidade).

## Edge cases

- **Sem `HARNESS_A2A_AGENT` no ambiente:** `ENV["HARNESS_A2A_AGENT"]` é `nil`
  → o `if` curto-circuita → `A2A_APP = nil` → `Server::App.new(..., a2a:
  nil)` → rotas A2A respondem 404 (comportamento do `Server::App` da task 6).
- **`HARNESS_A2A_AGENT` setado para um agente inexistente em `PROFILES`:**
  `PROFILES[a2a_agent]` é `nil` → mesmo resultado acima (`A2A_APP = nil`) —
  não levanta erro, não loga; é o comportamento silencioso esperado (paridade
  por omissão, mesmo padrão do `BACKEND`/`HARNESS_DB` ausente).
- **`HARNESS_A2A_AGENT` setado E `PROFILES` vazio (caso real da base deste
  wiring):** mesmo resultado — `A2A_APP = nil` sempre, na Fase 3-A base, até
  um deployment concreto popular `PROFILES` (documentado no `## Contexto`
  acima; não é bug desta task).
- **`base_url` sem `CONFIG[:public_url]`:** fallback
  `"http://localhost:#{CONFIG[:port]}"` — string sempre válida, sem
  levantar exceção; não é o `base_url` real de produção (isso é
  responsabilidade do deployment setar `HARNESS_PUBLIC_URL`/`public_url`),
  mas o wiring não quebra por omissão.
- **Ordem de construção:** `A2A_APP` depende de `BUS`, `TASK_STORE`,
  `SESSION_STORE`, `PROFILES`, `CATALOG` (todas já construídas bem antes,
  seção inicial do arquivo) e de `CONFIG` (mesma seção "Transporte") — não
  depende de nada que só exista depois do `APP`. Não há dependência cíclica.

## Testes

**Arquivo:** `spec/harness/wiring_load_spec.rb`

| Cenário | Verificação |
|---|---|
| Carga do composition root com `PROFILES` vazio (base, sem mexer em ENV) | `Harness::Wiring::A2A_APP` é `nil` |
| `Server::App`/`APP` construído com `a2a: A2A_APP` | `described_class::APP` é `Harness::Server::App` (não levanta `ArgumentError` de kwarg desconhecida/ausente — cobre o kwarg novo da task 6) |

```ruby
# frozen_string_literal: true

require "spec_helper"
require_relative "../../config/wiring" # composition root real (constrói o grafo eager)

RSpec.describe Harness::Wiring do
  # ... exemplos já existentes (CAPABILITY_REGISTRY/TOOL_CATALOG/EXECUTOR/MEMORY_STORE) ...

  it "A2A_APP é nil por default (PROFILES vazio na base do wiring)" do
    expect(described_class::A2A_APP).to be_nil
  end

  it "Server::App (APP) constrói com a2a: nil sem levantar ArgumentError" do
    expect(described_class::APP).to be_a(Harness::Server::App)
  end
end
```

> Não é preciso (nem dá, sem popular `PROFILES`) testar aqui o caminho
> "`A2A_APP` não-nil" — isso é responsabilidade do smoke da task 8, que monta
> seu próprio wiring de teste com um perfil real em `PROFILES` e
> `HARNESS_A2A_AGENT` apontando para ele.

## Definition of Done

- [ ] `A2A_APP` construído em `config/wiring.rb`, entre `CONFIG` e `APP`, seguindo o padrão opt-in (`if (a2a_agent = ENV[...]) && PROFILES[a2a_agent]` → `Harness::Server::A2A::App.new(...)`; senão `nil`)
- [ ] `APP = Harness::Server::App.new(...)` recebe `a2a: A2A_APP`
- [ ] Nenhum `require_relative` novo adicionado (require de `server/a2a/*` é responsabilidade da task 6, via `server/app.rb`)
- [ ] `spec/harness/wiring_load_spec.rb` estendido com os 2 exemplos novos (`A2A_APP` nil; `APP` constrói com `a2a: nil`)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- `PROFILES = {}.freeze` na base da Fase 1/2 (débito explícito da task 26)
  significa que `A2A_APP` é `nil` por default em QUALQUER ambiente que rode
  este `config/wiring.rb` sem modificação — isso é intencional e documentado
  no `## Contexto`, não uma lacuna desta task. A ativação real do A2A exige
  um deployment concreto que registre `PROFILES` (ou o wiring de teste do
  smoke, task 8).
- Esta task é 100% wiring — nenhuma classe nova, nenhum método novo. Toda a
  lógica do A2A (`Protocol`, `Message`, `TaskProjection`, `AgentCard`,
  `Server::A2A::App#rpc`/`#agent_card`) já foi entregue pelas tasks 1-5;
  aqui só se liga o fio final ao composition root, no mesmo espírito da task
  11 de P2B ("100% de fiação — nenhuma lógica nova").
