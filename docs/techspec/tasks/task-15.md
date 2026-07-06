# Task 15: Providers `Request`, `Prompt` (absorve SystemPrompt/SOUL.md + prompt_refs), `Skill`, `Session` (teto 79)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [04-context-builder-providers.md](../04-context-builder-providers.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Implementar os quatro Context Providers da Fase 1 (`Request`, `Prompt`, `Skill`, `Session`) sobre a classe base da task 14, substituindo o `system_prompt.rb` da Fase 0 com paridade byte-a-byte comprovada por teste de caracterização.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 5 | `SessionStore` (schema `session:<id>`, transcript como fonte da verdade) | ⬜ TODO |
| 14 | `ContextFragment`/`ContextProvider`/`Builder` (fan-out Async, orçamento global, pinned, evicção) | ⬜ TODO |
| 20* | `Registry` genérico + Workflow/Policy Registries + `PromptCatalog` (PROMPT.md) | ⬜ TODO — **OPCIONAL** |

Grafo (tasks.md): `15 (Providers) → 5, 14, 20*` — a dependência da 20 é **só o parâmetro** `catalog:` do provider `Prompt` (default `nil`); a 20 pode chegar depois. Esta task NÃO bloqueia em `PromptCatalog`: com `catalog: nil` e perfil sem `prompt_refs`, tudo funciona. O caminho de `prompt_refs` é testado com um duplo do catálogo (só precisa responder `find(name)`).

## Context

Implementa o doc **04 §2 ("Providers da Fase 1") e §8**, com D2 (fontes de transcript), D6 (`prompt_refs`) e doc 02 §2–§3 (Session/Checkpoint). Os providers são a matéria-prima do Builder (task 14): cada um produz `[ContextFragment]` puro; quem orça, corta e monta é o Builder.

Evolução da Fase 0 (doc 04 §8 e doc 00 §4):
- `system_prompt.rb` → **substituído** por `Providers::Prompt` (a concatenação base+files migra intacta; o `skills_block` deixa de ser parâmetro e vira o fragmento do `Providers::Skill`);
- `skill_catalog.rb` → **intocado** (migra na Etapa F sem mudança de lógica); `Providers::Skill` é adaptador fino sobre `effective`/`format_for_prompt`;
- no wiring futuro, `SYSTEM_PROMPT` vira `Providers::Prompt.new(files: [SOUL.md])` e o Builder é montado com os 4 providers.

Habilita: task 12 (`SendMessage` troca providers stub pelos reais) e task 20/23 (prompt_refs com catálogo real).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/context/providers/request.rb` | Metadados do turno, priority 40 |
| CREATE | `lib/harness/context/providers/prompt.rb` | Identidade pinned 100 + prompt_refs 90; `required? = true` |
| CREATE | `lib/harness/context/providers/skill.rb` | Adaptador do SkillCatalog, priority 80 |
| CREATE | `lib/harness/context/providers/session.rb` | Transcript → fragmentos `:history`, teto 79 (L7) |
| MODIFY | `lib/harness.rb` | `require_relative` dos 4 providers |
| CREATE | `spec/harness/context/providers/request_spec.rb` | Casos com/sem metadados |
| CREATE | `spec/harness/context/providers/prompt_spec.rb` | base/files/refs + **caracterização vs Fase 0** |
| CREATE | `spec/harness/context/providers/skill_spec.rb` | Adaptação effective/format_for_prompt |
| CREATE | `spec/harness/context/providers/session_spec.rb` | 3 fontes de transcript + teto 79 |

> Layout doc 00 §3: `lib/harness/context/providers/{request,session,skill,prompt}.rb`. Namespace: `Harness::Context::Providers` (doc 04 §2). O `SkillCatalog` só migra para `lib/harness/skill_catalog.rb` na Etapa F — se ainda não existir em `lib/`, os specs do provider `Skill` podem usar um duplo com a interface `effective`/`format_for_prompt` OU carregar o catálogo da Fase 0 como fixture (ver Testing).

### Step-by-Step Instructions

#### Step 1: `Providers::Request`

**File:** `lib/harness/context/providers/request.rb`

```ruby
module Harness
  module Context
    module Providers
      # Fragmento :system com metadados do turno (tenant, vars relevantes).
      # Nada se não houver metadados. priority: 40 (doc 04 §2).
      class Request < ContextProvider
        def call(request)
          lines = []
          lines << "tenant: #{request.tenant}" if request.tenant
          request.vars.to_h.each { |k, v| lines << "#{k}: #{v}" }
          return [] if lines.empty?

          [ContextFragment.build(
            content: "<request_context>\n#{lines.join("\n")}\n</request_context>",
            placement: :system, priority: 40, source: id
          )]
        end
      end
    end
  end
