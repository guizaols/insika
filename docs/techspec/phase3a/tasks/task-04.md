# Task 04 (P3A): `A2A::AgentCard` (descoberta)

> **Techspec:** [P3A-02-agent-card-and-wiring.md](../P3A-02-agent-card-and-wiring.md) (§AgentCard, D5, L1-L2) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo

Criar `Harness::Server::A2A::AgentCard`, o módulo puro que monta o documento de
descoberta A2A (`GET /.well-known/agent-card.json`, task 6) a partir de um
`AgentProfile` + skills efetivas do `SkillCatalog`. Um único método
(`.build`), sem I/O, sem HTTP, sem tocar `command_bus`/stores — só monta um
`Hash` JSON-serializável (RFC-0002 §1: A2A é transporte; aqui nem transporte é,
é dado estático). É a peça mais estreita da Etapa A e não depende de nenhuma
das outras três (Protocol/Errors, Message, TaskProjection) — pode ser feita em
paralelo.

## Dependências

Nenhuma — pode começar já.

## Contexto

A fatia P3A expõe **um agente por deployment** via `HARNESS_A2A_AGENT` (D5 do
P3A-02): o wiring (task 7) resolve essa env para um `AgentProfile` já
carregado em `PROFILES` e injeta no `Server::A2A::App` (task 5) como
`config[:a2a_agent]`. O `AgentCard` é o documento que um cliente A2A busca
ANTES de falar com o agente — descreve nome, descrição, endpoint e
capabilities. Por isso `AgentCard.build` recebe o `agent` (um `AgentProfile`,
`lib/harness/agent_profile.rb`) já resolvido; não há lógica de multi-agente
nem registry aqui (isso é "Fora de escopo" explícito no P3A-02, evolução
futura).

Duas decisões do techspec que a implementação PRECISA respeitar ao pé da
letra:

- **L1 — um agente (D5):** `skills:` não é `agent.skills` (a allowlist bruta
  do profile, que pode ser `nil`/`[]`/lista de nomes) — é o resultado JÁ
  filtrado de `skill_catalog.effective(agent.skills)` (`lib/harness/skill_catalog.rb:34`),
  que devolve `[Skill]` (`Data.define(:name, :description, :path, :body)`,
  nível 1: só metadados). Quem chama `AgentCard.build` (a task 5, no
  `Server::A2A::App#agent_card`) é responsável por já ter resolvido essa
  lista via `effective` — `AgentCard.build` em si só faz `.map` no que
  recebeu; não conhece `SkillCatalog` nem `AgentProfile#skills` por dentro.
  Isso mantém `AgentCard` puro e testável com dublês simples (não precisa de
  um `SkillCatalog` de verdade nos testes).
- **L2 — capabilities honestas:** `capabilities` é hardcoded
  `{ streaming: false, pushNotifications: false, stateTransitionHistory: false }`
  — NÃO é um argumento configurável de `.build`. Streaming/push/histórico de
  estado são evolução futura (Fora de escopo do P3A inteiro, per 00-overview e
  P3A-02); declarar `true` aqui enganaria um cliente A2A a tentar
  `message/stream` contra um adapter que não implementa isso. Não adicionar
  parâmetro para "ligar" essas capabilities nesta task.

A assinatura completa, já fixada no techspec (`P3A-02-agent-card-and-wiring.md:21`):

```ruby
def self.build(agent:, base_url:, skills: [], version: "0.1.0")
```

`base_url` chega pronto (quem monta é o wiring/task 7, a partir de
`CONFIG[:public_url]` ou de um default derivado do bind) — `AgentCard.build`
só concatena `"#{base_url}/a2a"`, sem normalizar barra final nem validar
formato de URL (não é essa task).

## Arquivos

| Ação | Arquivo | O quê |
|---|---|---|
| CREATE | `server/a2a/agent_card.rb` | `Harness::Server::A2A::AgentCard.build` |
| CREATE | `spec/harness/server/a2a/agent_card_spec.rb` | contrato do `.build` |

Diretório novo: `server/a2a/` (e `spec/harness/server/a2a/` no lado dos
testes) — ainda não existe no repo (primeira task da Etapa A a criar
arquivo). Não é necessário criar `.rspec`/config adicional: o glob padrão do
RSpec já cobre subdiretórios de `spec/`, e este arquivo não é requerido por
`lib/harness.rb` (é código de `server/`, carregado por `server/app.rb`/`config.ru`
— o `require_relative "server/a2a/agent_card"` em `server/app.rb` é escopo da
task 6, que compõe as rotas; aqui a task só cria o arquivo e o testa
isoladamente via `require_relative` direto no spec).

## Passo a passo

### Passo 1 — criar `server/a2a/agent_card.rb`

