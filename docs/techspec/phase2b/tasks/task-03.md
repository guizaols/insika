# Task 03 (P2B): `AgentProfile.capabilities`

> **Techspec:** [P2B-01-capability-registry.md](../P2B-01-capability-registry.md) (§Interfaces, L3) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Low · **Etapa:** A

## Objetivo

Adicionar o campo `:capabilities` ao `AgentProfile`: a allowlist de intenções
(`:browse`, etc.) que o agente pode referenciar. É o campo que o Executor vai
percorrer (task 5) para resolver providers via `CapabilityRegistry` (task 1)
antes do estágio de Policy. Sem esse campo, nenhum agente consegue declarar
capabilities — as tasks 1/2/4 ficam com registry pronto mas sem consumidor.

## Dependências

Nenhuma — pode começar já.

## Contexto

`AgentProfile` é o único ponto de política por agente (00-overview D6): cada
campo novo desde a Fase 0 segue a mesma disciplina — `Data.define` reaberto via
classe (não bloco, para não vazar constante léxica), `build` com defaults
explícitos, e uma semântica de allowlist documentada no comentário do campo.

Até agora essa semântica era **uniforme**: `nil` = permite tudo (`tools_allow`,
`context_providers`, `workflows_allow`), exceto onde `[]` já é o default vazio
(`tools_deny`, `skills` tratado à parte). `capabilities` **quebra essa
uniformidade de propósito**: RFC-0004 §6 decide que `nil`/ausente = **nenhuma**
capability, não "todas". A justificativa (P2B-01 L3, linha 132-135): expor
automaticamente toda capability registrada por um plugin de terceiros acoplaria
o agente a comportamento que ele nunca pediu — diferente de `tools_allow`, onde
"todas as tools registradas" já é um universo controlado pelo próprio Loader
(`contracts.tools`) e pela Policy no estágio 3. Capability é opt-in explícito:
o agente só ganha acesso à intenção `:browse` se `capabilities: [:browse]`
aparecer no profile.

Essa assimetria **precisa** de um comentário inline no `Data.define` (não só na
techspec) — é o tipo de decisão que um leitor futuro vai querer inverter "para
ficar consistente com os outros campos", e estaria errado ao fazer isso.

A allowlist de política de tools sobre o `impl_name` candidato (`tools_allow`/
`tools_deny` via `tool_opted_in?`) é reusada por dentro da resolução (task 1,
L3) — não é este campo que faz esse papel; `capabilities` só define **quais
intenções** o agente pode acionar, a política de qual implementação atende
continua em `tools_allow`/`tools_deny`.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/agent_profile.rb` | MODIFY | novo campo `:capabilities` no `Data.define` + `build(capabilities: nil)` |
| `spec/harness/agent_profile_spec.rb` | MODIFY | cobertura do default `nil` e do valor explícito |

## Passo a passo

### Passo 1 — adicionar o campo ao `Data.define`

Inserir `:capabilities` na lista de campos, ao lado dos demais campos "NOVO"
desta fatia (posição não é semanticamente relevante, mas manter perto de
`workflows_allow`/`context_providers` — mesma família de allowlist de
indireção — ajuda a leitura). Acrescentar o comentário da assimetria
diretamente acima do campo, não só no comentário de topo do arquivo.

**Padrão de referência (codebase) — estado atual:**

```ruby
# lib/harness/agent_profile.rb (ANTES)

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
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
    :approvals_required               # P2 — tools que exigem aprovação (ApprovalRequired)
  )

  class AgentProfile
    DEFAULT_LIMITS = { ... }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required
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
# lib/harness/agent_profile.rb (DEPOIS)

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  #
  # EXCEÇÃO deliberada: `capabilities` (P2B, RFC-0004 §6) NÃO segue essa regra.
  # nil/ausente = NENHUMA capability (não "todas", ao contrário de tools_allow/
  # context_providers/workflows_allow). Capability é opt-in explícito: o agente
  # precisa listar a intenção (`:browse`) para ganhar acesso a ela. Expor toda
  # capability registrada por engano acoplaria o agente a plugins de terceiros
  # que ele nunca pediu — risco que não existe em tools_allow (o universo já é
  # controlado por contracts.tools do Loader + Policy no estágio 3).
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
    :capabilities                     # P2B — allowlist opt-in de intenções (RFC-0004 §6; nil = NENHUMA, ver comentário acima)
  )

  class AgentProfile
    DEFAULT_LIMITS = { ... }.freeze

    def self.build(id:, model:, provider: nil, base_prompt: "", prompt_files: [],
                   tools_allow: nil, tools_deny: [], skills: nil,
                   context_providers: nil, workflows_allow: nil,
                   policies: [], prompt_refs: [], limits: {}, approvals_required: nil,
                   capabilities: nil)
      new(
        id: id, model: model, provider: provider, base_prompt: base_prompt,
        prompt_files: Array(prompt_files), tools_allow: tools_allow,
        tools_deny: Array(tools_deny), skills: skills,
        context_providers: context_providers, workflows_allow: workflows_allow,
        policies: Array(policies), prompt_refs: Array(prompt_refs),
        limits: DEFAULT_LIMITS.merge(limits), approvals_required: approvals_required,
        capabilities: capabilities
      )
    end

    def tool_opted_in?(name)
      Array(tools_allow).include?(name)
    end
  end
