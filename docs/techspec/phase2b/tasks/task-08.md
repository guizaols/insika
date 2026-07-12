# Task 08 (P2B): `Context::Providers::ToolSearch` (catálogo de tools deferred)

> **Techspec:** [P2B-02-tool-search.md](../P2B-02-tool-search.md) (L4, L6) · [tasks.md](./tasks.md)
> **Status:** ⬜ TODO · **Complexity:** Med · **Etapa:** B

## Objetivo

Criar `Harness::Context::Providers::ToolSearch`, o adaptador de contexto que
expõe o **nível 1** do progressive disclosure de tools (RFC-0005 §5, precedente
maduro das skills): um fragmento `:system` com `<available_tools>` (name +
description das tools em `profile.tools_deferred`) + a instrução "chame
`tool_search` para habilitar". É a metade "candidato" do fluxo — a metade
"promoção" é a `Tools::ToolSearch` builtin (task 9). Sem este provider, um
agente com `tools_deferred` fica com tools fora do prompt e **nenhuma pista**
de que elas existem: o modelo nunca chamaria `tool_search`.

Este provider é **real e usado** — não um contrato preparado à espera de
integração. Ele roda no estágio 2 (Context), lê `request.profile.tools_deferred`
diretamente (a allowlist do perfil, exatamente como o `Skill` provider lê
`profile.skills`) e é registrado em `CONTEXT_PROVIDERS` no wiring (task 11).
Não há espera pela Policy, não há `request.vars`, não há rota alternativa via
`configure_chat` — o techspec (P2B-02 L4) fechou essa decisão: o catálogo é
contexto, produzido aqui.

## Dependências

| Task | Componente | Necessário para |
|---|---|---|
| [Task 06](./task-06.md) | `ToolCatalog` (`lib/harness/tool_catalog.rb`) | `subset`/`format_for_prompt` — este provider é um adaptador FINO sobre ele, igual o `Skill` provider é sobre o `SkillCatalog` |

## Contexto

### Espelha o Skill provider, ponto a ponto

`lib/harness/context/providers/skill.rb` é o **precedente direto**: recebe um
catálogo no `initialize`, no `call(request)` pede o subconjunto efetivo ao
catálogo a partir de um campo do `profile`, formata com
`catalog.format_for_prompt`, devolve `[]` se vazio, senão devolve
`[ContextFragment.build(...)]` com `placement: :system`, `pinned: false`.
`ToolSearch` replica essa forma trocando:

- `@catalog.effective(request.profile.skills)` → `@catalog.subset(request.
  profile.tools_deferred)` — mesmo formato de chamada (perfil → catálogo),
  trocando o método do catálogo (`ToolCatalog` não tem `effective`, só
  `subset`/`search`/`format_for_prompt` — ver `Task 06`);
- `@catalog.format_for_prompt(skills)` → `@catalog.format_for_prompt(entries)`
  do `ToolCatalog` (mesma forma de string `<available_X>` + instrução, mas para
  `tool_search` em vez de `load_skill`);
- `priority: 80` → `priority: 70` (abaixo das skills — ver ordem de sacrifício
  abaixo).

### Nível 1 do progressive disclosure de tools (P2B-02 §Fluxo)

O fluxo completo (documentado no techspec, não implementado nesta task):
`profile.tools_deferred` é a allowlist opt-in; no `configure_chat` (task 10) o
Executor particiona `allowed_tools` (Policy) em `eager` (cabeadas de cara) e
`deferred` (fora do chat inicial, só no catálogo). Este provider entrega
justamente esse catálogo compacto ao prompt de sistema — o "índice" que o
modelo lê antes de decidir chamar `tool_search(query:)` (task 9) para
promover uma tool específica a `chat.tools`. Sem este fragmento, a builtin
`tool_search` existe mas o modelo não sabe que ela é útil nem o que buscar.

### O recorte é `profile.tools_deferred`, conhecido no estágio 2 (L4)

A ordem constitucional do turno é Context (2) → Policy (3) → ... (doc 03 §4).
Uma versão anterior deste plano hesitava aqui: o recorte *deferred permitido*
só é totalmente conhecido **após** a Policy (estágio 3) — cruzamento
`allowed_tools ∩ tools_deferred` — e cogitava fazer o provider depender de
`request.vars` populado por alguém pós-Policy, ou nascer inerte à espera da
task 10.