Módulo puro, um único method object (`self.build`), seguindo o texto do
techspec quase ao pé da letra — a única adição sobre o texto do P3A-02 é o
comentário de topo (padrão do resto do código: cada arquivo novo em `server/`
explica seu porquê num comentário, ver `server/admin_auth.rb:6-9` como
referência de tom).

**Padrão de referência (codebase) — `AgentProfile` (`lib/harness/agent_profile.rb:13-32`):**
```ruby
AgentProfile = Data.define(
  :id, :model, :provider,
  :base_prompt, :prompt_files,
  ...
)
```
`agent.id` e `agent.base_prompt` são os dois únicos campos do `AgentProfile`
que o `AgentCard` lê — `id` vira `name` do card, `base_prompt` (truncado)
vira `description`. Nenhum outro campo do profile (`model`, `tools_allow`,
`capabilities`, etc.) é exposto no card nesta fatia.

**Padrão de referência (codebase) — `SkillCatalog::Skill` (`lib/harness/skill_catalog.rb:15`):**
```ruby
Skill = Data.define(:name, :description, :path, :body)
```
Cada elemento de `skills:` responde a `.name`/`.description` — é só isso que
o `.map` do `AgentCard` usa (`path`/`body` — nível 2, corpo da skill — não
entram no card, que é só nível 1/metadados).

Implementação (transcrição fiel do bloco do techspec, `P3A-02-agent-card-and-wiring.md:16-33`):

```ruby
# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Documento de descoberta A2A (GET /.well-known/agent-card.json, task 6).
      # Puro: nenhum I/O, nenhum acesso a command_bus/stores — só monta o Hash
      # a partir de um AgentProfile já resolvido (D5: um agente por
      # deployment) e das skills já filtradas pelo SkillCatalog#effective
      # (nível 1: name+description, sem corpo).
      module AgentCard
        module_function

        # agent: AgentProfile (config[:a2a_agent], já resolvido pelo wiring).
        # base_url: origem pública do servidor (ex. HARNESS_PUBLIC_URL).
        # skills: [SkillCatalog::Skill] já filtradas por
        #         skill_catalog.effective(agent.skills) — quem chama resolve
        #         a allowlist, este módulo só mapeia.
        # -> Hash JSON-serializável (AgentCard, wire A2A).
        def build(agent:, base_url:, skills: [], version: "0.1.0")
          {
            name: agent.id,
            description: agent.base_prompt.to_s[0, 280],
            url: "#{base_url}/a2a",
            version: version,
            protocolVersion: "0.2.5", # A2A wire (confirmar, ver 00-overview §aberto)
            capabilities: {
              streaming: false, pushNotifications: false, stateTransitionHistory: false
            },
            defaultInputModes: ["text/plain"],
            defaultOutputModes: ["text/plain"],
            skills: skills.map { |s| { id: s.name, name: s.name, description: s.description, tags: [] } }
          }
        end
      end
    end
  end
end
```

Pontos de atenção na transcrição:
- `agent.base_prompt.to_s[0, 280]` — o `.to_s` cobre o edge case de
  `base_prompt` vir `nil` (não deveria, já que `AgentProfile.build` tem
  default `base_prompt: ""`, mas um `AgentProfile.new` direto — via
  `Data.define` — não impõe esse default; o módulo não deve estourar
  `NoMethodError` em `nil[0,280]`).
- `id:`/`name:` de cada skill usam o MESMO valor (`s.name`) — não há um id
  técnico separado do nome amigável nesta fatia (o AgentCard A2A pede um
  `id` por skill; aqui reaproveita-se o nome, que já é único por
  `SkillCatalog#load_all` — `found[skill.name] ||= skill`).
- `tags: []` sempre vazio — o `SkillCatalog::Skill` não tem conceito de tags
  hoje; não inventar um campo novo no catálogo para preencher isso.
- `module_function` (mesmo padrão de `AdminAuth`, `server/admin_auth.rb:15`)
  em vez de `class << self` ou `def self.build` solto — consistência com o
  outro módulo puro já existente em `server/`.

## Edge cases

- **`skills: []` (default ou agente sem skills)** → `skills.map` sobre array
  vazio → `[]` no card. Não é `nil`; o card sempre tem a chave `skills`
  presente com array (vazio ou não).
- **`agent.base_prompt` vazio (`""`)** → `description: ""` — não substituir
  por texto default nem omitir a chave.
- **`agent.base_prompt` mais longo que 280 chars** → truncado exatamente em
  280 (`String#[0, 280]`, sem reticências/marcador de corte — truncamento
  cru, sem tentar cortar em espaço de palavra).
- **`base_url` com barra final (`"http://x/"`)** → o módulo NÃO normaliza;
  produz `"http://x//a2a"` literalmente. Fora de escopo desta task consertar
  — é responsabilidade de quem monta `base_url` (wiring, task 7) entregar sem
  barra final. Documentar a armadilha, não "corrigir" escondido.
