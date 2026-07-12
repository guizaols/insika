# Task 02 (P2C): `AgentProfile.memory` (opt-in)

> **Techspec:** [P2C-01-memory-store-and-read.md](../P2C-01-memory-store-and-read.md) (§AgentProfile.memory, D5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo

Adicionar o campo `:memory` ao `AgentProfile`: o opt-in por agente que liga a
memória cross-session (fatos + notes, P2C-01). Sem esse campo, o provider de
leitura (task 4) e o cabeamento da tool `remember` (task 6) não têm onde ler
"este agente usa memória?" — a fatia inteira fica sem o interruptor por
agente que o overview (D5) exige.

## Dependências

Nenhuma — pode começar já.

## Contexto

`AgentProfile` é o único ponto de política por agente (00-overview D6): cada
campo novo desde a Fase 0 segue a mesma disciplina — `Data.define` reaberto
via classe (não bloco, para não vazar constante léxica), `build` com defaults
explícitos, e a semântica do campo documentada inline, não só na techspec.

`memory` segue a MESMA assimetria opt-in que `capabilities` (P2B task 3) e
`tools_deferred` (P2B task 7) introduziram: `nil` (ou `false`) = **OFF**, não
"ligado por padrão". Isso é o oposto da regra uniforme de topo do arquivo
(`nil` = todas/permissivo para `tools_allow`/`context_providers`/
`workflows_allow`) — e a razão é a mesma já registrada para `capabilities`:
ligar memória por omissão mudaria o comportamento observável de **todo**
agente já existente (Fase 1/2-A/2-B) no instante em que o campo aparecesse no
`Data.define`, mesmo sem nenhuma migração de perfil. Paridade Fase 1 (P2C-01
D1/D4) exige o oposto: um agente sem o kwarg novo continua exatamente como
está — provider de memória retorna `[]` (task 4) e a tool `remember` não é
cabeada (task 6) — até que alguém marque `memory: true` explicitamente no
profile.

Diferente de `capabilities`/`tools_deferred` (allowlists de nomes), `memory` é
um flag simples (verdade/falsidade), mais próximo em forma de um booleano de
feature — mas a MESMA disciplina de comentário de exceção se aplica: um
leitor futuro que veja `nil` num campo do `AgentProfile` pode presumir "nil =
permissivo" pela regra de topo, e estaria errado aqui. O comentário inline
precisa deixar isso explícito, do mesmo jeito que já foi feito para
`capabilities`.

Este campo NÃO cria nenhum gate por si — ele é lido em dois lugares fora
desta task: `Context::Providers::Memory#enabled_for?` (task 4, `!!profile.memory`)
e o cabeamento condicional da tool `remember` no `configure_chat` (task 6,
gate duplo com a presença do `@memory_store` injetado). Esta task só
introduz o campo e seu default; nenhuma lógica de consumo entra aqui.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/agent_profile.rb` | MODIFY | novo campo `:memory` no `Data.define` + `build(memory: nil)` |
| `spec/harness/agent_profile_spec.rb` | MODIFY | cobertura do default `nil`, do valor `true`, de `false` e retrocompat |

## Passo a passo

### Passo 1 — adicionar o campo ao `Data.define` e ao `build`

Inserir `:memory` no fim da lista de campos do `Data.define` (mesma convenção
já usada por `capabilities`/`tools_deferred`: inserir no fim minimiza chance
de conflito de merge com qualquer outra fatia que também toque este arquivo —
embora nesta fatia C não haja PR paralelo tocando `agent_profile.rb`, ver
Notas). Acrescentar o comentário de campo com a semântica `nil`/`false` = OFF
diretamente acima/ao lado do campo, e o kwarg correspondente em `build` com
default `nil`.

**Padrão de referência (codebase) — estado atual do arquivo** (já contém
`capabilities` e `tools_deferred`, mesclados nas fatias anteriores):

```ruby
# lib/harness/agent_profile.rb (ANTES desta task)

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  #
  # EXCEÇÃO deliberada: `capabilities` (P2B, RFC-0004 §6) NÃO segue a regra do
  # `nil = todas`. nil/ausente = NENHUMA capability (opt-in explícito — expor
  # toda capability registrada por engano acoplaria o agente a plugins que ele
  # não pediu). NÃO "corrija" para ficar consistente com tools_allow.
  AgentProfile = Data.define(
    :id, :model, :provider,           # Fase 0
    :base_prompt, :prompt_files,      # Fase 0
    :tools_allow, :tools_deny,        # Fase 0
    :skills,                          # Fase 0
    :context_providers,               # NOVO — allowlist de providers (RFC-0005 §4.1)
    :workflows_allow,                 # NOVO — aplicado pela WorkflowAllowlist (doc 05 §2)
    :policies,                        # NOVO — nomes no Policy Registry (estágio 3)
    :prompt_refs,                     # NOVO — nomes do Prompt Catalog (doc 04 §2)
    :limits,                          # NOVO — timeouts/orçamentos (D4/D8)
    :approvals_required,              # P2 — tools que exigem aprovação (ApprovalRequired)
    :capabilities,                    # P2B — intenções que o agente pode acionar
    #                                   (RFC-0004 §6). nil = NENHUMA (opt-in, ver acima).
    :tools_deferred                   # P2B — tools searchable-not-wired (Tool Search).
    #                                   nil = nenhuma deferred (tudo eager — paridade Fase 1);
    #                                   [names] ⊆ allowed_tools, expostas via tool_search.
  )

  class AgentProfile
    DEFAULT_LIMITS = { ... }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, tools_deferred: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities, tools_deferred: tools_deferred
      )
    end

    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
