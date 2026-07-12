# Techspec Fase 2 (fatia B) — Capability Registry + Tool Search

> Segue o mesmo processo das fatias anteriores (HANDOFF-TECHSPEC.md): RFC = "o quê
> e porquê"; este doc + os componentes `P2B-01`–`P2B-02` = "como, exatamente".
> A RFC-0001 é a constituição. Evolui o código das Fases 1 e 2-A
> (`lib/harness/`, `server/`, `config/wiring.rb`), não recomeça.
>
> **Fonte da verdade:** RFC-0004 (Capability Resolution), RFC-0002 §5/§7
> (montagem de tools entre Context e Policy), RFC-0005 §5 (progressive disclosure,
> precedente das skills), BACKLOG "Fase 2 — Avançado".

## Escopo desta fatia

A Fase 2-A entregou a camada de **controle/ciclo-de-vida** (mailbox completa,
aprovação, sessions-como-actors, Control UI de escrita). Esta fatia entrega a
camada de **resolução e exposição de ferramentas ao modelo** — o próximo bloco
coeso do BACKLOG que assenta diretamente sobre stubs já prontos:

**Faz:**
1. **Capability Registry** (RFC-0004, milestone "Fase 2 (entrada)"): um agente
   referencia uma *capability* (`:browse`) em vez de uma tool concreta; o runtime
   resolve **qual** implementação atende, de forma **determinística e auditável**
   (priority → precedência de plugin → disponibilidade), emitindo
   `:capability_resolved`. Empate = erro de configuração, nunca escolha silenciosa.
2. **Ativação de `contracts.capabilities`** no manifesto de plugin: hoje o
   `PluginLoader` **parseia e IGNORA** esse bloco com um warn "reservado (Fase 2)"
   (`plugin/loader.rb:109`). Esta fatia ativa a costura — `register_capability` no
   entry API + wiring no composition root.
3. **Tool Search** (progressive disclosure de tools, análogo às skills — RFC-0005
   §5): tools marcadas como *deferred* não entram no prompt de cara; entram como
   um catálogo compacto (name+description) e uma builtin `tool_search(query)` que
   **promove** as relevantes para o chat vivo sob demanda. Mantém pequeno o
   conjunto de schemas exposto ao modelo quando o registry cresce.

**Não faz (fatias/fases seguintes):** seleção de capability por custo/latência,
fallback em cadeia, capability versionada (`browse@2`) — RFC-0004 §8 "evolução".
Memória cross-session (RFC-0005 §6), tools externas MCP/webhook, bridge de
observabilidade, policies de custo/tenant, Postgres/pgvector. Sem SPA, sem
WebSocket (herdado das fatias anteriores).

## Como esta fatia evolui as Fases 1/2-A (costuras já prontas)

| Costura existente | Onde | O que a fatia B faz |
|---|---|---|
| `warn_reserved`: `contracts.capabilities` "reservado (Fase 2) — ignorado" | `lib/harness/plugin/loader.rb:109` | REMOVE o warn; parseia capabilities; `StagingApi` ganha `register_capability` |
| `Registry` base executável (tools/workflows/policies) | `lib/harness/registry.rb` | `CapabilityRegistry` é **indireção** (não herda — capability não é executável, RFC-0004 §2); resolve PARA entries do Registry |
| `AgentProfile` com allowlists (`tools_allow`, `skills`, `context_providers`, `workflows_allow`, `policies`) | `lib/harness/agent_profile.rb` | + `capabilities` (RFC-0004 §6) e `tools_deferred` (Tool Search); MESMA semântica `nil`/`[]`/`[names]` |
| `policy_request` monta `candidate_tools` das entries SEM filtrar, antes da Policy | `lib/harness/executor.rb:479` | sub-passo de **capability assembly** ANTES do `policy_request` (RFC-0004 §7: Context → Capability → Policy) |
| `configure_chat` adiciona `LoadSkill` como tool de SISTEMA fora da allowlist | `lib/harness/executor.rb:602` | adiciona `ToolSearch` do mesmo jeito; particiona `allowed_tools` em eager vs deferred |
| `SkillCatalog` + `Context::Providers::Skill` (nível 1 = name+description) | `lib/harness/skill_catalog.rb`, `context/providers/skill.rb` | `ToolCatalog` + `Context::Providers::ToolSearch` — adaptadores finos, MESMO padrão |
| `Tools::LoadSkill` (nível 2, carrega corpo sob demanda) | `lib/harness/tools/load_skill.rb` | `Tools::ToolSearch` (promove tool sob demanda) — mesmo padrão, respeita allowlist |
| Catálogo canônico de eventos (D5 Fase 1) | `lib/harness/event.rb`, `00-overview` Fase 1 D5 | + `:capability_resolved`, `:tool_search` (catálogo estendido, não reaberto) |
| Composition root único | `config/wiring.rb` | constrói `CAPABILITY_REGISTRY` + `TOOL_CATALOG`; injeta no `Executor` e no `Loader` |