O techspec (P2B-02 L4, revisado) resolve essa tensão da mesma forma que o
`Skill` provider já resolve a análoga: **o provider não precisa do recorte
pós-Policy**. Ele emite o catálogo de `profile.tools_deferred` puro e simples
— exatamente como o `Skill` provider emite `profile.skills` puro e simples,
sem esperar por `allowed_skills` (que só existe depois da Policy). O catálogo
pode ficar **levemente sobre-inclusivo**: uma tool deferred que a Policy
depois nega ainda aparece listada no `<available_tools>`. Isso é aceitável e
consistente — é o mesmo comportamento que a lista de skills já tem hoje. O
corte que importa de verdade não é de exibição, é de **promoção**: o
`tool_search` (task 9) só promove `deferred ∩ allowed_tools` (a Policy
continua autoritativa ali). Este provider decide só o que é *mostrado*, nunca
o que é *permitido*.

Por que não montar esse catálogo dentro do `configure_chat` (estágio 5, já
com a Resolution em mãos)? Porque isso violaria a regra constitucional "o
Runtime nunca monta prompt" (RFC-0005 §1) — texto de contexto é exclusivo dos
Context Providers. O `configure_chat` só **cabeia** a tool `tool_search` (como
já faz com `load_skill`), nunca injeta o `<available_tools>` no system.

### Ordem de sacrifício (priority)

RFC-0005 §"ordem de sacrifício": histórico antigo → histórico recente →
skills → tools deferred; identidade nunca (pinned). Skills está em `priority:
80`; tools deferred fica **abaixo**, em `priority: 70` — se o orçamento
apertar, o catálogo de tools cai antes das skills, mas ainda sobrevive mais
que histórico "normal" (`session.rb` usa priority `[60 + idx, 79].min`, teto
79). Ou seja, em corte de orçamento: histórico mais antigo cai primeiro,
depois o catálogo de tools deferred (70) pode cair antes de histórico recente
(até 79), depois skills (80), identidade nunca.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/context/providers/tool_search.rb` | CREATE | `Context::Providers::ToolSearch < ContextProvider` |
| `lib/harness.rb` | MODIFY | `require_relative "harness/context/providers/tool_search"` |
| `spec/harness/context/providers/tool_search_spec.rb` | CREATE | specs isoladas (sem Executor, sem RubyLLM) |

## Passo a passo

### Passo 1 — relembrar `Skill`, o precedente exato

**Padrão de referência (codebase) — `Skill` provider inteiro:**

```ruby
# lib/harness/context/providers/skill.rb (referência integral)

module Harness
  module Context
    module Providers
      class Skill < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          skills = @catalog.effective(request.profile.skills)
          block = @catalog.format_for_prompt(skills)
          return [] if block.empty?

          [ContextFragment.build(content: block, placement: :system,
                                 priority: 80, source: id)]
        end
      end
    end
  end
end
```

**`ContextFragment.build` (assinatura exata, `lib/harness/context/fragment.rb`):**

```ruby
ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                              :source, :pinned) do
  def self.build(content:, placement:, source:, priority: 50, tokens: nil,
                 pinned: false)
    new(content: content, placement: placement, priority: priority,
        tokens: tokens, source: source, pinned: pinned)
  end
end
```

**`ContextRequest` expõe `profile` (`lib/harness/context/provider.rb`):**

```ruby
ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                             :checkpoint)
```

### Passo 2 — implementar `ToolSearch`

```ruby
# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Adapta o ToolCatalog (RFC-0005 §5, espelha P2B-02 L4/L6): nível 1 do
      # progressive disclosure de TOOLS deferred — mesma forma do Skill
      # provider (task 15, Fase 1), trocando skill por tool. Adaptador FINO —
      # não reimplementa subset/format_for_prompt (o catálogo é intocado).
      #
      # O recorte é `profile.tools_deferred`, conhecido no estágio 2 — igual
      # ao Skill provider, que usa `profile.skills` (não o `allowed_skills`
      # pós-Policy). O catálogo pode ser levemente sobre-inclusivo (mostrar
      # um deferred que a Policy depois nega); aceitável, consistente com a
      # lista de skills. O corte real acontece na PROMOÇÃO (tool_search,
      # task 9, `deferred ∩ allowed_tools`), não na exibição (P2B-02 L4).
      class ToolSearch < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          entries = @catalog.subset(request.profile.tools_deferred)
          block = @catalog.format_for_prompt(entries)
          return [] if block.empty?

          # pinned: false — priority 70, abaixo das skills (80): ordem de
          # sacrifício histórico -> tools deferred -> skills -> (identidade
          # pinned, nunca). Ver P2B-02 §"ordem de sacrifício".
          [ContextFragment.build(content: block, placement: :system,
                                 priority: 70, source: id)]
        end
      end
    end
  end