```

**Depois (o que este passo produz):**

```ruby
# lib/harness/agent_profile.rb (DEPOIS desta task)

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  #
  # EXCEÇÃO deliberada: `capabilities` (P2B, RFC-0004 §6) NÃO segue a regra do
  # `nil = todas`. nil/ausente = NENHUMA capability (opt-in explícito — expor
  # toda capability registrada por engano acoplaria o agente a plugins que ele
  # não pediu). NÃO "corrija" para ficar consistente com tools_allow.
  #
  # EXCEÇÃO deliberada #2: `memory` (P2C, RFC-0005 §6) também NÃO segue a
  # regra do `nil = todas`/ligado. nil/false = memória DESLIGADA (paridade
  # Fase 1 — provider de contexto retorna [], tool `remember` não é cabeada);
  # true = ligada. Mesma lógica de `capabilities`: ligar memória por padrão
  # mudaria o comportamento de todo agente já existente sem ele ter pedido.
  # NÃO "corrija" para nil = ligado.
  AgentProfile = Data.define(
    :id, :model, :provider,           # Fase 0
    :base_prompt, :prompt_files,      # Fase 0
    :tools_allow, :tools_deny,        # Fase 0
    :skills,                          # Fase 0
    :context_providers,               # NOVO — allowlist de providers (RFC-0005 §4.1)
    :workflows_allow,                 # NOVO — aplicado pela WorkflowAllowlist (doc 05 §2)
    :policies,                        # NOVO — nomes no Policy Registry (estágio 3)
    :prompt_refs,                     # NOVO — nomes do Prompt Catalog (doc 04 §2)
    :limits,                          # NOVO — timeouts/orçamentos (D4/D8)
    :approvals_required,              # P2 — tools que exigem aprovação (ApprovalRequired)
    :capabilities,                    # P2B — intenções que o agente pode acionar
    #                                   (RFC-0004 §6). nil = NENHUMA (opt-in, ver acima).
    :tools_deferred,                  # P2B — tools searchable-not-wired (Tool Search).
    #                                   nil = nenhuma deferred (tudo eager — paridade Fase 1);
    #                                   [names] ⊆ allowed_tools, expostas via tool_search.
    :memory                           # P2C — opt-in de memória cross-session (RFC-0005 §6).
    #                                   nil/false = DESLIGADA (paridade Fase 1, ver exceção
    #                                   acima); true = LIGADA. Gate lido por
    #                                   Context::Providers::Memory#enabled_for? (task 4) e
    #                                   pelo cabeamento condicional de `remember` (task 6).
  )

  class AgentProfile
    DEFAULT_LIMITS = { ... }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil, tools_deferred: nil, memory: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities, tools_deferred: tools_deferred,
        memory: memory
      )
    end

    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