end
```

Regras do doc 04 §2: priority 40, `:system`, **sem fragmento** quando não há metadados (`tenant` nil e `vars` vazio → `[]`). Não é `required?` (metadados podem degradar — L5). O formato textual exato não é fixado pelo techspec (ver Notes); o que é contrato: determinístico, um fragmento único, e vazio ⇒ nenhum fragmento.

#### Step 2: `Providers::Prompt` — identidade pinned + prompt_refs

**File:** `lib/harness/context/providers/prompt.rb`

Absorve `SystemPrompt` + `SOUL.md` da Fase 0 (doc 04 §2 e §8):

```ruby
module Harness
  module Context
    module Providers
      # Absorve SystemPrompt + SOUL.md (Fase 0). Identidade é PINNED,
      # priority 100 — nunca cortada (RFC-0005 §4.4). required?: agente sem
      # identidade é um agente errado, não um agente degradado (doc 04 §6).
      class Prompt < ContextProvider
        def initialize(base: "", files: [], catalog: nil)
          @base = base
          @files = Array(files)
          @catalog = catalog
        end

        def required? = true

        def call(request)
          fragments = []
          identity = build_identity            # mesma lógica do SystemPrompt#build
          fragments << ContextFragment.build(
            content: identity, placement: :system,
            priority: 100, source: id, pinned: true
          ) unless identity.empty?
          fragments.concat(ref_fragments(request.profile))
          fragments
        end

        private

        # Migra INTACTA a concatenação do SystemPrompt#build (sem skills_block):
        def build_identity
          parts = [@base]
          @files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
          parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
        end

        def ref_fragments(profile)
          refs = Array(profile.prompt_refs)
          return [] if refs.empty?

          refs.map do |name|
            entry = @catalog&.find(name.to_s)
            raise ContextError, "prompt_ref '#{name}' não encontrado no Prompt Catalog" unless entry

            ContextFragment.build(content: entry.body, placement: :system,
                                  priority: 90, source: id, pinned: true)
          end
        end
      end
    end
  end
end
```

Regras (doc 04 §2, D6):
- Identidade (base+files) = **um** fragmento `:system`, `priority: 100`, `pinned: true`. Um fragmento único preserva a ordem interna base→files e garante a paridade byte-a-byte (a task 14 ordena por priority/source — a ordem intra-provider fica encapsulada no fragmento).
- `prompt_refs` (D6): um fragmento por ref, na ordem de `profile.prompt_refs`, `priority: 90`, `pinned: true`, com o `body` do `PromptCatalog::Prompt` (doc 06 §2).
- Nome inexistente no catálogo **ou** `prompt_refs` presente com `catalog: nil` → `ContextError` — "config inválida falha alto" (doc 04 §2).
- `required? = true`: qualquer falha (arquivo ilegível, ref inexistente) aborta o turno via `ContextError` no Builder (D4).

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/system_prompt.rb` — a lógica que migra intacta e o alvo da caracterização):
```ruby
module AgentRuntime
  class SystemPrompt
    def initialize(base: "", files: [])
      @base = base
      @files = Array(files)
    end

    def build(skills_block: "")
      parts = [@base]
      @files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
      parts << skills_block
      parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
    end
  end
end
```

#### Step 3: `Providers::Skill` — adaptador fino do SkillCatalog

**File:** `lib/harness/context/providers/skill.rb`

```ruby
module Harness
  module Context
    module Providers
      # Adapta o SkillCatalog (RFC-0005 §5): visão CANDIDATA das skills.
      # A LoadSkill do Executor NÃO vem daqui: ela é construída com
      # resolution.allowed_skills (decisão de policy, doc 05 §8), não com a
      # visão candidata do provider.
      class Skill < ContextProvider
        def initialize(catalog:)
          @catalog = catalog
        end

        def call(request)
          skills = @catalog.effective(request.profile.skills)
          block  = @catalog.format_for_prompt(skills)
          return [] if block.empty?

          [ContextFragment.build(content: block, placement: :system,
                                 priority: 80, source: id)]
        end
      end
    end
  end
end
```

