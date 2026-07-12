# Task 07 (P2B): `AgentProfile.tools_deferred`

> **Techspec:** [P2B-02-tool-search.md](../P2B-02-tool-search.md) (L1, L2) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Low · **Etapa:** B

## Objetivo

Adicionar o campo `:tools_deferred` ao `AgentProfile`: a allowlist de tools
que ficam *searchable-not-wired* — fora do cabeamento eager do `configure_chat`,
expostas só via catálogo compacto (`ToolCatalog`, task 6) e promovidas sob
demanda pelo builtin `tool_search` (task 9) quando o modelo precisa delas. É
o campo que o Executor (task 10) vai ler no estágio 5 para decidir **quando**
cabear cada tool permitida — sem esse campo, a task 10 não tem allowlist para
particionar `eager` vs `deferred` e a fatia B inteira fica sem o gatilho de
entrada por agente.

## Dependências

Nenhuma — pode começar já.

## Contexto

Tool Search é a versão-tool do progressive disclosure que a Fase 0/1 já
entregou para skills (`load_skill`): em vez de inchar o prompt com o schema
de todas as tools permitidas, um subconjunto fica fora do prompt inicial e é
promovido sob demanda. `tools_deferred` é a allowlist que declara esse
subconjunto por agente — mas ela **não é uma nova fonte de autoridade**:

- **L1 (P2B-02):** `tools_deferred` decide **QUANDO** cabear, nunca **SE**. O
  conjunto efetivamente deferred no turno é sempre a interseção
  `allowed_tools (Policy, estágio 3) ∩ tools_deferred` — nunca o
  `tools_deferred` sozinho. Uma tool listada em `tools_deferred` que a Policy
  já negou (via `tools_allow`/`tools_deny`/deny-sempre-vence) simplesmente não
  existe para o agente: não aparece no catálogo, não é promovível, não é
  chamável. A Policy continua sendo a única autoridade sobre *o quê*; Tool
  Search só desloca no tempo a exposição do schema de um subconjunto do que
  já foi autorizado. Este campo em si não filtra nada — só declara a
  intenção; quem cruza com `allowed_tools` é o Executor (task 10), fora do
  escopo desta task.
- **L2 (P2B-02):** `tools_deferred: nil` (default/ausente) = **nenhuma** tool
  é deferred → todas as `allowed_tools` são cabeadas eager, exatamente como
  hoje (paridade Fase 1). Nenhum agente existente muda de comportamento ao
  ganhar este campo novo — é opt-in explícito por agente que tem tools
  demais no registry.

Diferente de `capabilities` (task 3, mesma etapa do plano mas Etapa A —
P2B-01), que **quebra** a regra "nil = todas" porque capability é indireção
por intenção sobre um universo de terceiros, `tools_deferred` **segue** a
regra uniforme documentada no comentário de topo do `Data.define`: nil =
permissivo (aqui, "nada fica deferred" = tudo cabeado, o comportamento mais
permissivo em termos de disponibilidade imediata). Não é preciso um
comentário de exceção como o de `capabilities` — só o comentário de campo
padrão, na mesma linha dos demais `context_providers`/`workflows_allow`.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/agent_profile.rb` | MODIFY | novo campo `:tools_deferred` no `Data.define` + `build(tools_deferred: nil)` |
| `spec/harness/agent_profile_spec.rb` | MODIFY | cobertura do default `nil`, do valor explícito e da subset-semantics (comentário/edge case, não enforcement — ver Edge cases) |

## Passo a passo

### Passo 1 — adicionar o campo ao `Data.define` e ao `build`

Inserir `:tools_deferred` na lista de campos do `Data.define`, com o
comentário inline de semântica (nil vs lista), e o kwarg correspondente em
`build` com default `nil`, repassado **sem** `Array(...)` — mesma disciplina
de `capabilities` (task 3): se passasse por `Array()`, a distinção entre
"nenhuma tool deferred" (nil) e "lista vazia explícita" desapareceria antes
de chegar ao consumidor, embora aqui os dois casos já colapsem no mesmo
efeito prático (ver Edge cases) — preservar o valor recebido é o padrão já
estabelecido no arquivo, não uma nova regra inventada por esta task.

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

**Depois (o que este passo produz — assumindo merge após a task 3, que já
adicionou `:capabilities` no fim da lista; ver Notas sobre ordem):**

```ruby
# lib/harness/agent_profile.rb (DEPOIS)

module Harness
  # Único ponto de política por agente (00-overview D6).
  # Semântica de allowlist ÚNICA para tools, skills, providers e workflows
  # (nil = todas [+ opt-in p/ tools optional]; [] = nenhuma p/ skills/allow;
  # [names] = conjunto final; deny sempre vence) — uma regra só, testada uma vez.
  #
  # (comentário de exceção de `capabilities`, se já mesclado — task 3)
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
    :capabilities,                    # P2B (task 3) — allowlist opt-in de intenções, se já mesclada
    :tools_deferred                   # P2B — subconjunto de allowed_tools searchable-not-wired
                                       #   (Tool Search, P2B-02 L1/L2). nil = nenhuma deferred,
                                       #   todas as allowed_tools cabeadas eager (paridade Fase 1).
                                       #   [names] = essas ficam fora do prompt inicial, expostas
                                       #   via tool_search. SEMPRE subconjunto de allowed_tools —
                                       #   decide QUANDO cabear, nunca SE (a Policy no estágio 3
                                       #   continua a única autoridade sobre o quê).
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

