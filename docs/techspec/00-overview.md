# Techspec Fase 1 — Visão Geral e Decisões Globais

> Techspec de implementação da Fase 1 do Harness, gerado a partir do pacote
> `docs/harness_handoff/` conforme o `HANDOFF-TECHSPEC.md`. RFC = "o quê e
> porquê"; este documento e os componentes `01`–`07` = "como, exatamente".
>
> **Fonte da verdade:** os RFCs. A RFC-0001 é a constituição e nada aqui a
> contraria. Referências no formato "RFC-0006 §5".

## Documentos

| Doc | Componente | RFC base |
|-----|-----------|----------|
| `00-overview.md` | decisões globais, tipos compartilhados, plano de tarefas | — |
| `01-persistence-stores.md` | interface `Store` + backends Memory e SQLite | 0006 |
| `02-session-task-checkpoint.md` | stores de domínio + recuperação no boot | 0006 |
| `03-command-bus-executor.md` | Command Bus + Runtime Executor por estágios | 0002 |
| `04-context-builder-providers.md` | Context Builder + Providers com orçamento | 0005 |
| `05-policy-middleware-hooks.md` | Policy Engine, Middleware, Lifecycle Hooks | 0002 |
| `06-registries-plugin-autodiscovery.md` | Registries restantes + autodiscovery por gem | 0003 |
| `07-service-platform.md` | HTTP/SSE formalizado + esqueleto do Control UI | 0007 |

**Fora do escopo (Fase 2 — não especificado aqui):** Actor mailbox completa
(`approval`, `timeout`, `heartbeat`), Capability Resolution (RFC-0004), Tool
Search, memória semântica (RFC-0005 §6), Control UI completo, Artifact/Plugin
Stores, Postgres, lease/lock, retenção/GC.

---

## 1. Decisões globais

Cada decisão em aberto relevante à Fase 1 (handoff §7 e RFCs §Questões em
Aberto) é resolvida aqui e vale para todos os componentes. Formato: **Decisão**
+ **Motivo**.

### D1 — Namespace: `Harness` (placeholder registrado)

**Decisão:** todo código novo da Fase 1 vive sob o módulo `Harness`, em
`lib/harness/`. O código da Fase 0 (`AgentRuntime`) é migrado para `Harness`
conforme cada arquivo é tocado (todos são tocados na Fase 1 — ver §4). O nome
público da gem (RFC-0001 §8: `RubyLLM::Harness` vs nome próprio) permanece
**aberto e não bloqueia**: é um `s/Harness/X/` mecânico antes do primeiro
release público.

**Motivo:** os RFCs já usam `Harness::` em todos os esboços de interface
(RFC-0006 §1, RFC-0005 §2). Adiar o rename final é barato; adiar o namespace
comum não é — a Fase 1 cria ~30 arquivos novos.

### D2 — Stateless com sessão persistida opcional (default da API)

**Decisão:** o núcleo permanece **stateless**; a sessão persistida é **opt-in
por request**. `SendMessage` aceita `session_id` OU `history`, mutuamente
exclusivos:

- `history` presente → comportamento da Fase 0 (caller manda o transcript;
  nada é persistido). Compatibilidade total com o consumidor atual.
- `session_id` presente → o transcript vem do Session Store (via
  `SessionProvider`, doc 04) e o turno é persistido de volta ao final.
- Ambos presentes → `Harness::ValidationError` (não há semântica de merge
  segura; ambiguidade é erro, não escolha silenciosa).
- Nenhum → turno one-shot sem histórico.

**Motivo:** é a recomendação dos RFCs (BACKLOG §Decisões pendentes) e preserva
o contrato que o Agent.Shop já consome. Sessão vira um recurso da plataforma
sem virar obrigação do consumidor.

### D3 — Conjunto mínimo de Commands (RFC-0002 §10.1)

**Decisão:** a Fase 1 define **cinco** Commands, em duas classes de despacho:

| Command | Classe | Efeito |
|---------|--------|--------|
| `CreateSession` | controle | cria `session:<id>` no Session Store |
| `SendMessage` | turno | cria Task + executa a pipeline canônica |
| `TriggerWorkflow` | turno | cria Task + executa um Workflow do Registry |
| `CancelTask` | controle | posta `cancel` na mailbox mínima da Task |
| `ResumeTask` | controle | retoma Task `paused`/`waiting`/interrompida do último checkpoint |

- **Commands de turno** criam uma Task (Actor, fiber Async) e retornam
  `task_id` imediatamente; o resultado flui pelo Event Stream.
- **Commands de controle** agem sobre stores/mailbox e respondem síncrono.

`ApproveAction` fica na Fase 2 (exige mailbox `approval`, RFC-0002 §9).
Consultas (listar sessões, inspecionar task) **não são Commands** — são reads
diretos dos stores expostos pela Service Platform (doc 07); Command é intenção
de mudança, leitura não muda nada.

> **Resolvido por emenda constitucional.** A RFC-0001 §10 recebeu a
> **Emenda 1 (2026-07-06)**: Commands cobrem interações de mutação;
> consultas são leituras da Service Platform sobre os stores, sem passar
> pelo Runtime. Nenhuma pendência — o doc 07 implementa conforme escrito.

**Motivo:** é o menor conjunto que cobre o fluxo do consumidor real
(conversa + cancelamento) e a recuperação no boot (`ResumeTask` é o mesmo
caminho usado pelo recovery, RFC-0006 §4 — um código só para os dois casos).
`TriggerWorkflow` entra porque o Workflow Registry é escopo da Fase 1 e o
custo marginal é um handler.

### D4 — Contrato de erro/timeout por estágio (RFC-0002 §10.3)

**Decisão:** taxonomia única em `lib/harness/errors.rb`; cada estágio tem
regra de propagação e de retomada definida. Regra geral: **erro vira evento,
task tem estado terminal explícito, checkpoint nunca é corrompido** (o último
checkpoint válido sempre permite `ResumeTask`).

```ruby
module Harness
  class Error < StandardError; end

  class ValidationError   < Error; end  # Command malformado → HTTP 422, nenhuma Task criada
  class NotFoundError     < Error; end  # session/task/agente inexistente → HTTP 404
  class PolicyDenied      < Error      # Policy Engine negou → evento :policy_denied, task :failed
    attr_reader :policy, :reason
  end
  class ContextError      < Error      # provider required falhou → task :failed
    attr_reader :provider
  end
  class ProviderError     < Error; end  # RubyLLM esgotou retries → task :failed
  class StoreError        < Error; end  # backend de persistência falhou → task :failed
  class CancelledError    < Error; end  # cancelamento cooperativo → task :cancelled
  class TimeoutError      < Error      # estouro de timeout de estágio
    attr_reader :stage
  end
end
```

Por estágio:

| Estágio | Falha | Timeout (default) | Comportamento |
|---------|-------|-------------------|---------------|
| Command Bus | payload inválido | — | `ValidationError` síncrono; nenhuma Task |
| Context Builder | provider opcional falha/estoura | 5s por provider | **degradação graciosa**: fragmento omitido + evento `:provider_warning`; turno segue |
| Context Builder | provider `required: true` falha | 5s | `ContextError`; task `:failed` |
| Policy Engine | negação | — | `PolicyDenied`; evento `:policy_denied`; task `:failed` (não é retry-ável) |
| Middleware | exceção | — | propaga como falha do turno; task `:failed` |
| RubyLLM | erro de provider | `request_timeout` do RubyLLM (120s) | retry é do RubyLLM (`max_retries: 3`); esgotado → `ProviderError`, task `:failed` |
| Tool Execution | exceção na tool | 60s por tool | capturada e devolvida **ao modelo** como resultado de erro (semântica RubyLLM); não derruba o turno. Estouro → idem, como `TimeoutError` serializado |
| Turno inteiro | — | 300s | `TimeoutError(stage: :turn)`; task `:failed`; checkpoint anterior preservado |
| Persistence | store falha | — | `StoreError`; task `:failed`; evento `:error` (o turno já executou — o erro é reportado, não silenciado) |