```

Note que `memory` **não** passa por `Array(...)` nem por qualquer coerção
(`!!memory` etc.) no `build` — é repassado exatamente como recebido, mesma
disciplina de `capabilities`/`tools_deferred`. Quem normaliza para booleano
(`!!profile.memory`) é o consumidor (`Context::Providers::Memory#enabled_for?`,
task 4), não este arquivo. Preservar o valor cru evita, por exemplo, que um
`false` explícito vire `nil` (ou vice-versa) antes de chegar no consumidor —
ainda que os dois já colapsem no mesmo efeito prático (OFF), a distinção de
"o que foi passado" não deveria se perder num campo de infraestrutura.

### Passo 2 — não criar helper de gate nesta task

Não adicionar um método tipo `memory_enabled?` ao `AgentProfile`. Quem decide
"memória está ligada para este agente" é o próprio `Context::Providers::Memory
#enabled_for?` (task 4, `!!profile.memory`) e o `configure_chat` (task 6, gate
duplo com `@memory_store` presente). Mesma disciplina já aplicada a
`capabilities` (task 3 da fatia B, que não ganhou `capability_opted_in?`) e a
`tools_deferred` (task 7 da fatia B, sem `deferred?`). Manter o escopo desta
task restrito ao campo e seu default.

## Edge cases

- **`nil` (default/ausente):** memória DESLIGADA — comportamento idêntico à
  Fase 1/2-A/2-B (nenhum contexto de memória injetado, nenhuma tool `remember`
  cabeada). Este é o ponto que garante retrocompatibilidade: todo profile
  existente, construído sem o kwarg novo, continua válido via o default do
  `build` — nenhuma chamada existente quebra nem muda de comportamento.
- **`false` (explícito):** mesmo efeito de `nil` — memória desligada. Não há
  necessidade de distinguir `nil` de `false` no comportamento (ambos = OFF);
  o valor é preservado sem normalização, só para não perder o que foi
  passado.
- **`true`:** memória ligada — o provider (task 4) passa a injetar fatos/notes
  no contexto e o `configure_chat` (task 6) passa a cabear `remember`, DESDE
  QUE o `@memory_store` também esteja injetado no Executor (task 7) — este
  campo por si só não cria o store nem garante nenhum efeito sem o resto da
  fatia estar wireado. Este campo apenas declara a intenção do agente.
- **Retrocompatibilidade:** profiles construídos por specs/fixtures de fases
  anteriores (Fase 0/1/2-A/2-B) que não passam `memory:` continuam
  funcionando sem alteração — o campo novo é 100% aditivo, sem migração de
  dados nem quebra de assinatura posicional (todos os kwargs de `build` têm
  default).

## Testes

**Arquivo:** `spec/harness/agent_profile_spec.rb`

| Cenário | Expectativa |
|---|---|
| `build` sem `memory:` | `profile.memory` é `nil` (default = OFF, paridade Fase 1) |
| `build(memory: true)` | `profile.memory` retorna `true` |
| `build(memory: false)` | `profile.memory` retorna `false` (efeito prático igual a nil, valor preservado) |
| compatibilidade Fase 0 | assinatura mínima (`build(id:, model:)`) continua aceita — nenhum kwarg existente quebrou |
| compatibilidade com `capabilities`/`tools_deferred` | `build` aceita os três kwargs novos juntos sem conflito |

## Definition of Done

- [ ] Campo `:memory` adicionado ao `Data.define` com comentário da
      assimetria (nil/false = OFF, não "ligado") inline, não só na techspec
- [ ] `build` aceita `memory: nil` como default e repassa sem coerção
- [ ] Specs novas cobrindo nil/true/false + specs existentes continuam verdes
      (nenhuma quebra de retrocompatibilidade)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

Diferente das tasks 3/7 da fatia B (P2B), que precisaram de uma seção de
"coordenação de arquivo compartilhado" porque corriam em PRs paralelos
tocando o mesmo `Data.define`, esta é a **ÚNICA** task da fatia C (P2C) que
toca `lib/harness/agent_profile.rb` — não há PR paralelo nesta fatia
disputando o mesmo arquivo. Ainda assim, seguir a convenção já estabelecida
de inserir o campo novo no fim da lista (tanto no `Data.define` quanto nos
kwargs de `build`) por consistência com o padrão do arquivo, não por
necessidade de evitar conflito desta vez.