Regras (doc 04 §2):
- `catalog.effective(profile.skills)` → `format_for_prompt` → **1 fragmento** `:system`, `priority: 80`. `pinned: false` — L7 fixa a ordem de sacrifício sob pressão de orçamento: histórico antigo → histórico recente → **skills** → (identidade é pinned, nunca).
- `format_for_prompt` vazio (nenhuma skill efetiva) → `[]` — reproduz a Fase 0, onde `SystemPrompt#build` rejeitava o `skills_block` vazio.
- Não reimplementar `effective` nem `format_for_prompt` — o catálogo é intocado (doc 04 §8); o provider é só o adaptador. A ordem constitucional Context→Policy é preservada: o provider produz com a visão **candidata** (`effective`); a policy corta depois (doc 05 §8).

**Reference pattern from codebase** (`docs/harness_handoff/reference-implementation/lib/agent_runtime/skill_catalog.rb` — a interface adaptada):
```ruby
    def effective(skills_policy)
      return all if skills_policy.nil?
      return [] if skills_policy.empty?

      names = Array(skills_policy).map(&:to_s)
      all.select { |s| names.include?(s.name) }
    end

    # Nível 1: lista compacta injetada no system prompt. Só metadados.
    def format_for_prompt(skills = all)
      return "" if skills.empty?
      ...
    end
```

#### Step 4: `Providers::Session` — 3 fontes de transcript, teto 79

**File:** `lib/harness/context/providers/session.rb`

```ruby
module Harness
  module Context
    module Providers
      # Lê o Session Store (D2). Único provider de histórico: as três fontes
      # de transcript convergem aqui (L4) — o Executor não escolhe fonte.
      class Session < ContextProvider
        def initialize(session_store:)
          @session_store = session_store
        end

        def enabled_for?(_profile) = true   # ativo, mas só produz se houver fonte

        def call(request)
          messages = transcript_for(request)
          return [] if messages.nil? || messages.empty?

          messages.each_with_index.map do |msg, idx|
            ContextFragment.build(
              content: { role: msg[:role], content: msg[:content] },
              placement: :history,
              priority: [60 + idx, 79].min,   # teto 79 (L7)
              source: id
            )
          end
        end

        private

        # Precedência (doc 04 §2 / D2):
        #   1. request.checkpoint (retomada — histórico vem dele, doc 02 §3)
        #   2. history explícito do request (D2)
        #   3. Session Store por session_id
        def transcript_for(request)
          return request.checkpoint.messages if request.checkpoint
          # fonte 2: history explícito — ver Notes (convenção com a task 12)
          return explicit_history(request) if explicit_history(request)
          return @session_store.find(request.session.id)&.messages if request.session

          nil
        end
      end
    end
  end
end
```

Regras:
- **Fragmentos `:history`, 1 por mensagem** (doc 04 §2). `content` é o Hash `{role:, content:}` — o mesmo shape que `Runner#seed_history` já consome na Fase 0 (doc 02 §3) e que o Builder despeja em `package.history` (contrato da task 14). `tokens: nil` — o Builder estima (L3; `estimate` faz `to_s`).
- **Prioridade escalonada por recência com TETO** (L7): `min(60 + idx, 79)`, `idx` contado **da mais antiga para a mais recente** (mais antiga = 60). O corte de orçamento descarta as mais antigas primeiro e o histórico NUNCA supera skills (80) nem identidade (100).
- **Precedência das 3 fontes** (doc 04 §2): `request.checkpoint` → history explícito do request → Session Store por `session_id`. A primeira fonte presente vence; não há merge.
- **A existência da sessão já foi validada pelo handler** (doc 03 §3: `NotFoundError` síncrono ANTES do fiber) — aqui a sessão sempre existe; não tratar sessão-inexistente como caso normal.
- Nenhuma fonte → `[]` (turno one-shot sem histórico, D2).
- **Requiredness condicional** (doc 04 §6: "`Session` é required quando `session_id` foi pedido"): `required?` da base não recebe o request, então implementar o equivalente comportamental — quando `request.session` está presente e a leitura do store **falha** (exceção/`StoreError`), deixar a exceção propagar como `ContextError` (levantar `ContextError.new("Session provider falhou com sessão pedida: ...")`); sem sessão pedida, qualquer falha interna resulta em `[]`/warning (degradação). Ver Notes.

