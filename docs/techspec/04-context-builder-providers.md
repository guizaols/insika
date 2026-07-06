# Techspec 04 — Context Builder + Context Providers

> Implementa RFC-0005 §1–§5 (Builder, contrato de provider, providers da Fase
> 1). Memória (§6) e Skill Workshop (§7) são Fase 2. Evolui o
> `system_prompt.rb` da Fase 0 para providers plugáveis com orçamento de
> tokens. Regra constitucional: o Runtime nunca monta prompt.

## 1. Objetivo e fronteira

**Faz:** contrato `ContextProvider` + `ContextFragment`; `ContextBuilder` com
seleção por perfil, fan-out Async, agrupamento por placement, orçamento de
tokens com evicção por prioridade e `pinned`; os quatro providers da Fase 1 —
`Request`, `Prompt`, `Skill`, `Session`; hooks `before/after_prompt`.

**Não faz:** Memory/Workspace/Plugin/Artifact providers (Fase 2, RFC-0005 §8);
decidir o que o agente pode usar (Policy, doc 05 — o Builder informa, não
autoriza); chamar o modelo.

## 2. Interfaces públicas

```ruby
module Harness
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned) do
    # placement: :system | :history | :tool_context   (RFC-0005 §2)
    # priority:  Integer; maior = mais importante (sobrevive a cortes)
    # tokens:    Integer; estimado com TokenEstimator se o provider não informar
    # source:    String — id do provider (auditoria)
    # pinned:    true → incortável no orçamento (ex.: identidade)
    def self.build(content:, placement:, priority: 50, tokens: nil,
                   source:, pinned: false)
  end

  class ContextProvider              # classe base (RFC-0005 §2)
    def id = self.class.name         # override para nome estável
    def required? = false            # true → falha aborta o turno (D4)
    def enabled_for?(profile) = true
    def call(request) = []           # -> [ContextFragment]
    # request: ContextRequest (abaixo). Pode fazer IO (roda em fiber próprio).
  end

  ContextRequest = Data.define(:session, :history, :message, :profile,
                               :tenant, :vars, :checkpoint)
  # session:    SessionStore::Session | nil (D2 — handler já validou existência)
  # history:    [{role:, content:}] | nil (D2 — history explícito do request;
  #             XOR com session, garantido pelo handler)
  # checkpoint: Checkpoint | nil (presente em ResumeTask — histórico vem dele)

  ContextPackage = Data.define(:system, :history, :tool_context,
                               :fragments, :budget) do
    # system:       String (concatenação final p/ with_instructions)
    # history:      [{role:, content:}] (p/ seed do chat)
    # tool_context: String | nil
    # fragments:    [ContextFragment] pós-corte (auditoria)
    # budget:       { cap:, used:, evicted: [source] }
  end

  class ContextBuilder
    def initialize(providers:, hooks:, event_stream:,
                   estimator: TokenEstimator)
    def call(request)                # -> ContextPackage
  end

  module TokenEstimator              # D8
    def self.estimate(text) = (text.to_s.length / 4.0).ceil
  end
end
```

### Providers da Fase 1

```ruby
module Harness::Context::Providers
  class Request < ContextProvider
    # Fragmento :system com metadados do turno (tenant, vars relevantes) +
    # nada se não houver metadados. priority: 40.
  end

  class Prompt < ContextProvider     # absorve SystemPrompt + SOUL.md (Fase 0)
    def initialize(base: "", files: [], catalog: nil)
    # Fragmentos :system PINNED, priority: 100 — identidade nunca é cortada
    # (RFC-0005 §4.4). Mesma leitura de arquivos do SystemPrompt#build.
    # catalog: PromptCatalog (doc 06) — se o perfil tem prompt_refs (D6),
    # resolve cada nome no catálogo e soma como fragmento :system priority
    # 90, pinned. Nome inexistente → ContextError (config inválida falha alto).
    def required? = true
  end

  class Skill < ContextProvider      # adapta o SkillCatalog (RFC-0005 §5)
    def initialize(catalog:)
    # catalog.effective(profile.skills) → format_for_prompt → 1 fragmento
    # :system, priority: 80. A LoadSkill do Executor NÃO vem daqui: ela é
    # construída com resolution.allowed_skills (decisão de policy, doc 05 §8),
    # não com a visão candidata do provider.
  end

  class Session < ContextProvider    # lê o Session Store (D2)
    def initialize(session_store:)
    def enabled_for?(profile) = true # ativo, mas só produz se houver sessão
    # Fragmentos :history (1 por mensagem), prioridade escalonada por
    # recência com TETO: min(60 + idx_da_mais_antiga_para_recente, 79) —
    # o corte de orçamento descarta as mais antigas primeiro e o histórico
    # NUNCA supera skills (80) nem identidade (100); ver L7. Fonte do
    # transcript, em ordem de precedência: request.checkpoint (retomada,
    # doc 02 §3) → history explícito do request (D2) → Session Store por
    # session_id. A existência da sessão já foi validada pelo handler
    # (doc 03 §3, NotFoundError síncrono) — aqui a sessão sempre existe.
  end
end
```

## 3. Modelos de dados / schemas

- `ContextFragment`/`ContextPackage`/`ContextRequest`: acima (Data, imutáveis).
- Ordem canônica de montagem do `system` (L2): fragmentos `:system` ordenados
  por `priority` **descendente**, empate por `source` alfabético
  (determinismo — handoff §6), concatenados com `\n\n`. Reproduz a saída da
  Fase 0: Prompt(100) → Skill(80) → Request(40) ≙ base+SOUL → skills_block.
- `:history`: ordenado cronologicamente (a prioridade só decide **corte**,
  nunca reordena mensagens).