end
```

`@catalog.subset(nil)` (perfil sem `tools_deferred`) e `@catalog.subset([])`
(perfil com allowlist vazia) devem ambos devolver `[]` do catálogo (task 6,
`subset` usa `Array(names)` — `Array(nil) == []`); `format_for_prompt([])`
devolve `""`; `call` devolve `[]`. Nenhum tratamento especial de `nil` é
necessário neste provider — a defensividade mora no `ToolCatalog` (task 6),
não aqui, mesma divisão de responsabilidade do `Skill` provider.

### Passo 3 — registrar o require em `lib/harness.rb`

Inserir junto dos demais providers de contexto (mesmo bloco de
`require_relative "harness/context/providers/*"`), depois de `skill`:

```ruby
require_relative "harness/context/providers/request"
require_relative "harness/context/providers/prompt"
require_relative "harness/context/providers/skill"
require_relative "harness/context/providers/tool_search"   # NOVO
require_relative "harness/context/providers/session"
```

### Passo 4 — nota para o wiring (task 11)

Esta task **não** mexe em `config/wiring.rb` — isso é escopo da task 11, que
constrói `TOOL_CATALOG` e precisa adicionar o provider em `CONTEXT_PROVIDERS`,
no mesmo array onde `Providers::Skill` já vive hoje:

```ruby
CONTEXT_PROVIDERS = [
  Context::Providers::Request.new,
  Context::Providers::Prompt.new(base: "", files: [], catalog: PROMPT_CATALOG),
  Context::Providers::Skill.new(catalog: CATALOG),
  Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG),   # NOVO (task 11)
  Context::Providers::Session.new(session_store: SESSION_STORE)
]
```

Diferente da versão anterior deste plano, não há ambiguidade de rota para a
task 11 resolver: o provider é sempre ativo assim que registrado — não existe
cenário em que ele "nasce inerte" no wiring.

## Edge cases

- **`profile.tools_deferred` nil/ausente:** `@catalog.subset(nil)` devolve
  `[]` (task 6: `Array(nil).map(&:to_s)` → `[]`), `format_for_prompt([])` →
  `""`, `call` retorna `[]` — mesmo contrato do `Skill` provider quando
  `format_for_prompt` produz string vazia (nenhum fragmento "vazio" chega ao
  Builder). Reproduz a paridade Fase 1 (P2B-02 L2): agente sem
  `tools_deferred` não ganha fragmento algum.
- **`profile.tools_deferred` == `[]`:** mesmo resultado do caso nil — `[]`.
- **Formato `<available_tools>`:** delegado ao `ToolCatalog#format_for_prompt`
  (task 6) — este provider não formata string por conta própria, só decide
  *quais* entries mandar (subset) e *quando* não mandar nada (`[]`).
- **`priority: 70` / ordem de sacrifício:** documentado acima; testar que fica
  estritamente abaixo do `Skill` provider (80) e que `pinned` é `false` (nunca
  sobrevive a um corte de orçamento sobre skills ou identidade).
- **Sobre-inclusão em relação à Policy:** um nome em `tools_deferred` que a
  Policy (estágio 3) vai negar depois ainda aparece no fragmento deste
  provider — não é bug, é a mesma relação que `Skill`/`profile.skills` já tem
  com `allowed_skills`. Testar que o provider NÃO recebe nem consulta
  `allowed_tools`/Resolution — só `request.profile`.