## Decisões globais desta fatia

### D1 — Capability é INDIREÇÃO, resolve para o Registry (não é executável)
Fiel à RFC-0004 §2 e ao princípio 6 da RFC-0001 (Registry = executável; Catalog =
não). `CapabilityRegistry` **não** herda de `Registry`: ele guarda `Provider`s
(metadados de resolução) e o `resolve` devolve o `impl_name` concreto, que o
`ToolRegistry`/`WorkflowRegistry` então instancia. Zero execução na camada de
capability.

### D2 — Resolução determinística; empate REAL = erro, nunca escolha silenciosa
O algoritmo (RFC-0004 §5, refinado — ver P2B-01 L3/L4) é **puro e cacheável por
`(capability, profile)`** no turno: candidatos → filtro `available?` → descarta
`impl_name ∈ tools_deny` (deny vence) → ordena `priority` desc (`nil` = mais
baixo), desempate por precedência de plugin (RFC-0003 §5). 1 no topo → resolve;
0 → `CapabilityUnavailable`; ≥2 **same-priority-same-plugin** no topo →
`CapabilityAmbiguous` (plugins distintos nunca dão ambíguo — a precedência
resolve). Toda resolução emite `:capability_resolved { capability, chosen,
candidates }`.

### D3 — Resolução é SUB-PASSO da montagem de tools; grant = `profile.capabilities`
Não é estágio novo (RFC-0002 §8; RFC-0004 §7). Roda depois do Context (precisa
saber as capabilities pedidas) e antes da montagem final. **A autorização de usar
uma capability é listá-la em `profile.capabilities`** (opt-in) — a resolução aplica
só `tools_deny` + `available?` + priority/precedência, NÃO a allowlist RAW
`tools_allow` (que governa tools DIRETAS). As tools de capability são **juntadas ao
tool set DEPOIS do estágio 3** (não passam pela `ToolAllowlist`), então uma
`tools_allow` não-nil não as remove; deny e os gates do Envelope (approval) ainda
valem. Pinning por-agente de provider fica p/ evolução (P2B-01 L3). Uma pipeline só.

### D4 — Capability é exposta ao modelo sob NOME ESTÁVEL (o da capability)
RFC-0004 §6: o prompt/skill referencia `browse` de forma consistente,
independentemente de qual browser resolveu. A tool chega ao RubyLLM renomeada via
um decorator fino `Capability::ResolvedTool` (padrão delegator do `ToolEnvelope`,
só troca o `name`). **Ordem de embrulho no `run_pipeline` (não `configure_chat`):
`impl → ResolvedTool → ToolEnvelope`**, entre `instantiate_tools` e `wrap_tools` —
o Envelope já roda no estágio 3. O `ToolEnvelope` passa a chavear
side-effect/approval por `impl_name` (não pelo alias). Sem dupla-exposição: o impl
só aparece sob o nome estável, salvo se listado à parte em `tools_allow`.