#### Step 5: Requires em `lib/harness.rb`

Adicionar os 4 `require_relative` após `context/builder`. Nenhum provider requer `ruby_llm` (doc 04 §7: nenhum arquivo deste doc requer a gem).

### Edge Cases to Handle

1. **`Prompt` com arquivo inexistente em `files`** → silenciosamente pulado (`File.exist?` — comportamento da Fase 0, preservado pela caracterização).
2. **`Prompt` com base vazia e nenhum arquivo legível** → identidade vazia → nenhum fragmento de identidade (o `reject` da Fase 0). Atenção: o perfil ainda pode ter `prompt_refs` (fragmentos 90 saem mesmo assim).
3. **`prompt_refs` com `catalog: nil`** → `ContextError` (config inválida falha alto), não `[]` silencioso.
4. **`prompt_refs` duplicados** → um fragmento por ocorrência, na ordem do perfil (o techspec não pede dedupe; não inventar).
5. **`Skill` com `profile.skills == []`** → `effective` devolve `[]` → `format_for_prompt` devolve `""` → `[]` (nenhum fragmento).
6. **`Session` com transcript de 1 mensagem** → priority 60. **Com 25 mensagens** → 60,61,…,78,79,79,79,… (teto).
7. **`Session` com checkpoint E sessão presentes** (retomada de turno com `session_id`) → checkpoint vence (precedência), sem merge.
8. **Mensagens com chaves string** (`"role"`/`"content"`, vindas de JSON do store) → normalizar para o shape `{role:, content:}` esperado pelo seed (doc 02 §3).
9. **`Request` com `vars` vazio e `tenant` nil** → `[]` — "nada se não houver metadados".

## Testing

Zero RubyLLM / zero API key (doc 04 §7). Fixtures de arquivo em diretório temporário (`Dir.mktmpdir`) ou `spec/fixtures/`.

### Unit Tests

**File:** `spec/harness/context/providers/prompt_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| **caracterização Fase 0** | mesma entrada (`base:` + 2 arquivos, um inexistente) comparada com a saída do algoritmo `SystemPrompt#build` (portado no spec como referência) | `fragment.content` **byte-a-byte igual** a `parts.reject{vazios}.join("\n\n")` — doc 04 §7/§8 |
| identidade pinned 100 | base+files | 1 fragmento `:system`, priority 100, `pinned: true`, source estável |
| identidade vazia | base `""`, sem arquivos | nenhum fragmento de identidade |
| required? | — | `required? == true` |
| prompt_refs resolvidos | perfil com `prompt_refs: %w[a b]`, catálogo duplo | 2 fragmentos priority 90 pinned, ordem do perfil, content = body do catálogo |
| ref inexistente | catálogo sem o nome | `ContextError` |
| refs sem catálogo | `catalog: nil` + perfil com refs | `ContextError` |
| perfil sem refs | `prompt_refs: nil`/`[]` | só o fragmento de identidade |

**File:** `spec/harness/context/providers/skill_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| 1 fragmento priority 80 | catálogo com skills (reusar fixtures de SKILL.md da Fase 0 — doc 04 §7) | `:system`, priority 80, não-pinned, content == `format_for_prompt(effective)` |
| respeita profile.skills | `skills: []` | `[]` (sem fragmento) |
| subconjunto | `skills: [nome]` | bloco só com essa skill |
| não filtra por policy | — | o provider usa `effective` (visão candidata); nenhuma referência a Resolution/allowed_skills |

**File:** `spec/harness/context/providers/session_spec.rb` (com `SessionStore` + `Stores::Memory` reais — doc 04 §7)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| fonte checkpoint | `request.checkpoint` com messages | fragmentos vêm do checkpoint; store não é consultado |
| fonte history explícito | history no request, sem checkpoint | fragmentos vêm do history; store não é consultado |
| fonte session_id | só `request.session` | messages lidas do `SessionStore` |
| nenhuma fonte | request vazio | `[]` |
| precedência | checkpoint + sessão presentes | checkpoint vence |
| escalonamento | 3 mensagens | priorities 60, 61, 62; ordem cronológica preservada |
| teto 79 | 25 mensagens | nenhum fragmento > 79; mais recentes = 79; skills (80) e identidade (100) nunca superadas |
| shape do content | mensagem do store (chaves string) | `content == {role:, content:}` (shape do seed, doc 02 §3) |
| falha com sessão pedida | store que levanta | `ContextError` (required quando session_id foi pedido) |

**File:** `spec/harness/context/providers/request_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| com metadados | tenant + vars | 1 fragmento `:system` priority 40 contendo tenant e vars |
| sem metadados | tenant nil, vars `{}` | `[]` |
| determinismo | mesma entrada 2× | content idêntico |