end
```

Note que `capabilities` **não** passa por `Array(...)` no `build` — ao
contrário de `tools_deny`/`policies`/`prompt_refs`. Isso é intencional: se
passasse por `Array()`, `nil` viraria `[]` e a distinção "nenhuma capability
declarada" vs "lista vazia explícita" desapareceria antes de chegar ao
consumidor (task 1/5). Quem for resolver (`CapabilityRegistry#resolve` ou o
Executor) trata `nil` e `[]` como equivalentes na prática — ambos "não
resolver nada" — mas o campo em si preserva o valor recebido, sem normalizar.

### Passo 2 — não criar helper de opt-in para capabilities nesta task

`tool_opted_in?` continua servindo só a tools (Fase 0, inalterado). A
resolução de capability (task 1, L3) reusa esse método sobre o `impl_name`
candidato — não sobre o nome da capability. Não adicionar um
`capability_opted_in?` aqui: quem decide "essa capability está na allowlist do
agente" é o próprio `Array(profile.capabilities).include?(cap)` direto no
Executor/registry (task 1/5), não um método novo no `AgentProfile`. Manter o
escopo desta task restrito ao campo.

## Edge cases

- **`nil` (default/ausente):** nenhuma capability — comportamento idêntico à
  Fase 1/2-A (só tools diretas, nenhuma indireção por intenção). Este é o
  ponto que garante retrocompatibilidade: todo profile existente, construído
  sem o kwarg novo, continua válido via o default do `build` — nenhuma
  chamada existente quebra.
- **`[]` (lista vazia explícita):** mesma prática de "nenhuma" que `nil` — não
  há capability para resolver. Diferente de `tools_allow`, aqui `nil` e `[]`
  coincidem no efeito (ambos = nenhuma), então não há necessidade de
  distingui-los no comportamento — só no comentário, para deixar claro que a
  ausência do campo não é acidental.
- **`[names]`:** essas capabilities (símbolos ou strings, a task 1 define o
  tipo de chave do registry — manter consistente) são candidatas à resolução
  no turno; a task 5 é quem de fato itera e resolve.
- **Retrocompatibilidade:** profiles construídos por specs/fixtures de fases
  anteriores (Fase 0/1/2-A) que não passam `capabilities:` continuam
  funcionando sem alteração — o campo novo é 100% aditivo, sem migração de
  dados nem quebra de assinatura posicional (todos os kwargs de `build` têm
  default).

## Testes

**Arquivo:** `spec/harness/agent_profile_spec.rb`

| Cenário | Expectativa |
|---|---|
| `build` sem `capabilities:` | `profile.capabilities` é `nil` (default = nenhuma, não "todas") |
| `build(capabilities: [:browse])` | `profile.capabilities` retorna `[:browse]` sem normalização |
| `build(capabilities: [])` | `profile.capabilities` retorna `[]` (equivalente a nil na prática, mas preservado como veio) |
| compatibilidade Fase 0 | assinatura mínima (`build(id:, model:)`) continua aceita — nenhum kwarg existente quebrou |

## Definition of Done

- [ ] Campo `:capabilities` adicionado ao `Data.define` com comentário da
      assimetria (nil = nenhuma) inline, não só na techspec
- [ ] `build` aceita `capabilities: nil` como default e repassa sem `Array()`
- [ ] Specs novas cobrindo nil/lista/lista-vazia + specs existentes continuam
      verdes (nenhuma quebra de retrocompatibilidade)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**COORDENAÇÃO DE ARQUIVO COMPARTILHADO:** a task 7 (Etapa B, PR paralelo)
também edita `lib/harness/agent_profile.rb` para adicionar `:tools_deferred`.
As duas tasks tocam o mesmo `Data.define` e o mesmo `build` em pontos
adjacentes. Como o techspec (`tasks.md`) já aponta, sequenciar os merges (um
PR primeiro, o outro rebaseia) ou mesclar manualmente com atenção — o
`Data.define` e a assinatura de `build` não toleram merge automático limpo se
as duas branches inserirem o campo novo na mesma posição da lista. Preferir
inserir `:capabilities` no fim da lista de campos (como no Passo 1) para
minimizar a chance de conflito de linha com `:tools_deferred` da task 7.