- **`ToolCatalog#subset` recebendo nomes que não existem no catálogo:**
  comportamento é do catálogo (task 6), não desta task — o provider só repassa
  o que veio em `profile.tools_deferred`. Se `subset` devolver `[]` para nomes
  desconhecidos, o provider degrada para `[]` graciosamente (mesmo caminho do
  "sem deferred").

## Testes

**Arquivo:** `spec/harness/context/providers/tool_search_spec.rb`

| Cenário | Expectativa |
|---|---|
| `profile.tools_deferred` nil | `call` retorna `[]` |
| `profile.tools_deferred` vazio (`[]`) | `call` retorna `[]` |
| `profile.tools_deferred: ["send_email"]`, catálogo tem a entry | 1 fragmento `:system`, `priority: 70`, `pinned: false`, `content` == `catalog.format_for_prompt(catalog.subset(["send_email"]))`, contém `send_email` |
| `profile.tools_deferred` com nome fora do catálogo | `catalog.subset` devolve `[]` (ou subset parcial) → `format_for_prompt` vazio → `call` retorna `[]` quando não sobra nenhuma entry |
| subconjunto: 2 tools no catálogo, só 1 em `profile.tools_deferred` | fragmento contém só a permitida, não a outra |
| `priority`/`pinned` | fragmento fica estritamente abaixo de `Skill` (80): `priority == 70`, `pinned == false` |

Usar um `FakeToolCatalog`/dublê simples (ou o `ToolCatalog` real da task 6,
puro, sem RubyLLM) — sem chat, sem RubyLLM, sem gem `ruby_llm` carregada
(mesma disciplina de `skill_spec.rb`, que só usa `SkillCatalog` real). O
`request` de teste é construído com `Harness::ContextRequest.new(session: nil,
message: "oi", profile: profile, tenant: nil, vars: {}, checkpoint: nil)`,
onde `profile` é um `AgentProfile`/dublê com `tools_deferred` setado
diretamente — mesmo padrão do `skill_spec.rb`, sem depender de `vars`.

## Definition of Done

- [ ] `Context::Providers::ToolSearch` criado, espelhando a forma do `Skill`
      provider (adaptador fino sobre `ToolCatalog`), lendo
      `request.profile.tools_deferred`
- [ ] `priority: 70`, `pinned: false`, `placement: :system` — abaixo de skills
      (80), acima do teto de histórico recente (79 é o teto do `Session`, não
      colide)
- [ ] `[]` quando não há deferred (`profile.tools_deferred` nil, vazio, ou
      subset vazio)
- [ ] Comentário inline documentando que o recorte é sobre-inclusivo em
      relação à Policy por design (mesma relação do `Skill` com
      `allowed_skills`), e que o corte real é na promoção (task 9)
- [ ] `require_relative` adicionado em `lib/harness.rb`
- [ ] Suíte verde sem chave de API
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Provider real e ativo, não "preparado-mas-inerte".** Diferente de uma
  versão anterior deste plano, esta task não depende de `request.vars` nem de
  uma decisão futura da task 10 sobre "qual rota de injeção" usar. O provider
  lê `request.profile.tools_deferred` diretamente, do mesmo jeito que
  `Context::Providers::Skill` já lê `request.profile.skills` hoje — sem seam,
  sem convenção de chave pendente, sem depender de alguém popular `vars` pós-
  Policy. A única coisa que falta para o provider produzir efeito em produção
  é o registro em `CONTEXT_PROVIDERS` (task 11), que é wiring puro — não uma
  decisão de arquitetura em aberto.
- **Task 11 wireia.** `config/wiring.rb` ganha `TOOL_CATALOG` e adiciona
  `Context::Providers::ToolSearch.new(catalog: TOOL_CATALOG)` a
  `CONTEXT_PROVIDERS`, na mesma lista onde `Providers::Skill` já está — ver
  `## Passo a passo`, Passo 4.
- **Coordenação com a task 6:** a assinatura consumida aqui
  (`catalog.subset(names)`, `catalog.format_for_prompt(entries)`) é a mesma
  que a task 6 já expõe no `## Passo a passo` dela — não há campo novo a
  pedir ao `ToolCatalog`. Qualquer mudança de assinatura na task 6 deve ser
  propagada para cá antes de fechar a Etapa B.