**Retomada:** `ResumeTask` sempre reexecuta **do início do último turno
checkpointado** (RFC-0006 §5). Tools não-idempotentes já concluídas constam no
checkpoint e não re-executam (doc 02 §3). **Cancelamento:** cooperativo —
`Async::Task#stop` verificado nas fronteiras de estágio e de turno; nunca no
meio de uma escrita de store (a escrita de checkpoint é atômica via
`transaction`).

Timeouts são configuráveis por perfil de agente (`AgentProfile.limits`, D6) e
implementados com `Async::Task#with_timeout` (nunca `Timeout.timeout` de
stdlib, que é thread-based e viola o modelo Async/Fibers).

**Motivo:** "erro vira evento + estado terminal" é o único contrato compatível
com Response-como-projeção-contínua (RFC-0002 §7): o consumidor já está
ouvindo o stream quando o erro acontece. Degradação graciosa em provider
opcional resolve RFC-0005 §9.4 do jeito mais barato que ainda é auditável.

### D5 — Catálogo canônico de eventos

**Decisão:** o `Event` ganha metadados de correlação e o catálogo é fechado
(novos tipos exigem atualizar esta tabela — é o contrato do wire):

```ruby
module Harness
  Event = Data.define(:type, :data, :meta) do
    # meta: { task_id:, session_id:, seq:, at: }  (seq monotônico por task)
    def to_h = { type:, **data, meta: meta.compact }
  end
end
```

| Tipo | data | Origem |
|------|------|--------|
| `:task_started` | `{ task_id, command }` | Executor |
| `:content` | `{ delta }` | RubyLLM streaming |
| `:skill_activated` | `{ name }` | before_tool_call (load_skill) |
| `:tool_call` | `{ name, arguments }` | before_tool_call |
| `:tool_result` | `{ name, result }` | after_tool_result |
| `:checkpoint_created` | `{ task_id, turn }` | estágio Persistence |
| `:policy_denied` | `{ policy, reason }` | Policy Engine |
| `:provider_warning` | `{ provider, message }` | Context Builder (degradação) |
| `:session_created` | `{ session_id }` | handler CreateSession |
| `:plugin_loaded` | `{ id, tools, skills }` | PluginLoader (boot) |
| `:task_completed` | `{ task_id, content }` | Executor |
| `:task_failed` | `{ task_id, error, message }` | Executor |
| `:task_cancelled` | `{ task_id }` | Executor |
| `:capability_resolved` | `{ capability, chosen, candidates }` | CapabilityRegistry (P2B-01) |
| `:tool_search` | `{ query, matched }` | Tools::ToolSearch (P2B-02) |
| `:memory_written` | `{ kind, key }` | Tools::Remember (P2C) |
| `:done` | `{ content }` | Executor (compat Fase 0) |
| `:error` | `{ message }` | qualquer estágio (compat Fase 0) |

`:done` e `:error` são **mantidos** pelo contrato com o consumidor atual;
`:task_completed`/`:task_failed` são os equivalentes com correlação. Formato
SSE inalterado: `data: {json}\n\n`.

A fatia 2-B (`phase2b/00-overview.md` D7) estendeu este catálogo com
`:capability_resolved` e `:tool_search` — falhas de resolução de capability
NÃO ganham evento próprio, propagam como `CapabilityError` pelos eventos
`:error`/`:task_failed` já existentes.

**Motivo:** o Event Stream é concorrente ao turno (RFC-0002 §7) e alimenta
consumidor e Control UI pelo mesmo canal (RFC-0007 §4) — sem `task_id`/`seq`
não há multiplexação nem replay confiável.

### D6 — Schema canônico do AgentProfile

**Decisão:** consolidar o `AgentProfile` (hoje disperso entre RFCs) como o
único ponto de política por agente. Compatível com o da Fase 0 (novos campos
têm default):