### D5 — Tool Search é o análogo tool do progressive disclosure de skills
RFC-0005 §5 já provou o padrão para skills (nível 1 = name+description no system
via **Context Provider**; nível 2 = `load_skill` sob demanda). Tool Search o
replica FIELMENTE para tools: (nível 1) `Context::Providers::ToolSearch` emite o
catálogo compacto dos `profile.tools_deferred` no estágio 2 — **como o Skill
provider usa `profile.skills`, o recorte é conhecido no estágio 2, sem depender da
Policy nem do seam `vars`**; (nível 2) a builtin `tool_search(query)` promove as
relevantes sob demanda. Crucial (RFC-0005): **o Runtime nunca monta prompt** — o
catálogo vem do Provider, o `configure_chat` só CABEIA a tool `tool_search` (como
faz com `load_skill`), nunca injeta texto de prompt. `tools_deferred: nil` =
comportamento da Fase 1. A Policy continua autoritativa: o `tool_search` só promove
`deferred ∩ allowed_tools` (deny vence) — decide QUANDO cabear, **nunca SE**.

### D6 — Promoção mid-loop via `chat.with_tools`, respeitando "RubyLLM First"
`tool_search.execute` roda ENTRE rounds do loop do RubyLLM (é uma tool call).
Recebe um handle do `chat` (como `LoadSkill` recebe o catálogo) e chama
`chat.with_tools(*matches)`; o RubyLLM re-serializa `chat.tools` no próximo round,
tornando as tools promovidas chamáveis **sem** o Executor dirigir o loop.
Determinístico e testável (matcher puro + `chat` fake que registra `with_tools`).
✅ **Verificado contra ruby_llm 1.16.0** (durante o detalhamento da task 9, execução
real da gem): `with_tools` dentro de um `execute` **afeta o round seguinte do mesmo
`ask`** — `@tools` é um Hash mutado e `handle_tool_calls` só chama `complete`
recursivamente após resolver todas as tool_calls do round. A promoção no MESMO turno
vale para esta gem. Fallback (chamável no próximo turno via sessions-como-actors)
fica documentado como plano-B caso a versão da gem mude, mas não é o caminho ativo.

### D7 — Catálogo de eventos estendido, não reaberto arbitrariamente
Novos tipos: `:capability_resolved`, `:tool_search`. Registrados no catálogo
canônico (Fase 1 D5). Falhas de resolução (`CapabilityUnavailable`/`Ambiguous`)
NÃO ganham evento próprio — propagam como erro de estágio `:capability`
(`CapabilityError`), levando a task a `:failed` pelos eventos `:error`/
`:task_failed` já existentes (mesma disciplina da taxonomia D4 da Fase 1).

## Componentes (docs a detalhar)

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `P2B-01-capability-registry.md` | `CapabilityRegistry` + `Provider` + resolução determinística + ativação de `contracts.capabilities` + `AgentProfile.capabilities` + capability assembly no Executor + `ResolvedTool` | 0004 |
| `P2B-02-tool-search.md` | `ToolCatalog` + `Context::Providers::ToolSearch` + `Tools::ToolSearch` (promoção mid-loop) + `AgentProfile.tools_deferred` + partição eager/deferred no Executor | 0005 §5 |

## Plano de tarefas (resumo — detalhe em `tasks/tasks.md`)

Ordem por dependência: registry+resolução (independente) e catálogo de tools
(independente) andam em paralelo; a costura no Executor junta as duas; eventos e
smoke E2E fecham por cima. Ver `tasks/tasks.md`.

## Critério de conclusão da fatia

1. Uma capability `:browse` com **2 providers** de priority distintos resolve para
   o de maior priority; com priority **idêntica** no topo → `CapabilityAmbiguous`
   (turno falha em `:capability`, candidatos listados); provider indisponível
   (`available? == false`) é descartado. Cada resolução bem-sucedida emite
   `:capability_resolved`.
2. Um plugin declara `contracts.capabilities` no manifesto e `register_capability`
   no entry; a capability fica resolvível e exposta ao modelo sob o **nome estável**
   (não o do impl). A Policy (`tools_allow`/`deny`) filtra pelo `impl_name`.
3. Um agente com `tools_deferred` NÃO recebe essas tools no prompt inicial; o
   modelo chama `tool_search("...")`, as tools relevantes são **promovidas** e
   ficam chamáveis; `:tool_search { query, matched }` é emitido. `tools_deferred:
   nil` reproduz o comportamento da Fase 1 (tudo cabeado de cara).
4. Suíte inteira verde sem chave de API (RubyLLM mockado só na integração) — herda
   o critério de testabilidade das fatias anteriores. O matcher de Tool Search e a
   resolução de capability são **puros** (testados sem gem).
