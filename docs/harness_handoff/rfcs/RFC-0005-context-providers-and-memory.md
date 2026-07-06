---
rfc: "0005"
title: Context Providers & Memory
status: Draft
type: Componente
created: 2026-07-05
supersedes: []
depends_on: ["0001", "0002", "0006"]
---

# RFC-0005 — Context Providers & Memory

> Detalha o **Context Builder** (estágio 2 da pipeline, RFC-0002) e a integração
> de memória. Regra constitucional: o Runtime nunca monta prompt — contexto é
> exclusivo desta plataforma.

## 1. Modelo

Todo contexto é produzido por **Context Providers** plugáveis. O **Context
Builder** agrega os providers habilitados para o agente/turno num pacote de
contexto, respeitando orçamento de tokens. Substitui a montagem monolítica de
system prompt por uma pipeline extensível.

## 2. Context Provider — contrato

```ruby
module Harness
  # Um provider produz zero ou mais fragmentos para um turno.
  class ContextProvider
    # request: { session:, message:, profile:, tenant:, vars: }
    def call(request) = []          # -> [ContextFragment]
    def enabled_for?(profile) = true
  end

  ContextFragment = Data.define(:content, :placement, :priority, :tokens, :source) do
    # placement: :system | :history | :tool_context
    # priority:  maior = mais importante (sobrevive a cortes)
    # tokens:    estimativa p/ orçamento
    # source:    id do provider (auditoria)
  end
end
```

Providers podem ser síncronos ou fazer IO; o Builder roda os independentes em
**fan-out Async** (RFC-0001 concorrência).

## 3. Providers previstos

| Provider   | Produz                                                        |
|------------|--------------------------------------------------------------|
| Request    | dados do turno atual (mensagem, metadados do request)        |
| Session    | histórico/transcript da sessão (do Session Store, RFC-0006)  |
| Skill      | lista nível-1 do Skill Catalog (name+description) — §5       |
| Prompt     | template base / identidade (SOUL.md equivalente)             |
| Memory     | recuperação cross-session relevante — §6                     |
| Workspace  | estado do workspace/tenant (config, catálogo de produtos…)   |
| Plugin     | contexto injetado por plugins habilitados                    |
| Artifact   | referências a artefatos anexados à sessão (Artifact Store)   |

## 4. Context Builder — algoritmo

Dado o turno:

1. **Seleção.** Reúne providers habilitados para o `profile` (allowlist por
   agente, mesma semântica de tools/skills: `nil`=todos, `[]`=nenhum,
   `[names]`=subconjunto).
2. **Produção.** Executa os providers (fan-out Async para os independentes),
   coletando fragmentos.
3. **Agrupamento.** Agrupa por `placement` (system / history / tool_context).
4. **Orçamento.** Se a soma de `tokens` excede o cap do turno, corta por
   `priority` ascendente (evicção do menos importante) até caber. Providers
   marcam fragmentos como `pinned` quando não podem ser cortados (ex.: identidade).
5. **Montagem.** Concatena por placement na ordem canônica; o resultado alimenta
   o `with_instructions` / mensagens do RubyLLM.

Envolto por `before_prompt`/`after_prompt` (Hooks, RFC-0002 §6), que podem
reescrever o pacote antes de seguir.

## 5. Skill Provider (já maduro)

Convenção **AgentSkills / SKILL.md**, progressive disclosure em 3 níveis:
(1) discovery — name+description no fragmento system; (2) activation — a tool
`load_skill` carrega o corpo sob demanda; (3) reference — `scripts/`/`references/`
sob demanda. Precedência de roots: workspace > managed > plugin. Allowlist por
agente aplicada aqui e no `load_skill`. **Implementado e testado** no
`agent_runtime`.

## 6. Memory Integration

Memória cross-session escopada por tenant, exposta como Context Provider.

### 6.1 Camadas
- **Profile** — fatos estáveis do usuário/tenant (chave-valor).
- **Notes** — anotações livres acumuladas.
- **Semantic** — trechos indexados por embedding para recuperação por similaridade.

### 6.2 Read path
No turno, o Memory Provider recupera:
- Profile/Notes relevantes (por chave/escopo);
- top-k trechos semânticos acima de um `threshold` de similaridade (default ~0.70,
  configurável), respeitando um sub-orçamento de tokens.

### 6.3 Write path
Após o turno (fora do caminho crítico, como task Async), um extrator decide o que
persistir: atualização de profile, novas notes, novos trechos indexados. Idempotente.

### 6.4 Backends
Standalone: SQLite + índice vetorial embutido. Escala: plugin
`harness-postgres`/pgvector. Persistência via Stores (RFC-0006); o provider não
conhece o backend.

## 7. Skill Workshop (fase 2)

Auto-geração de skill: uma skill/tool que detecta padrões repetidos e **propõe**
novos `SKILL.md` num diretório de proposta (`skills/_proposed/`) para **revisão
humana** — nunca ativa direto. É o mecanismo que faz a plataforma melhorar com o
uso, mantendo o humano no loop.

## 8. Estado atual & pendências

- **Feito:** Skill Provider (SkillCatalog + progressive disclosure); montagem base
  (evolui do `system_prompt.rb` para o Context Builder).
- **Fase 1:** interface de ContextProvider; Builder com fan-out e orçamento;
  Session/Request/Prompt providers; habilitação por agente.
- **Fase 2:** Memory (read/write, camadas, semantic); Workspace/Artifact/Plugin
  providers; Skill Workshop.

## 9. Questões em Aberto

1. Quem corta quando o orçamento estoura — política global vs por-placement.
2. Estimativa de tokens: heurística barata vs contagem exata (custo).
3. Extração de memória: por LLM (caro/preciso) vs regras (barato/limitado).
4. Providers síncronos vs assíncronos: timeout e degradação graciosa quando um
   provider lento não responde.