```ruby
module Harness
  AgentProfile = Data.define(
    :id, :model, :provider,           # Fase 0
    :base_prompt, :prompt_files,      # Fase 0
    :tools_allow, :tools_deny,        # Fase 0 — nil=todas(+opt-in), []=∅ p/ allow; deny sempre vence
    :skills,                          # Fase 0 — nil=todas, []=nenhuma, [names]=conjunto final
    :context_providers,               # NOVO — mesma semântica de allowlist (RFC-0005 §4.1)
    :workflows_allow,                 # NOVO — aplicado pela WorkflowAllowlist builtin (doc 05 §2)
    :policies,                        # NOVO — nomes no Policy Registry avaliados no estágio 3
    :prompt_refs,                     # NOVO — nomes do Prompt Catalog somados à identidade (doc 04 §2)
    :limits                           # NOVO — { turn_timeout: 300, tool_timeout: 60,
  )                                   #          provider_timeout: 5, context_budget: 8_000,
end                                   #          max_turns: 25, max_tool_calls: 50 }
```

A semântica de allowlist (`nil`/`[]`/`[names]`) é **a mesma** para tools,
skills, providers e workflows — uma regra só, testada uma vez.

**Motivo:** RFC-0005 §4.1 manda reusar a semântica; centralizar evita a deriva
que o BACKLOG aponta ("Policy Engine (allow/deny) — parcial").

### D7 — Consistência multi-processo: last-write-wins, lease/lock adiado

**Decisão:** Fase 1 assume **um nó** (SQLite WAL, RFC-0006 §6);
last-write-wins. O lease/lock otimista (claim + token + TTL) fica na Fase 2,
mas o Task Store já reserva os campos `claimed_by` e `claim_expires_at` no
schema (doc 02) para não exigir migração depois.

**Motivo:** RFC-0006 §6 já aponta last-write-wins como default suficiente para
"sessão/task de um dono"; pagar o custo do lock sem multi-processo real viola
Reuse First/núcleo pequeno.

### D8 — Estimativa de tokens: heurística barata atrás de interface

**Decisão:** `Harness::TokenEstimator.estimate(text) -> Integer` com
implementação default `(text.length / 4.0).ceil`. A interface permite trocar
por contagem exata (tokenizer real) sem tocar no Builder. Corte de orçamento é
**global por prioridade ascendente** (não por-placement), com `pinned`
incortável (resolve RFC-0005 §9.1 e §9.2).

**Motivo:** a heurística erra ~±15%, o que se absorve com margem no budget;
contagem exata custa uma dependência e latência por turno. Política global é a
mais simples que respeita `priority` — por-placement só se a prática mostrar
starvation.

### D9 — Versões pinadas

**Decisão:** `Gemfile` do núcleo pina:

```ruby
gem "ruby_llm", ">= 1.15"     # before_tool_call/after_tool_result exigem 1.15+
gem "async", "~> 2.0"
gem "falcon", "~> 0.47"       # servidor (apenas em harness-server)
gem "sqlite3", "~> 2.0"       # apenas backend SQLite
gem "rack", "~> 3.0"          # apenas em harness-server
```

`Gemfile.lock` passa a ser commitado. O núcleo (`lib/`) **não** requer
`ruby_llm` em load-time fora dos pontos de integração (Executor, LoadSkill) —
mantém a regra de testabilidade sem RubyLLM (handoff §6).

**Motivo:** o README da Fase 0 ("notas honestas") avisa que os callbacks
quebram silenciosamente em versões antigas; pinagem é a correção de menor
custo.

---

## 2. Tipos compartilhados

Definidos uma vez, usados por todos os docs:

```ruby
module Harness
  # doc 03 — toda interação vira Command (RFC-0001 princípio 5)
  Command = Data.define(:type, :payload, :meta)
  #   type:    Symbol (:create_session, :send_message, :trigger_workflow,
  #                    :cancel_task, :resume_task)
  #   payload: Hash validado pelo handler (schemas no doc 03)
  #   meta:    { command_id:, tenant:, transport:, issued_at: }

  # D5 — evento com correlação
  Event = Data.define(:type, :data, :meta)

  # doc 04 — RFC-0005 §2 (inalterado do RFC, com :pinned)
  ContextFragment = Data.define(:content, :placement, :priority, :tokens,
                                :source, :pinned)

  # doc 02 — snapshot por turno (RFC-0006 §5)
  Checkpoint = Data.define(:task_id, :turn, :session_id, :agent_id,
                           :messages, :completed_side_effects, :created_at)
end
```