Se esta task for mesclada **antes** da task 3 (Etapa A e B correm em
paralelo — ver `tasks.md`), o padrão é o mesmo mas sem a linha
`:capabilities`/`capabilities:` — quem mesclar por último faz o merge manual
das duas inserções (ver Notas).

### Passo 2 — não criar helper de filtro nesta task

Não adicionar um método tipo `deferred?(name)` ou `effective_deferred` ao
`AgentProfile`. Quem cruza `allowed_tools ∩ tools_deferred` é o Executor no
`configure_chat` (task 10), que já tem a `Resolution` da Policy disponível
naquele estágio — este arquivo só guarda a allowlist declarada, sem lógica de
resolução. Mesma disciplina da task 3 (`capabilities` não ganhou
`capability_opted_in?` aqui).

## Edge cases

- **`nil` (default/ausente):** nenhuma tool deferred — todas as
  `allowed_tools` (resultado da Policy) são cabeadas eager no
  `configure_chat`, comportamento idêntico à Fase 1/2-A. Este é o ponto de
  retrocompatibilidade: todo profile existente, construído sem o kwarg novo,
  continua se comportando exatamente como antes.
- **`[]` (lista vazia explícita):** mesmo efeito prático de `nil` — nenhuma
  tool deferred, tudo eager. Diferente de `capabilities` (onde `nil` e `[]`
  também colapsam no mesmo efeito, mas por razões de segurança de opt-in),
  aqui a equivalência é só operacional: um `[]` explícito não altera o
  cabeamento, mas o valor é preservado sem normalização (não convertido a
  `nil`) — quem decide "tratar `[]` como `nil`" na prática é o Executor
  (`Array(tools_deferred).empty?` ou equivalente), fora do escopo desta task.
- **`[names]`:** essas tools **precisam** ser um subconjunto de
  `allowed_tools` para produzir efeito — se um nome em `tools_deferred` não
  estiver em `allowed_tools` (Policy já negou, ou o nome nem existe no
  registry), ele simplesmente não aparece em lugar nenhum: não é cabeado
  eager (óbvio, não estava permitido), não entra no catálogo deferred, não é
  promovível via `tool_search`. Este campo **não valida** essa relação no
  `build` — não há acesso à Policy/registry neste nível; a interseção e
  qualquer validação de nomes órfãos é responsabilidade do Executor (task
  10), que já tem a `Resolution` completa.
- **Retrocompatibilidade:** profiles construídos por specs/fixtures das fases
  anteriores (Fase 0/1/2-A) e da task 3 (capabilities) que não passam
  `tools_deferred:` continuam funcionando sem alteração — campo 100% aditivo,
  todos os kwargs de `build` mantêm default, nenhuma assinatura posicional
  quebra.

## Testes

**Arquivo:** `spec/harness/agent_profile_spec.rb`

| Cenário | Expectativa |
|---|---|
| `build` sem `tools_deferred:` | `profile.tools_deferred` é `nil` (default = nenhuma deferred, paridade Fase 1) |
| `build(tools_deferred: ["send_email"])` | `profile.tools_deferred` retorna `["send_email"]` sem normalização |
| `build(tools_deferred: [])` | `profile.tools_deferred` retorna `[]` (efeito prático igual a nil, valor preservado) |
| compatibilidade Fase 0 | assinatura mínima (`build(id:, model:)`) continua aceita — nenhum kwarg existente quebrou |
| compatibilidade com `capabilities` (task 3), se já mesclada | `build` aceita ambos os kwargs novos juntos sem conflito |

## Definition of Done

- [ ] Campo `:tools_deferred` adicionado ao `Data.define` com comentário de
      semântica inline (nil = nenhuma deferred, paridade Fase 1; subconjunto
      de `allowed_tools`, decide QUANDO não SE)
- [ ] `build` aceita `tools_deferred: nil` como default e repassa sem
      `Array()`
- [ ] Specs novas cobrindo nil/lista/lista-vazia + specs existentes
      continuam verdes (nenhuma quebra de retrocompatibilidade)
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

**COORDENAÇÃO DE ARQUIVO COMPARTILHADO:** a task 3 (Etapa A, PR paralelo)
também edita `lib/harness/agent_profile.rb` para adicionar `:capabilities` —
mesmo `Data.define` e mesmo `build`, em pontos adjacentes (ambas inserem no
fim da lista de campos, por convenção definida na task 3, para minimizar
conflito de linha). Como o techspec (`tasks.md`, §"Coordenação de arquivo
compartilhado") já registra: sequenciar os merges (um PR primeiro, o outro
rebaseia sobre ele) ou mesclar manualmente com atenção — o `Data.define` e a
assinatura de `build` não toleram merge automático limpo se as duas branches
tentarem a mesma posição. Etapas A e B são independentes em design (nenhum
consumidor desta task depende de `capabilities`, e vice-versa) mas
**colidem no arquivo físico**; quem mesclar por último resolve o conflito
concatenando os dois campos novos (ordem entre eles é irrelevante) e os dois
kwargs novos de `build` (idem).