### Integration Tests (if applicable)

**File:** `spec/harness/context/builder_providers_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| paridade de montagem Fase 0 | Builder (task 14) + `Prompt`+`Skill` reais | `package.system == base+SOUL → skills_block` unidos por `"\n\n"` — reproduz `Prompt(100) → Skill(80)` ≙ saída do wiring da Fase 0 (doc 04 §3) |
| histórico sob orçamento | `Session` com transcript longo + cap apertado | mensagens antigas evictadas primeiro; bloco de skills e identidade intactos (L7) |

## Definition of Done

- [ ] 4 providers com as assinaturas exatas do doc 04 §2 (`Prompt.new(base:, files:, catalog: nil)`, `Skill.new(catalog:)`, `Session.new(session_store:)`)
- [ ] Teste de caracterização do `Prompt` vs `SystemPrompt#build` da Fase 0 passa byte-a-byte (doc 04 §7/§8)
- [ ] `Prompt` required, identidade pinned 100; `prompt_refs` → fragmentos 90 pinned; nome/catálogo ausente → `ContextError`
- [ ] `Skill` = adaptador fino (nenhuma lógica de catálogo duplicada); comentário deixando claro que a LoadSkill NÃO vem daqui
- [ ] `Session` cobre as 3 fontes na precedência checkpoint → history → store; teto 79 (L7); shape `{role:, content:}` do seed
- [ ] Nenhum provider requer `ruby_llm`; suíte roda sem ruby_llm instalado e sem API key
- [ ] `# frozen_string_literal: true` em todos os arquivos; comentários em português
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Lacuna — canal do "history explícito":** `ContextRequest` (doc 04 §2) não tem campo `history`; o doc manda o `Session` provider consumir "history explícito do request (D2)" como fonte 2. Convenção proposta até a task 12 fechar o handler: o handler `SendMessage` repassa o history em `request.vars[:history]` (ou constrói uma `Session` efêmera). Implementar a fonte 2 atrás de um método privado único (`explicit_history(request)`) para trocar a convenção com 1 linha quando a task 12 definir o canal real. Registrado como alinhamento pendente — não é decisão arquitetural desta task.
- **Lacuna — requiredness condicional do `Session`:** `required?` não recebe o request, mas o doc 04 §6 diz "required quando `session_id` foi pedido". A implementação comportamental (levantar `ContextError` só quando há sessão pedida e a leitura falha) satisfaz o contrato sem mudar a interface da base. Se a task 14 já tiver outro mecanismo, seguir o código real.
- **Formato textual do fragmento `Request`:** o techspec fixa placement/priority/condição-de-vazio, não o texto. O formato sugerido no Step 1 é deliberadamente simples e determinístico; qualquer formato equivalente serve, desde que os testes de determinismo passem.
- **`Providers::Prompt` emite a identidade como fragmento único** (base+files concatenados) para preservar a ordem interna e a paridade byte-a-byte — a ordenação canônica da task 14 só ordena ENTRE fragmentos. Os `prompt_refs` são fragmentos separados (priority 90) porque têm prioridade própria no doc.
- **`skill_catalog.rb` da Fase 0** migra para `lib/harness/` inalterado só na Etapa F (doc 00 §4). Se ao implementar esta task ele ainda não existir em `lib/`, use duplo/fixture nos specs do provider — o adaptador só depende da interface `effective`/`format_for_prompt`.
