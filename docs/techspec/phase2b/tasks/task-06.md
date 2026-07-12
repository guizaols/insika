# Task 06 (P2B): `ToolCatalog` (visão name+description sobre o ToolRegistry)

> **Techspec:** [P2B-02-tool-search.md](../P2B-02-tool-search.md) (L3, L5) · [tasks.md](./tasks.md)
> **Status:** ✅ DONE · **Complexity:** Med · **Etapa:** B

## Objetivo

Criar `Harness::ToolCatalog`, o adaptador FINO sobre o `ToolRegistry` que expõe
a visão "nível 1" (progressive disclosure, RFC-0005 §5) das tools: só
`name`+`description`, o suficiente para o modelo decidir "preciso disso" sem
pagar o custo do schema completo de parâmetros. É o análogo direto do
`SkillCatalog` para tools — mesma forma (`all`/`format_for_prompt`), mesmo
espírito ("catálogo compacto no prompt, detalhe sob demanda"). Sem esta task,
as tasks 8 (`Context::Providers::ToolSearch`), 9 (`Tools::ToolSearch` builtin)
e 10 (Executor `configure_chat`) não têm o que consumir — é a base de toda a
Etapa B.

## Dependências

Nenhuma — pode começar já.

## Contexto

### Progressive disclosure já tem precedente maduro: espelhar, não reinventar

RFC-0005 §5 resolveu o mesmo problema para skills: expor `name`+`description`
de TODAS as skills no prompt (nível 1) e carregar o corpo completo (nível 2)
só quando o modelo chama `load_skill`. `SkillCatalog` é a implementação disso.
Tool Search (P2B-02) replica o padrão trocando skill por tool: `tools_deferred`
(task 7) é a allowlist opt-in de tools que ficam FORA do chat inicial;
`ToolCatalog` é o catálogo compacto delas; `Tools::ToolSearch` (task 9) é o
`load_skill` das tools (promove via `chat.with_tools` em vez de devolver um
corpo markdown).

