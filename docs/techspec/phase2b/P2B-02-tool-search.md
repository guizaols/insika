# P2B-02 — Tool Search: progressive disclosure de tools

> **RFC base:** 0005 §5 (progressive disclosure — precedente maduro das skills),
> 0002 §6 (Tool Execution / loop RubyLLM).
> **Evolui:** `lib/harness/agent_profile.rb`, `lib/harness/executor.rb`,
> `config/wiring.rb`. **Novo:** `lib/harness/tool_catalog.rb`,
> `lib/harness/context/providers/tool_search.rb`, `lib/harness/tools/tool_search.rb`.
> **Overview:** D5, D6, D7. **Espelha:** `skill_catalog.rb`,
> `context/providers/skill.rb`, `tools/load_skill.rb`.

## Objetivo

Quando o registry de tools cresce, expor o schema de TODAS as tools permitidas
incha o prompt e degrada a escolha do modelo. As skills já resolveram isso com
progressive disclosure (nível 1 = name+description no system; nível 2 =
`load_skill` sob demanda). Tool Search replica o padrão para tools: um subconjunto
*deferred* fica fora do prompt inicial, listado num catálogo compacto, e uma
builtin `tool_search(query)` **promove** as relevantes para o chat vivo quando o
modelo precisa. É a versão-tool do que a Fase 0/1 já entregou para skills.

## Fluxo

```
profile.tools_deferred = ["send_email", "create_invoice", ...]   (allowlist)

MONTAGEM (Executor, estágio 5 configure_chat):
  eager    = allowed_tools (Policy) - tools_deferred
  deferred = allowed_tools (Policy) ∩ tools_deferred
  chat.with_tools(*eager, ToolSearch.new(catalog, deferred_allowed, chat))   [+ LoadSkill]
  contexto (system) recebe o catálogo compacto dos deferred (name+description)

LOOP RubyLLM:
  modelo lê <available_tools> e decide: precisa de "enviar email"
  chama tool_search(query: "enviar email")
    ToolSearch#execute:
      1. matches = catalog.search(query) ∩ deferred_allowed         [matcher PURO]
      2. instancia os matches; chat.with_tools(*wrap(matches))       [PROMOÇÃO, D6]
      3. emit :tool_search { query, matched: [names] }
      4. devolve ao modelo: name+description+schema dos matches
  próximo round: RubyLLM re-serializa chat.tools -> "send_email" chamável
  modelo chama send_email(...)   (passa pelo ToolEnvelope normal)
```

## Decisões

### L1 — `tools_deferred` decide QUANDO cabear, nunca SE (D5)
`deferred` é sempre **subconjunto de `allowed_tools`** (a decisão da Policy no
estágio 3). Tool Search nunca expande o que o agente pode chamar — só atrasa a
exposição do schema. Uma tool deferred que a Policy negou simplesmente não existe
para o agente (nem no catálogo, nem promovível). A autoridade continua na Policy.

### L2 — `tools_deferred: nil` = comportamento da Fase 1 (paridade)
`nil`/ausente → nenhuma tool é deferred → todas as `allowed_tools` são cabeadas de
cara, exatamente como hoje. Nenhum agente existente muda de comportamento. Opt-in
explícito por agente que tem tools demais.

### L3 — `ToolCatalog` é adaptador FINO sobre o `ToolRegistry` (espelha `SkillCatalog`)
Não reimplementa registro; consulta as `entries` do `ToolRegistry` e extrai
`name` + `description`. A description vem da classe `RubyLLM::Tool` (método
`description` da tool) OU do metadata da Entry — resolver a fonte na task (o
`load_skill` lê do frontmatter; aqui a tool é executável, então a description
canônica é a da própria tool). O catálogo é a "visão nível 1" das tools deferred,
análogo a `SkillCatalog#format_for_prompt`.

### L4 — `Context::Providers::ToolSearch` emite o catálogo de `profile.tools_deferred` no estágio 2 (decisão D4, espelha EXATAMENTE o Skill provider)
Um Context Provider (RFC-0005 §2) que emite um `ContextFragment` `:system` com a
lista `<available_tools>` (name+description) + a instrução "chame `tool_search`
para habilitar". `pinned: false`, priority ~70 (abaixo das skills=80: ordem de
sacrifício histórico → skills → tools deferred; identidade nunca). `[]` quando o
agente não tem deferred.