- **`version:` omitido** → default `"0.1.0"` (versão do PRÓPRIO agente/card,
  não confundir com `protocolVersion`, que é da versão do WIRE A2A e é
  hardcoded `"0.2.5"`, não parametrizável).
- **`agent` sem os métodos `id`/`base_prompt`** (dublê de teste incompleto) →
  `NoMethodError` explícito na hora — não há guard silencioso; é assim que o
  teste percebe um dublê malformado.

## Testes

**Arquivo:** `spec/harness/server/a2a/agent_card_spec.rb`

Dublês simples (não precisa de `AgentProfile.build` nem `SkillCatalog` reais —
qualquer objeto/`Struct`/`OpenStruct` que responda a `id`/`base_prompt` serve
para `agent`; qualquer objeto que responda a `name`/`description` serve para
cada elemento de `skills`), seguindo o espírito do `FakeBrowseTool` da
task-02 da Fase 2B (`spec/harness/tool_envelope_approval_spec.rb`).

| # | Cenário | Asserção |
|---|---|---|
| 1 | `agent` com `id: "chef"`, `base_prompt: "ajuda com receitas"`, `base_url: "http://x"`, sem skills | `name == "chef"`; `description == "ajuda com receitas"`; `url == "http://x/a2a"` |
| 2 | mesmo setup | `protocolVersion == "0.2.5"`; `version == "0.1.0"` (default) |
| 3 | mesmo setup | `capabilities == { streaming: false, pushNotifications: false, stateTransitionHistory: false }` (as 3 chaves, todas `false`) |
| 4 | mesmo setup | `defaultInputModes == ["text/plain"]`; `defaultOutputModes == ["text/plain"]` |
| 5 | `skills: []` (default, não passado) | `skills == []` no resultado |
| 6 | `skills: [dublê(name: "receitas", description: "busca receitas")]` | `skills == [{ id: "receitas", name: "receitas", description: "busca receitas", tags: [] }]` |
| 7 | `skills` com 2+ elementos | cada um mapeado na mesma ordem de entrada |
| 8 | `base_prompt` com 300 caracteres | `description.length == 280`; é o prefixo exato dos 280 primeiros chars |
| 9 | `base_prompt: nil` | `description == ""` (não estoura `NoMethodError`) |
| 10 | `version: "9.9.9"` explícito | `version == "9.9.9"` (sobrescreve o default) |
| 11 | resultado inteiro (integração dos campos) | `.build(...)` responde a `to_json` sem erro (Hash 100% serializável — só símbolos/strings/booleans/arrays/hashes, nada de `Data`/objeto custom vazando) |

## Definition of Done

- [ ] `Harness::Server::A2A::AgentCard.build` criado em `server/a2a/agent_card.rb`,
      assinatura `(agent:, base_url:, skills: [], version: "0.1.0")`, puro
      (sem I/O, sem `command_bus`/stores)
- [ ] `capabilities` hardcoded `streaming:false`/`pushNotifications:false`/
      `stateTransitionHistory:false` — não configurável por parâmetro
- [ ] `skills` mapeadas para `{id,name,description,tags:[]}`, preservando ordem
- [ ] `spec/harness/server/a2a/agent_card_spec.rb` cobrindo a tabela de testes
      acima
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Versão do wire A2A a confirmar** (00-overview §"Questão em aberto" do
  P3A): `protocolVersion: "0.2.5"` e o formato do `agent-card.json` seguem o
  subconjunto ~v0.2/v0.3 do spec A2A fixado pelo techspec; confirmar contra a
  versão-alvo antes de anunciar compatibilidade pública. Não é bloqueio para
  esta task — só não "resolver" a incerteza inventando uma versão diferente
  da que está escrita no P3A-02.
- **`securitySchemes`/auth = evolução** (Fora de escopo do P3A inteiro,
  P3A-02 "Fora de escopo"): o card desta fatia não declara nenhum esquema de
  autenticação — um cliente A2A real esperaria isso para saber como se
  autenticar contra o endpoint, mas a fatia A2A inbound desta fase é
  server-to-server sem auth própria (reusa o que já existe no `Server::App`).
  Não adicionar a chave `securitySchemes` "para não ficar faltando" — é
  deliberado.
- Esta task NÃO cria `server/a2a/app.rb` (task 5, que compõe `AgentCard` +
  `Protocol`/`Message`/`TaskProjection`), NÃO mexe em `server/app.rb` (task 6,
  rotas) e NÃO mexe em `config/wiring.rb` (task 7, `HARNESS_A2A_AGENT`) —
  escopo deliberadamente estreito, mesmo espírito de isolamento das outras
  três tasks paralelas da Etapa A (1, 2, 3).