A diferença estrutural que importa para esta task: `SkillCatalog` **lê do
disco** (`Dir.glob("**/SKILL.md")`, frontmatter YAML) porque skills são
arquivos editáveis por humanos — uma fonte de dados externa ao processo.
`ToolCatalog` não lê nada do disco: as tools já estão todas na memória, no
`ToolRegistry` (Fase 1, `lib/harness/tool_registry.rb`), registradas
programaticamente pelo `Loader` no boot. `ToolCatalog` só **extrai e formata**
o que o `ToolRegistry` já tem (P2B-02 L3: "não reimplementa registro; consulta
as `entries` do `ToolRegistry`").

### De onde vem a `description` (a decisão central desta task)

O `ToolRegistry::Entry` (herdado do `Registry` genérico, `lib/harness/
registry.rb`) é `Data.define(:name, :plugin, :metadata, :factory)` — não tem
campo `description`. A description canônica **não vive no Entry**: vive na
própria tool, via o método de instância `#description` que `RubyLLM::Tool`
expõe (delegando para `self.class.description`, setado pela DSL `description
"..."` no topo da classe — ver `lib/harness/tools/load_skill.rb` como
exemplo real: `description "Carrega as instruções completas..."`).

Isso significa que `ToolCatalog` precisa **instanciar** a tool para ler a
description — exatamente o que o Executor já faz hoje em
`instantiate_tools` (`executor.rb`, estágio 3: `entry.factory.call`) para
montar `state.allowed_tools`. Não é um custo novo nem um padrão novo: é o
mesmo `factory.call` que a Fase 1 já paga, só que aqui a instância é usada
para ler `.description` em vez de para ser envelopada e chamada pelo modelo.

Como as factories registradas no `ToolRegistry` são sempre blocos/callables
**sem argumentos** (`register(name, callable = nil, ..., &block)` —
`factory.call` nunca recebe parâmetros; qualquer dependência que a tool
precise já foi capturada no closure no momento do registro, pelo `Loader`),
instanciar é sempre seguro e não exige que `ToolCatalog` conheça nada sobre
como a tool foi montada.

**Duck typing, não herança de `RubyLLM::Tool`.** `ToolCatalog` não faz
`require "ruby_llm"` nem verifica `is_a?(RubyLLM::Tool)` — só chama
`.description` na instância devolvida pelo factory. Isso mantém `ToolCatalog`
puro e testável sem a gem (mesma disciplina do `ToolEnvelope`, que também
delega via `SimpleDelegator` sem se importar com a classe real da tool). Nos
specs, um dublê qualquer que responda a `:description` já basta — não é
preciso herdar `RubyLLM::Tool` nem carregar a gem.

### O que fica de fora (não é papel do `ToolCatalog`)

`side_effect`, `optional`, `plugin` (o metadata do Entry) e o schema de
parâmetros (`params_schema`, usado pelo `chat.with_tools` de verdade)
**não** aparecem no `ToolCatalog` — quem cuida de `side_effect` é o
`ToolRegistry#side_effect?` (já existe, consumido pelo `ToolEnvelope`); quem
cuida do schema completo é o momento de **promoção** (task 9, `Tools::
ToolSearch#execute`, que devolve name+description+parâmetros ao modelo DEPOIS
de decidir promover). O catálogo nível 1 é deliberadamente pobre — é esse
empobrecimento que economiza tokens no prompt inicial.

## Arquivos

| Arquivo | Ação | Descrição |
|---|---|---|
| `lib/harness/tool_catalog.rb` | CREATE | `Harness::ToolCatalog`: `Entry`, `initialize(tool_registry:)`, `all`, `subset`, `search`, `format_for_prompt` |
| `lib/harness.rb` | MODIFY | `require_relative "harness/tool_catalog"` (logo após `harness/skill_catalog`, mesma vizinhança do catálogo irmão) |
| `spec/harness/tool_catalog_spec.rb` | CREATE | specs puros — dublê de tool respondendo só a `:description`, sem `ruby_llm` |

## Passo a passo

### Passo 1 — `Entry`, `initialize` e `all` (mirror do `SkillCatalog`)

**Padrão de referência (codebase) — `SkillCatalog` (nível 1 + cache eager no
`initialize`):**

```ruby
# lib/harness/skill_catalog.rb (referência)

class SkillCatalog
  Skill = Data.define(:name, :description, :path, :body)

  def initialize(roots)
    @roots = Array(roots)
    @skills = load_all      # cache eager, calculado uma vez
  end

  def all
    @skills.values
  end
end
```

**`ToolRegistry#entries` / `Registry::Entry` (o que existe para consultar):**

```ruby
# lib/harness/registry.rb (referência)
Entry = Data.define(:name, :plugin, :metadata, :factory)

def entries = @entries.values   # -> [Entry], ordem de inserção (Hash Ruby preserva)
```

`ToolCatalog::Entry` é mais enxuto que `SkillCatalog::Skill` — só
`name`+`description` (sem `path`/`body`: não há "corpo" para uma tool, o
"nível 2" dela é o próprio `execute` real, chamado depois da promoção, não um
markdown carregado por uma tool de sistema).

```ruby
# frozen_string_literal: true

module Harness
  class ToolCatalog
    Entry = Data.define(:name, :description)

    def initialize(tool_registry:)
      @tool_registry = tool_registry
      @entries = build_entries   # cache eager — mesma disciplina do SkillCatalog
    end

    def all
      @entries
    end

    private

    def build_entries
      @tool_registry.entries.map do |entry|
        Entry.new(name: entry.name, description: entry.factory.call.description.to_s)
      end
    end
  end
end
```

`@entries` é calculado **uma vez**, no `initialize` — não a cada chamada de
`all`/`search`. Isso evita reinstanciar tool a cada busca (uma instância por
tool já é suficiente para ler a description; reinstanciar em loop seria
desperdício sem benefício, já que a description não muda em runtime).

### Passo 2 — `subset(names)` (recorte deferred permitido)

```ruby
def subset(names)
  wanted = Array(names).map(&:to_s)
  all.select { |e| wanted.include?(e.name) }
end
```

Defensivo: nomes que não existem no catálogo são **silenciosamente
ignorados** — não levanta erro. Isso importa porque quem chama `subset` é o
Executor (task 10) com `deferred_allowed = allowed_tools_names ∩
tools_deferred`, um recorte que já deveria ser válido; mas um `tools_deferred`
desalinhado com o registry (erro de configuração do agente, não bug de
código) não deve derrubar a montagem do chat — a tool simplesmente não
aparece no catálogo, e o modelo nunca fica sabendo que ela existia (falha
segura: menos exposição, nunca mais).

### Passo 3 — `search(query, within: nil)` (matcher PURO, P2B-02 L5)

```ruby
def search(query, within: nil)
  terms = query.to_s.downcase.split(/\s+/).reject(&:empty?)
  return [] if terms.empty?

  universe = within ? subset(within) : all
  scored = universe.each_with_index.filter_map do |entry, idx|
    score = score_entry(entry, terms)
    [entry, score, idx] if score.positive?
  end
  scored.sort_by { |_entry, score, idx| [-score, idx] }.map(&:first)
end

private

def score_entry(entry, terms)
  name = entry.name.downcase
  desc = entry.description.downcase
  terms.sum { |term| (name.include?(term) ? 2 : 0) + (desc.include?(term) ? 1 : 0) }
end
```

Regras do matcher (case-insensitive, substring/keyword, **sem embeddings** —
P2B-02 L5 é explícito sobre isso):

- `query` é tokenizado por espaço em branco; cada termo é buscado como
  substring (case-insensitive) em `name` e em `description`.
- **Peso**: match no `name` vale 2, match na `description` vale 1 — um termo
  que aparece no nome da tool é sinal mais forte de relevância que aparecer
  só na descrição longa. Isso é o "ranking simples" da techspec, não um
  modelo de relevância sofisticado.
- **Determinismo/estabilidade**: `sort_by` usa `[-score, idx]` — o índice
  original (posição no universo de busca) é o critério de desempate
  explícito. Isso é necessário porque `Array#sort_by` do Ruby **não garante
  estabilidade** entre elementos de mesma chave; sem o `idx` no tuplo, duas
  tools empatadas em score poderiam trocar de ordem entre execuções.
- `within:` restringe o universo de busca (tipicamente `deferred_allowed`,
  vindo da task 9/10) chamando `subset` internamente — **não** duplica a
  lógica de filtro por nome.

### Passo 4 — `format_for_prompt(entries)` (mirror exato do `SkillCatalog`)

**Padrão de referência (codebase) — `SkillCatalog#format_for_prompt`:**

```ruby
# lib/harness/skill_catalog.rb (referência)

def format_for_prompt(skills = all)
  return "" if skills.empty?

  entries = skills.map do |s|
    %(  <skill name="#{s.name}">#{s.description}</skill>)
  end.join("\n")

  <<~PROMPT.strip
    <available_skills>
    #{entries}
    </available_skills>

    Antes de agir numa tarefa que casa com uma skill acima, chame a tool
    `load_skill` com o nome dela para carregar as instruções completas.
  PROMPT
end
```

**`ToolCatalog#format_for_prompt`** — mesma forma, trocando a tag e a
instrução final (`load_skill` → `tool_search`):

```ruby
def format_for_prompt(entries = all)
  return "" if entries.empty?

  lines = entries.map { |e| %(  <tool name="#{e.name}">#{e.description}</tool>) }.join("\n")

  <<~PROMPT.strip
    <available_tools>
    #{lines}
    </available_tools>

    Antes de usar uma tool acima, chame `tool_search` com o que você precisa
    fazer para habilitá-la nesta conversa.
  PROMPT
end
```

Consumido tal e qual pela task 8 (`Context::Providers::ToolSearch`) e pela
rota alternativa direto no `configure_chat` (task 10) — nenhuma das duas
formata string por conta própria, ambas delegam a este método (P2B-02 L4:
"o fragmento é derivado... "; task-08 já assume essa assinatura literal:
`@tool_catalog.format_for_prompt(@tool_catalog.subset(deferred_allowed))`).

### Passo 5 — registrar o require em `lib/harness.rb`

Inserir logo após `require_relative "harness/skill_catalog"` (mesma
vizinhança do catálogo irmão — ambos são "camada de leitura" sobre um
registry, sem dependência de carga entre si):

```ruby
require_relative "harness/skill_catalog"
require_relative "harness/tool_catalog"   # NOVO
require_relative "harness/turn_state"
```

Diferente de `harness/tools/load_skill.rb`, `ToolCatalog` **não** faz
`require "ruby_llm"` — só espera que a instância devolvida por
`entry.factory.call` responda a `:description` (duck typing, ver `##
Contexto`). Por isso entra no `lib/harness.rb` normal, sem o cuidado de
"require lazy" que o `LoadSkill`/`ToolSearch` (tools de verdade) exigem.

## Edge cases

- **Tool sem `description`** (`description` nunca setada na classe, ou
  instância que devolve `nil`): `entry.factory.call.description.to_s` vira
  `""` — `Entry#description` nunca é `nil`, evitando `NoMethodError` em
  `format_for_prompt`/`search` (`"".include?(term)` é uma chamada válida,
  sempre `false` para termo não-vazio).
- **`factory.call` levanta exceção** (bug de registro — ex.: uma tool
  registrada errada, faltando dependência no closure): propaga na
  **construção** do catálogo (`initialize`), ou seja, falha alto e cedo no
  boot/wiring — **diferente** do `SkillCatalog`, que ignora silenciosamente
  um `SKILL.md` malformado. A assimetria é deliberada: skills são arquivos
  editáveis por humanos (dado externo, tolerar malformação é razoável);
  tools são registradas programaticamente pelo `Loader` (bug de código, não
  dado de usuário) — falhar cedo é preferível a um catálogo silenciosamente
  incompleto que só se manifesta como "o modelo nunca encontra essa tool" em
  produção.
- **`query` vazia ou só espaços** (`""`, `"   "`, `nil`): `search` devolve
  `[]`. Decisão deliberada — devolver o catálogo inteiro para uma query
  vazia derrotaria o propósito da deferral (o modelo poderia "promover tudo"
  com uma chamada trivial). `tool_search(query: "")` é tratado como busca
  sem match, não como "liste tudo".
- **`within:` com nomes fora do catálogo**: `subset` já filtra
  silenciosamente (ver Passo 2); `search` nunca vê esses nomes, então não há
  caminho de erro adicional a tratar aqui.
- **Ranking com empate**: duas entries com o mesmo score preservam a ordem
  original do universo de busca (`all` ou `subset(within)`), nunca a ordem
  alfabética nem qualquer critério implícito do `sort_by` puro — testado
  explicitamente (ver `## Testes`).
- **Fonte da `description`**: resolvida por **instanciação do factory**, não
  por metadata paralelo no `Registry::Entry` — decisão registrada aqui e não
  revisitável sem migrar o `ToolRegistry` (ver `## Contexto`).
- **Catálogo vazio** (`ToolRegistry` sem nenhuma tool registrada): `all` →
  `[]`, `format_for_prompt([])` → `""`, `search` → `[]` para qualquer query —
  mesmo contrato "vazio é seguro" do `SkillCatalog`.

## Testes

**Arquivo:** `spec/harness/tool_catalog_spec.rb`

Usar um `Harness::ToolRegistry` real (ou o `Registry` genérico) registrado
com dublês simples — uma classe/objeto Ruby comum que responda a
`:description`, **sem** herdar `RubyLLM::Tool` e sem `require "ruby_llm"`
(mesma disciplina de pureza do `skill_catalog_spec.rb`, que só usa
`SkillCatalog` real, sem mocks pesados).

```ruby
FakeTool = Struct.new(:description)
registry = Harness::ToolRegistry.new
registry.register("send_email") { FakeTool.new("Envia um e-mail para um destinatário") }
```

| Cenário | Expectativa |
|---|---|
| `all` sobre registry com N tools | N `Entry(name:, description:)`, uma por entry do registry, na ordem do registry |
| description lida via instância do factory | dublê sem herdar `RubyLLM::Tool`, só responde a `:description` — confirma duck typing |
| tool com `description` `nil` | `Entry#description == ""`, nunca `nil` |
| `subset(["send_email"])` | devolve só a entry correspondente |
| `subset(["send_email", "inexistente"])` | devolve só `send_email`; nome desconhecido ignorado sem erro |
| `subset([])` / `subset(nil)` | `[]` |
| `search("email")` casa por `name` | retorna a tool cujo nome contém "email" |
| `search("destinatário")` casa só por `description` | retorna a tool mesmo sem o termo no nome |
| `search("")` / `search(nil)` / `search("   ")` | `[]` |
| `search` com `within: ["a"]` | tool fora do recorte não aparece mesmo com match forte na description |
| ranking: nome > description | tool que bate no nome vem antes da que só bate na description (mesmo # de termos) |
| ranking: empate preserva ordem original | duas tools com score igual saem na ordem de `all`/`within`, não alfabética |
| `format_for_prompt(catalog.all)` não-vazio | inclui `<available_tools>`, `name="..."`, a description, e a instrução `tool_search` |
| `format_for_prompt([])` | `""` |
| `factory.call` levanta exceção no registro | `ToolCatalog.new(tool_registry:)` propaga a exceção (falha alto e cedo, ver edge case) |

## Definition of Done

- [ ] `Harness::ToolCatalog` criado com `Entry`, `initialize(tool_registry:)`,
      `all`, `subset`, `search`, `format_for_prompt` conforme a interface do
      P2B-02 §Interfaces
- [ ] `description` resolvida por instanciação do factory (`entry.factory.
      call.description`), documentada inline no código — não por metadata
      paralelo no `Registry::Entry`
- [ ] `search` puro, determinístico (nome pesa mais que description, empate
      resolvido por índice original), sem embeddings, sem estado externo
- [ ] `require_relative "harness/tool_catalog"` adicionado em
      `lib/harness.rb`, sem puxar `ruby_llm`
- [ ] Specs cobrindo todos os cenários da tabela acima
- [ ] Suíte verde sem chave de API (matcher PURO, testável sem `ruby_llm`)
- [ ] Rubocop limpo
- [ ] Code review

## Notas

- **Base de toda a Etapa B.** As tasks 8 (`Context::Providers::ToolSearch`) e
  9 (`Tools::ToolSearch` builtin) já assumem literalmente a assinatura desta
  task (`catalog.subset(names)`, `catalog.format_for_prompt(entries)`,
  ambas retornando `[]`/`""` graciosamente para recortes vazios/desconhecidos
  — ver `docs/techspec/phase2b/tasks/task-08.md`, que já cita essa
  assinatura). Qualquer mudança de assinatura decidida durante a
  implementação desta task deve ser propagada para lá antes de fechar a
  Etapa B.
- **Sem coordenação de arquivo compartilhado nesta task**: diferente das
  tasks 3/7 (`agent_profile.rb`) ou 5/10 (`executor.rb#configure_chat`),
  `lib/harness/tool_catalog.rb` é arquivo novo e exclusivo desta task. O
  único ponto de toque compartilhado é `lib/harness.rb` (uma linha de
  `require_relative`), risco de conflito baixo — várias tasks tocam esse
  arquivo, mas em linhas adjacentes de um bloco de requires, não na mesma
  linha.
- Este catálogo **não** decide `side_effect`/aprovação/timeout — isso
  continua sendo papel do `ToolRegistry`/`ToolEnvelope` (Fase 1, inalterado).
  `ToolCatalog` é estritamente "camada de leitura" para o prompt.