- `budget.cap` = `profile.limits.context_budget` (default 8_000 tokens, D6).

## 4. Fluxo de controle

Estágio 2 da pipeline (doc 03 §4), envolto por `before/after_prompt`:

```
executor ─► hooks.around(:prompt, request) do
              builder.call(request)
                1. seleção   providers.select { enabled_for?(profile) &&
                             allowlist(profile.context_providers) }   # semântica nil/[]/[names] (D6)
                2. produção  fan-out Async: cada provider em fiber filho,
                             with_timeout(profile.limits.provider_timeout)
                3. coleta    fragments (tokens ||= estimator.estimate(content))
                4. agrupamento por placement
                5. orçamento soma > cap? → evicção global por priority ASC,
                             pulando pinned, até caber (D8). Registra evicted.
                6. montagem  ContextPackage (ordem canônica §3)
            end
          ─► after_prompt pode reescrever o pacote (RFC-0005 §4)
```

O pacote alimenta `chat.with_instructions(package.system)` e o seed de
histórico no estágio 5-6 (doc 03). O Builder **não** conhece RubyLLM.

## 5. Concorrência

- Fan-out com `Async do ... end.wait` por provider (barrier: o Builder precisa
  de todos — é a exceção legítima de barreira; um provider lento é limitado
  pelo timeout, não pelos irmãos).
- Providers são fibers **filhos do fiber da task**: cancelar a task cancela
  produção de contexto em voo.
- Providers não compartilham estado mutável; cada um recebe o `ContextRequest`
  imutável.
- `provider_timeout` default 5s (D4) via `Async::Task#with_timeout` por fiber
  de provider.

## 6. Erros e timeouts

Aplicação do D4, linha "Context Builder":

- Provider **opcional** falha ou estoura timeout → fragmentos dele são
  omitidos, evento `:provider_warning { provider:, message: }`, turno segue
  (degradação graciosa — resolve RFC-0005 §9.4).
- Provider **`required?`** falha → `ContextError(provider:)` → task `:failed`.
  `Prompt` é required (agente sem identidade é um agente errado, não um
  agente degradado); `Session` é required quando `session_id` foi pedido.
- Orçamento insolúvel (só `pinned` já excede o cap) → `ContextError` com
  mensagem explícita — configuração inválida deve falhar alto, não truncar
  identidade.
- Evicção **não é erro**: registrada em `budget.evicted` + um
  `:provider_warning` agregado quando algo foi cortado.

## 7. Estratégia de testes

- **Builder puro** (sem IO): providers fake devolvendo fragmentos
  roteirizados. Casos: seleção por allowlist (nil/[]/[names] — mesma tabela
  de casos da semântica de tools); agrupamento; ordem canônica determinística
  (empate de priority → source alfabético, handoff §6); orçamento — corta o
  menor priority primeiro, nunca corta pinned, para exatamente quando cabe;
  pinned-only estourando → `ContextError`.
- **Timeout/degradação:** provider fake que dorme (via `Async::Task#sleep`) >
  timeout → warning + turno segue; required lento → `ContextError`.
- **Providers reais:** `Prompt` (base+arquivos, paridade byte-a-byte com
  `SystemPrompt#build` da Fase 0 — teste de caracterização antes de deletar);
  `Skill` (reusa fixtures de SKILL.md da Fase 0); `Session` (com
  SessionStore+Memory; casos history-explícito, session_id, checkpoint,
  nenhum).
- Zero RubyLLM / zero API key (nenhum arquivo deste doc requer a gem).

## 8. Evolução a partir da Fase 0

- `system_prompt.rb` → **substituído** por `Providers::Prompt`. A concatenação
  base+files migra intacta; o `skills_block` deixa de ser parâmetro (vira o
  fragmento do `Providers::Skill`). Teste de caracterização garante saída
  idêntica para o wiring atual antes da remoção.
- `skill_catalog.rb` → intocado; `Providers::Skill` é um adaptador fino sobre
  `effective`/`format_for_prompt`.
- `config/wiring.rb` → `SYSTEM_PROMPT` vira
  `Providers::Prompt.new(files: [SOUL.md])`; Builder montado com os 4
  providers.

## 9. Decisões locais

| # | Decisão | Motivo |
|---|---------|--------|
| L1 | Corte global por priority ASC (não por-placement) | D8; a política mais simples que respeita prioridade. `:history` recebe priorities escalonadas por recência, então o corte global naturalmente poda o histórico antigo primeiro — o efeito por-placement desejado sem uma segunda política |
| L2 | Ordem do system por priority DESC + source alfabético | determinismo exigido pelo handoff §6; reproduz a ordem da Fase 0 sem hard-code de nomes |
| L3 | `tokens` calculado pelo Builder quando o provider não informa | provider simples não deveria conhecer tokenização; quem tem o estimator é o Builder (D8) |
| L4 | `Session` provider único para history/session_id/checkpoint | as três fontes de transcript (D2) convergem num só lugar; o Executor não escolhe fonte de histórico (Context fora do Runtime) |
| L5 | `required?` no provider, não no wiring | quem sabe se pode degradar é o próprio provider (identidade não; metadados sim); o wiring não repete a decisão |
| L6 | Barrier no fan-out (não pipeline) | o orçamento precisa de TODOS os fragmentos antes de cortar — dependência cross-item real |
| L7 | Teto 79 na prioridade do histórico | sem o teto, sessões longas (>20 msgs) fariam o histórico recente evictar o bloco de skills (80) e, >40, disputar com a identidade; a ordem de sacrifício sob pressão de orçamento é fixa por design: histórico antigo → histórico recente → skills → (identidade é pinned, nunca) |