**O recorte é `profile.tools_deferred` (∩ tools registradas), conhecido no estágio
2** — igual ao Skill provider, que usa `profile.skills` (não o `allowed_skills`
pós-Policy). Isso RESOLVE a falsa "nuance" da versão anterior: o catálogo não
precisa da Resolution nem do seam `request.vars`. O catálogo pode ser levemente
sobre-inclusivo (mostrar um deferred que a Policy depois nega) — **exatamente como
a lista de skills mostra `profile.skills` e a Policy pode estreitar**; aceitável e
consistente. O corte real acontece na PROMOÇÃO (o `tool_search` só habilita
`deferred ∩ allowed_tools`, L5) — não na exibição.

> **Por que NÃO montar o catálogo no `configure_chat`:** injetar texto de prompt no
> Executor violaria a regra constitucional "o Runtime nunca monta prompt" (RFC-0005
> §1). Contexto é exclusivo dos Context Providers. O `configure_chat` só CABEIA a
> tool `tool_search` (como faz com `load_skill`), nunca injeta o `<available_tools>`.

### L5 — `Tools::ToolSearch` promove via `chat.with_tools` (D6, espelha `LoadSkill`)
Como `LoadSkill` recebe o `catalog` + `allowed_names`, `ToolSearch` recebe
`catalog` + `deferred_allowed` + `chat`. `execute(query:)`:
1. `matches = catalog.search(query)` filtrado por `deferred_allowed` (matcher
   PURO: substring/keyword sobre name+description, case-insensitive — determinístico,
   testável sem modelo; ranking simples, sem embeddings nesta fatia);
2. instancia os matches (via `tool_registry`), embrulha no `ToolEnvelope` (mesmo
   wrap das eager), `chat.with_tools(*wrapped)`;
3. `emit :tool_search { query, matched }`;
4. retorna ao modelo os matches (name+description+parâmetros) — o schema que ele
   precisa para chamar.
Respeita a allowlist (só promove o que está em `deferred_allowed`): o modelo não
promove uma tool que a Policy não liberou (L1). Idempotente: re-promover a mesma
tool é no-op (`chat.with_tools` já a tem).

### L6 — `tool_search` é tool de SISTEMA, fora da allowlist (espelha `load_skill`)
`configure_chat` já adiciona `LoadSkill` como default de sistema quando há skills;
adiciona `ToolSearch` quando há deferred. Nunca envelopada (sem side-effect,
latência trivial — mesma regra do `load_skill`, ver Notes da Fase 1). O evento
`:tool_search` é o análogo do `:skill_activated`. O `configure_chat` só CABEIA a
tool (o catálogo `<available_tools>` vem do Provider L4, não daqui).

### L7 — Nome estável do tool de sistema (decisão D2 — corrige bug latente da Fase 0)
`RubyLLM::Tool#name` deriva do nome da CLASSE demodulizado: verificado rodando a
gem 1.16, `Harness::Tools::LoadSkill.new.name` → `"harness--tools--load_skill"`
(não `"load_skill"`). Toda tool de sistema DEVE sobrescrever `#name`:
`Tools::ToolSearch#name = "tool_search"`. O `LoadSkill` da Fase 0 carrega esse bug
latente (o modelo vê o nome feio e a checagem `last_tool_name == "load_skill"` em
`wire_callbacks`/`:skill_activated` nunca casa em produção) — **corrigir junto no
mesmo PR** com um one-liner `def name = "load_skill"`. Barato, adjacente, remove um
bug real de correção.

## Interfaces

### `ToolCatalog` (`lib/harness/tool_catalog.rb`)
```ruby
module Harness
  class ToolCatalog
    Entry = Data.define(:name, :description)

    def initialize(tool_registry:)          # visão sobre o registry (L3)
    def all                                  # -> [Entry]
    def subset(names)                        # -> [Entry] (recorte deferred permitido)
    def search(query, within: nil)           # -> [Entry] matcher PURO (L5), ranqueado
    def format_for_prompt(entries)           # -> String <available_tools> (espelha SkillCatalog)
  end
end
```