## 3. Layout de diretórios (alvo da Fase 1)

```
lib/harness.rb                       # requires; zero side-effects
lib/harness/errors.rb                # D4
lib/harness/event.rb                 # evolui event.rb (D5)
lib/harness/agent_profile.rb         # evolui agent_profile.rb (D6)
lib/harness/token_estimator.rb       # D8
lib/harness/store.rb                 # doc 01 — interface + contrato
lib/harness/stores/{memory,sqlite}.rb
lib/harness/{session,task,checkpoint}_store.rb   # doc 02 — domínio
lib/harness/recovery.rb              # doc 02 — boot recovery
lib/harness/command.rb               # doc 03
lib/harness/command_bus.rb
lib/harness/commands/*.rb            # um handler por Command
lib/harness/executor.rb              # doc 03 — evolui runner.rb
lib/harness/event_stream.rb          # doc 03 — pub/sub in-process
lib/harness/task_actor.rb            # doc 03 — fiber + mailbox mínima
lib/harness/context/{fragment,provider,builder}.rb   # doc 04
lib/harness/context/providers/{request,session,skill,prompt}.rb
lib/harness/policy/{engine,policy}.rb                # doc 05
lib/harness/{middleware,hooks}.rb                    # doc 05
lib/harness/registry.rb              # doc 06 — genérico
lib/harness/{tool,workflow,policy}_registry.rb
lib/harness/prompt_catalog.rb        # Catalog, não Registry (RFC-0001 princípio 6)
lib/harness/skill_catalog.rb         # migra da Fase 0 (inalterado)
lib/harness/plugin/loader.rb         # doc 06 — evolui plugin_loader.rb
lib/harness/tools/load_skill.rb      # migra da Fase 0
server/app.rb, server/admin/*        # doc 07 — evolui app/server.rb
config/wiring.rb                     # composition root (evolui)
spec/                                # doc por doc, ver §Testes de cada um
```

## 4. Mapa de evolução da Fase 0 (handoff §4.8, consolidado)

| Fase 0 (`agent_runtime`) | Destino Fase 1 | Como |
|--------------------------|----------------|------|
| `event.rb` | `harness/event.rb` | estende com `meta` (D5); `to_h` compatível |
| `agent_profile.rb` | `harness/agent_profile.rb` | estende com 4 campos novos (D6) |
| `tool_registry.rb` | `harness/tool_registry.rb` | migra; `resolve` vira input do Policy Engine (doc 05) |
| `skill_catalog.rb` | `harness/skill_catalog.rb` | migra sem mudança de lógica |
| `tools/load_skill.rb` | `harness/tools/load_skill.rb` | migra sem mudança de lógica |
| `plugin_loader.rb` | `harness/plugin/loader.rb` | estende: manifesto `harness.plugin.yml`, autodiscovery por gem, registro de providers/middleware (doc 06) |
| `system_prompt.rb` | **substituído** por `context/providers/prompt.rb` | vira o PromptProvider; `SOUL.md`/base viram fragmentos `pinned` (doc 04) |
| `runner.rb` | **substituído** por `executor.rb` + pipeline | a lógica RubyLLM (build_chat/callbacks/seed) migra intacta para o estágio 6-7; o entorno vira estágios (doc 03) |
| `app/server.rb` | `server/app.rb` | rotas formais + tradução request→Command (doc 07) |
| `config/wiring.rb` | `config/wiring.rb` | ganha stores, bus, builder, engine (composition root continua único) |

Nada da Fase 0 é jogado fora; `runner.rb` e `system_prompt.rb` são os únicos
substituídos, e suas lógicas migram para dentro dos novos componentes.

## 5. Restrições inegociáveis (handoff §5 — checklist de revisão)

Cada doc de componente declara conformidade; a revisão final verifica:

1. **RubyLLM First** — chat/streaming/tool-loop/retries nunca reimplementados.
2. **Uma única pipeline** — Commands de turno passam TODOS pela mesma sequência de estágios.
3. **Ruby puro no núcleo** — sem Rails/ActiveSupport em `lib/`.
4. **Sem job runner externo** — durabilidade = stores + recovery no boot.
5. **Async/Fibers, sem threads** — `Async` em todo fan-out; `sqlite3` é a única exceção controlada (doc 01 §5).
6. **Catalog ↔ Registry** — skills/prompts em Catalogs; tools/workflows/policies em Registries.
7. **Convention over Configuration** — SKILL.md/AgentSkills intocado.
8. **Context fora do Runtime** — Executor recebe o pacote pronto do Builder.
9. **Middleware modifica, Hooks alteram, Events observam** — doc 05 §1 define a fronteira formal.

## 6. Plano de implementação (ordenado, handoff §8)

Ordem de dependência do handoff §3. Cada tarefa é um PR pequeno e testável.

**Etapa A — Fundação (doc 01)**
1. `harness/errors.rb` + `harness/event.rb` + `harness/agent_profile.rb` (D4/D5/D6) — migração dos tipos da Fase 0
2. Interface `Harness::Store` + suíte de contrato compartilhada (RSpec shared examples)
3. Backend `Stores::Memory` (passa a suíte)
4. Backend `Stores::SQLite` (WAL, mesma suíte)

**Etapa B — Domínio persistente (doc 02)**
5. `SessionStore` (schema `session:<id>`)
6. `TaskStore` (schema `task:<id>`, enum de status, Executions)
7. `CheckpointStore` (schema `checkpoint:<task>:turn:<n>`, side-effects não-idempotentes)
8. `Recovery` — varredura no boot + retomada via caminho do `ResumeTask`

**Etapa C — Pipeline (doc 03)**
9. `Command` + `CommandBus` + handlers de controle (`CreateSession`, `CancelTask`)
10. `Executor` esqueleto: Task como fiber Async, mailbox mínima (`cancel`, `user_message`), estados
11. Migração do `runner.rb` para os estágios 6-7 do Executor (RubyLLM intacto)
12. Handler `SendMessage` end-to-end (com providers stub) + checkpoint por turno
13. `ResumeTask` + integração com Recovery

**Etapa D — Contexto (doc 04)**
14. `ContextFragment`/`ContextProvider`/`TokenEstimator` + `Builder` (fan-out Async, orçamento, pinned)
15. Providers: `Request`, `Prompt` (absorve SystemPrompt/SOUL.md), `Skill` (adapta SkillCatalog), `Session` (lê SessionStore)
16. Hooks `before_prompt`/`after_prompt` no Builder

**Etapa E — Política e extensão da execução (doc 05)**
17. `Policy::Engine` + Policy Registry + policies builtin (tool/skill allow-deny — absorve o `resolve` do ToolRegistry)
18. `Middleware` pipeline (interface Rack-like) 
19. Hooks restantes (`before/after_task`, `before/after_agent`, `before/after_tool`)

**Etapa F — Registries e plugins (doc 06)**
20. `Registry` genérico + Workflow/Policy Registries + Prompt Catalog
21. PluginLoader: manifesto `harness.plugin.yml`, contratos de workflow, registro de middleware/hooks/providers
22. Autodiscovery por gem (boot hook estilo Railtie)
23. Handler `TriggerWorkflow`

**Etapa G — Serviço (doc 07)**
24. Rotas formais: POST Commands, GET reads, `/events` SSE
25. Esqueleto do Control UI (`/admin`: Sessions, Tasks, Events ao vivo — read-only na Fase 1)
26. `Gemfile` final pinado + Gemfile.lock + smoke test de boot (Falcon)

Critério de conclusão da fase: fluxo `SendMessage` com `session_id` sobrevive
a `kill -9` + reboot retomando do checkpoint; suíte inteira verde sem chave de
API (RubyLLM mockado apenas nos testes de integração do Executor).