### `AgentProfile` — novo campo `tools_deferred`
```ruby
# tools_deferred: allowlist de tools searchable-not-wired (Tool Search).
#   nil = nenhuma deferred (todas as allowed_tools cabeadas de cara — Fase 1)
#   [names] = essas ficam fora do prompt inicial, expostas via tool_search
AgentProfile = Data.define(..., :tools_deferred)   # + build(tools_deferred: nil)
```

### `Context::Providers::ToolSearch` (`lib/harness/context/providers/tool_search.rb`)
```ruby
module Harness
  module Context
    module Providers
      class ToolSearch < ContextProvider
        def initialize(catalog:)             # ToolCatalog
        def call(request)                    # -> [ContextFragment] :system, priority ~70
      end                                    #    (recorte deferred: ver L4/L6)
    end
  end
end
```

### `Tools::ToolSearch` (`lib/harness/tools/tool_search.rb`)
```ruby
module Harness
  module Tools
    class ToolSearch < RubyLLM::Tool           # herda da gem (require lazy, como LoadSkill)
      description "Busca e habilita ferramentas adicionais por descrição da necessidade"
      param :query, desc: "O que você precisa fazer (ex.: 'enviar email', 'gerar fatura')"

      def name = "tool_search"                 # L7: nome estável (senão "harness--tools--tool_search")
      # ToolEnvelope p/ os matches promovidos exige checkpoint_store: (task 9)
      def initialize(catalog, deferred_allowed, chat, tool_registry:, checkpoint_store:, event_stream:, state:)
      def execute(query:)                      # matcher + promoção via chat.with_tools (L5)
    end
  end
end
```

## Integração no Executor (`executor.rb`)

- `configure_chat` (estágio 5): se `profile.tools_deferred` não-vazio, computa
  `deferred_allowed = allowed_tools_names ∩ profile.tools_deferred`; **exclui as
  deferred do `with_tools`** (só `eager = allowed_tools − deferred` são cabeadas);
  adiciona `Tools::ToolSearch.new(@tool_catalog, deferred_allowed, chat, ...)` como
  tool de SISTEMA (fora da allowlist, un-enveloped, como `LoadSkill`). **NÃO injeta
  `<available_tools>` no system** — esse catálogo vem do `Context::Providers::
  ToolSearch` (estágio 2, L4); o Runtime não monta prompt (RFC-0005).
- `create_chat`: `require_relative "tools/tool_search"` lazy (como `load_skill`, D9).
- Novo `@tool_catalog` no construtor (default `nil` → sem Tool Search, paridade
  Fase 1). Wiring em `config/wiring.rb` (o Provider L4 também entra em
  `CONTEXT_PROVIDERS`).
- Interação com capability (P2B-01): capabilities resolvem para tools **eager**
  (nome estável). Deferral é ortogonal e aplica-se a tools diretas; uma capability
  não é deferred nesta fatia (nota, não bloqueio).

## Testes (fazem parte de cada task)

- **`ToolCatalog#search`** (puro, sem gem): match por name e por description,
  case-insensitive; `within:` respeita o recorte deferred; ordem determinística.
- **`Tools::ToolSearch#execute`** (chat FAKE que registra `with_tools`): promove
  os matches; ignora tool fora de `deferred_allowed`; emite `:tool_search`;
  re-promoção idempotente. Sem modelo real.
- **`Context::Providers::ToolSearch`**: fragmento só quando há deferred; formato
  `<available_tools>`; vazio → `[]`.
- **Integração (RubyLLM mockado)**: agente com `tools_deferred` não vê a tool no
  chat inicial; após `tool_search`, a tool está em `chat.tools` e é chamável;
  `tools_deferred: nil` → tudo cabeado de cara (paridade Fase 1).

## Riscos específicos

- **Promoção mid-loop (D6):** depende de o `ruby_llm` 1.16 re-serializar
  `chat.tools` no round seguinte a um `with_tools` chamado DENTRO de um `execute`.
  **Mitigação:** um teste de integração dedicado com o stub de chat da suíte (task
  14) exercita exatamente isso ANTES de fechar a task 9; se 1.16 não propagar no
  mesmo `ask`, cai no fallback (tool chamável no próximo turno) — documentar e
  medir. Ver `00-overview` §Riscos.
