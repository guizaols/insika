# Techspec Fase 5 — Tools sem código + fechamento de dívidas de wiring

> **Autor:** Claude (AI-generated, pendente de revisão humana)
> **Criado:** 2026-07-12
> **Status:** Proposto — Fase 4 (Studio, 20/20) e o cleanup DHH (PR #35) mergeados. `main` limpa @ `7cb5ab3`.
> **Base:** main @ `7cb5ab3` (pós-Fase-4 + pós-DHH-review).
> **Fonte da verdade:** open questions §9 da spec da Fase 4 (`../phase4-studio/00-overview.md`).
> Referência de produto: o "tool builder" do agent-studio (definir integração sem
> escrever código) + a paridade A2A que ficou pendente.

---

> **Decisão de escopo (2026-07-12):** a Fase 5 tem **um headline** — *tools definidas
> por dados* (§9.1), a última capacidade de "produto" que faltava do agent-studio: o
> operador cria uma tool (uma chamada HTTP a uma API externa) **pela UI, sem Ruby**.
> Junto, fechamos **duas dívidas de wiring baratas e adjacentes**: A2A/AgentCard lendo
> `PROFILE_SOURCE` em vez do `PROFILES` estático (§9.6) e o *delete* de LLM provider
> desfazendo a config em runtime (§9.5, resíduo). **Adiados explicitamente:**
> multi-tenancy real (§9.2, evolução grande) e o render "WhatsApp" de `/chats`
> (§9.4, acoplado ao domínio Tedi — vira plugin quando/se necessário).

## 1. Contexto & Objetivo

Depois da Fase 4, o Studio autora **quase tudo** de um agente pela UI: identidade,
prompts, skills, memória, settings, providers de LLM, MCP, system-files, e o
**allow/deny de tools por agente**. Mas as tools em si **continuam sendo código
Ruby**: para dar uma capacidade nova a um agente (ex.: "consultar o CEP", "criar
ticket no Freshdesk", "buscar estoque na API da loja"), é preciso escrever uma
classe `RubyLLM::Tool`, registrá-la num composition root e reiniciar. Isso quebra a
promessa da Fase 4 (`clone → chave → ruby serve` e opera tudo pela UI): a última
milha — **integrar com um sistema externo** — ainda exige um dev e um deploy.

**Objetivo:** permitir que o operador **defina uma tool por dados** — nome,
descrição, parâmetros e uma **chamada HTTP** (método, URL, headers, corpo,
extração da resposta) — **pela UI**, e ela fica imediatamente disponível para os
agentes (via o mesmo allow/deny que já existe), **sem reiniciar** e **sem código**.
É o análogo do "custom tool / webhook action" dos builders de agente comerciais.

**Objetivo secundário (dívida):** deixar o caminho A2A (inbound + AgentCard)
enxergar os agentes criados pelo Studio, fechando a §9.6; e fazer o *delete* de
provider LLM desfazer a config global em runtime, fechando a §9.5.

### Por que agora, e por que é barato

O mapeamento do código (2026-07-12) mostrou que a fundação da Fase 4 já paga quase
todo o custo:

- **A registry guarda *factories*, não classes** (`lib/harness/registry.rb:11,20,37`).
  Os consumidores (catálogo, JSON Schema para o modelo, allow/deny, envelope) são
  **duck-typed** sobre `name`/`description`/`parameters`/`params_schema`/`execute`.
  Já existe **uma tool que é "uma classe, N instâncias parametrizadas por config"**:
  `A2ARemote` (`lib/harness/tools/a2a_remote.rb:11-32`) — `name`/`description`
  por-instância, comportamento por-instância via deps injetadas. Uma tool definida
  por dados é **exatamente esse padrão**, generalizado para HTTP arbitrário.
- **Timeout, aprovação, side-effect/checkpoint e allow/deny por agente vêm de graça**
  do `ToolEnvelope` (`lib/harness/tool_envelope.rb:35-59`) e das policies
  `ToolAllowlist`/`ApprovalRequired` (`lib/harness/policy/policy.rb:50-63,93-98`).
  Uma data-tool nova **não precisa** de nenhum mecanismo novo de exposição por
  agente — o nome dela já flui por `tools_allow`/`tools_deny`/`approvals_required`
  no `AgentProfile`.
- **O padrão de "store versionado + overlay com `reload`" já existe** para skills
  (D3 da Fase 4: `SkillStore` + `SkillCatalog.reload`) e o mascaramento de segredo
  já existe (`SecretMasking`, sentinel `__OCULTO__`). Data-tools reusam ambos.

O único **gap real de arquitetura** é que a `ToolRegistry` é "imutável pós-boot por
construção" (`lib/harness/registry.rb:8-9`). Registrar/remover uma tool em runtime
exige uma costura nova — resolvida com o **mesmo overlay store-backed dos skills**
(ver D2).

---

## 2. Requisitos

### Funcionais

- **F1 — Definir tool por dados:** criar/editar/deletar uma tool pela UI com: `name`
  (identificador para o modelo), `description`, lista de `parameters`
  (`name`, `type`, `description`, `required`) e uma **ação HTTP** (`method`,
  `url` com template, `headers`, `query`, `body` com template, `timeout`,
  `side_effect`).
- **F2 — Templating de parâmetros:** os valores que o modelo passa entram na URL,
  query, headers e body por interpolação segura (`{{param}}`), com escaping por
  contexto (URL-encode em query/path, JSON em body).
- **F3 — Extração da resposta:** a data-tool devolve ao modelo um resultado
  derivado da resposta HTTP (corpo cru, um caminho `a.b.c` do JSON, ou um subset),
  não o envelope HTTP inteiro. Erros HTTP viram `{ error: ... }` (contrato dos tools
  atuais).
- **F4 — Segredos mascarados:** headers com credencial (ex.: `Authorization: Bearer …`)
  são persistidos e nunca vazam à UI — mesma mecânica `SecretMasking`/`__OCULTO__`
  dos providers LLM/MCP.
- **F5 — Disponibilidade sem restart:** ao salvar, a tool passa a existir para o
  próximo turno de qualquer agente cujo allow/deny a inclua — **sem reiniciar**
  (paridade com skills, não com MCP).
- **F6 — Exposição por agente:** a matriz `/tools` existente passa a listar
  data-tools junto das tools de código; `:set_agent_tools` continua o único
  mecanismo de allow/deny (nada novo).
- **F7 — Versionamento:** editar uma data-tool guarda histórico e permite restaurar
  (paridade com `SkillStore`/`SystemFileStore`).
- **F8 — A2A por ProfileSource (§9.6):** o AgentCard e o inbound A2A passam a
  resolver agentes via `PROFILE_SOURCE`, enxergando agentes criados no Studio.
- **F9 — Delete de LLM provider desfaz runtime (§9.5):** deletar um provider remove
  a config global em runtime quando o RubyLLM permite, senão sinaliza restart.

### Não-Funcionais

- **NF1 — Core intacto:** nenhuma regressão na pipeline de turno. Store de data-tools
  vazio ⇒ comportamento **byte-a-byte idêntico** ao de hoje (spec de paridade).
- **NF2 — Segurança de saída (SSRF/egress):** uma data-tool faz requisição HTTP a
  partir do servidor. Precisa de **guarda de host** (allowlist/denylist de destinos,
  bloqueio de IPs privados/metadata `169.254.169.254`, só `https` por padrão),
  timeout obrigatório (via `ToolEnvelope`) e limite de tamanho de resposta.
- **NF3 — Segredo nunca em log nem no schema:** headers-credencial mascarados na UI,
  na auditoria e em qualquer `to_h`. O valor real só sai para o cliente HTTP no
  momento da chamada.
- **NF4 — CSP/CSRF preservados:** UI segue as regras da Fase 4 (sem JS/CSS inline,
  `check_csrf!` em todo POST, matriz = card+checkbox).
- **NF5 — Side-effect correto:** data-tool não-idempotente (`POST/PUT/PATCH/DELETE`
  por padrão) marca `side_effect: true` ⇒ checkpoint/skip-on-resume via envelope.
- **NF6 — Determinismo de testes:** cliente HTTP injetável (dublê nos specs); nenhum
  teste bate rede real.

---

## 3. Estado atual — o que reusa vs. o que falta

### Já existe e é reusável

| Peça | Onde | Uso na Fase 5 |
|------|------|----------------|
| Registry por **factory** + duck-typing | `lib/harness/registry.rb:11,20,37`; `tool_registry.rb:10,16` | Registrar data-tools como factory, igual a `A2ARemote` |
| **Tool parametrizada por instância** | `lib/harness/tools/a2a_remote.rb:11-32` | Molde direto do `DataDefinedTool` |
| `params_schema` override por instância | `ruby_llm/tool.rb:83-104` | Emitir JSON Schema a partir da config, sem classe por-tool |
| `ToolEnvelope` (timeout/approval/side-effect) | `lib/harness/tool_envelope.rb:35-59,87-98` | Gate por-chamada de graça |
| Policies allow/deny + approval | `lib/harness/policy/policy.rb:50-63,93-98`; `allowlist.rb` | Exposição por agente sem código novo |
| `ToolCatalog` (level-1 + search) | `lib/harness/tool_catalog.rb:16,51-72` | Data-tools aparecem no catálogo/`tool_search` |
| **Overlay store-backed + `reload`** | `SkillCatalog` + `SkillStore` (D3 Fase 4) | Molde do registro dinâmico (D2) |
| `SecretMasking` + `__OCULTO__` | `lib/harness/secret_masking.rb` | Headers-credencial mascarados (F4) |
| Store versionado | `lib/harness/skill_store.rb:40-77` | Molde do `ToolStore` (F7) |
| `ConfigStore` scoped | `lib/harness/config_store.rb:21,30-51` | Novo scope `"tools"` |
| Padrão de Command CQRS + bus | `command.rb`, `command_bus.rb`, `commands/write_skill.rb` | Molde de `:write_data_tool`/`:delete_data_tool` |
| Studio: matriz `/tools`, editor por island | `studio/app.rb:336-352,678-687`; `views/tools.erb`, `skill_edit.erb` | Molde da página de autoria |
| `ProfileSource.coerce` + `StoredProfileSource` | `lib/harness/profile_source.rb:22-26,50-111` | §9.6 é só passar `PROFILE_SOURCE` |
| `A2A::App` já faz `coerce` | `server/a2a/app.rb:21` | §9.6 é só wiring, não toca a classe |
| `LLMConfigurator.apply` (reconfig ao vivo) | `lib/harness/llm_configurator.rb:22-58` | §9.5: delete chama o inverso |

### GAPS — o que a Fase 5 precisa e **não existe** hoje

- **G1 — Persistência de data-tools:** um `ToolStore` (scope `"tools"` novo no
  `ConfigStore::SCOPES`, `config_store.rb:21`), versionado e com headers mascarados.
- **G2 — A classe genérica `DataDefinedTool`:** um `RubyLLM::Tool` parametrizado por
  um value object `ToolDefinition`, sobrescrevendo `name`/`description`/`parameters`/
  `params_schema`/`execute`, com cliente HTTP injetável e guarda de egress (NF2).
- **G3 — Registro dinâmico:** a `ToolRegistry` é imutável pós-boot. Precisa de um
  **overlay** que mescle a registry de código (boot) com o conjunto store-backed,
  re-lido por dispatch (ou via `reload`) — sem tornar a registry de código mutável.
- **G4 — Commands de autoria de tool:** `:write_data_tool` / `:delete_data_tool`
  (+ `reload` do overlay) + validação + auditoria.
- **G5 — Página de autoria de tool:** editor com builder de parâmetros e config HTTP
  (hoje `/tools` só tem a matriz allow/deny read-only sobre `ToolCatalog`).
- **G6 — Wiring A2A no deployment real:** `config/deployment.rb` nunca monta
  `A2A::App`; e `config/wiring.rb:154,157` monta com `PROFILES` estático.
- **G7 — Delete de provider desfazendo runtime:** `DeleteLLMProvider`
  (`commands/delete_llm_provider.rb`) hoje só remove o record durável.

---

## 4. Decisões de arquitetura

### D1 — Data-tool = uma classe genérica parametrizada por `ToolDefinition`

Não geramos uma classe Ruby por tool. Seguimos o padrão do `A2ARemote`
(`a2a_remote.rb:11-32`): **uma** classe `Harness::Tools::DataDefinedTool <
RubyLLM::Tool`, construída com um `ToolDefinition` (value object) + um cliente HTTP
injetado. Ela sobrescreve os métodos de instância que a `RubyLLM::Tool` expõe:

- `name` / `description` ← da definição;
- `parameters` e **`params_schema`** ← derivados dos `parameters` da definição
  (ambos são métodos de instância sobrescrevíveis, `ruby_llm/tool.rb:83-104`), então
  emitimos um JSON Schema arbitrário sem depender do DSL de classe `param`;
- `execute(**kwargs)` ← monta e executa a chamada HTTP (D3) e devolve o resultado
  extraído (F3).

Isso mantém **todos os consumidores intactos** (catálogo, schema do provider, envelope,
policies) porque todos são duck-typed.

### D2 — Registro dinâmico via **overlay store-backed + `reload`** (não restart)

A `ToolRegistry` de código continua imutável (montada no boot, first-registration-wins).
Introduzimos um **`OverlayToolRegistry`** que compõe:

1. a **base** (a `ToolRegistry` de código de hoje), e
2. um **conjunto dinâmico** derivado do `ToolStore`, materializado como factories
   de `DataDefinedTool`.

`entries`/`resolve`/metadados consultam a base **e** o overlay. Em colisão de nome,
**a base (código) vence** — uma data-tool não pode sequestrar o nome de uma tool de
código (regra de segurança). O overlay recarrega via `reload` (troca atômica do
índice dinâmico), disparado pelos Commands de autoria — **exatamente o D3 dos skills**
(`SkillCatalog.reload`). Assim a data-tool nova vale no próximo turno **sem restart**
(F5). O executor lê `@tool_registry.entries` no estágio de policy
(`executor.rb:515`) — passa a ser o overlay; como as data-tools sofrem allow/deny
normal, um agente só as vê se optar.

> **Paridade (NF1):** `ToolStore` vazio ⇒ overlay é a base pura ⇒ `entries`/`resolve`
> idênticos. Spec de paridade obrigatória.
>
> **Alternativa descartada:** persistir e **só registrar no boot** (data-tool exige
> restart, como MCP). Mais simples, mas quebra F5 e é inconsistente com o hot-reload
> de skills — que é o vizinho conceitual (autoria de conteúdo), não o MCP (processo
> externo que liga no boot). Ficamos com o overlay.

### D3 — Chamada HTTP: cliente injetável, templating seguro, extração declarativa

`DataDefinedTool#execute`:

1. **Interpola** `url`/`query`/`headers`/`body` a partir dos kwargs do modelo com
   escaping por contexto (`{{param}}` → URL-encode em path/query, string JSON em
   body). Sem `eval`, sem interpolação Ruby — só substituição textual controlada.
2. **Aplica a guarda de egress (NF2)** antes de sair: resolve o host, rejeita
   IP privado/loopback/link-local/metadata, exige `https` (allowlist opcional de
   hosts por deploy).
3. **Executa** via um `HttpClient` injetável (dublê nos testes, NF6) com timeout
   (o `ToolEnvelope` também impõe o seu, `tool_envelope.rb:54`) e limite de tamanho.
4. **Extrai** o resultado conforme a definição (`response.extract`: `:body_raw`,
   `:json_path` `"a.b.c"`, ou `:status`) e devolve Hash/String. Erro (timeout,
   status ≥ 400, host bloqueado) → `{ error: "..." }`.

### D4 — Segredos de tool: `SecretMasking` nos headers

Headers marcados como secretos (a UI marca; ou heurística: `Authorization`,
`*-Api-Key`, `*-Token`) são persistidos e devolvidos à UI **mascarados**
(`__OCULTO__`), reconciliados no upsert com `SecretMasking.reconcile` — igual a
`LLMProviderStore.upsert` (`llm_provider_store.rb:48-63`) e `McpStore`. O valor real
só sai em `get_raw` consumido pelo `DataDefinedTool` no momento da chamada.

### D5 — Side-effect por padrão do método HTTP

`side_effect` default = `false` para `GET`/`HEAD`, `true` para os demais — o operador
pode sobrescrever. Repassado como metadado no `register` do overlay
(`tool_registry.rb:10`) ⇒ `ToolEnvelope` faz checkpoint/skip-on-resume
(`tool_envelope.rb:87-98`) sem código novo.

### D6 — §9.6: A2A por `ProfileSource` — só wiring

`A2A::App` já faz `Harness::ProfileSource.coerce(profiles)` (`server/a2a/app.rb:21`) e
lê `@profiles[@config[:a2a_agent]]` (`app.rb:39`). A dívida é 100% de composition root:

- **`config/deployment.rb`** passa a montar `Server::A2A::App.new(..., profiles:
  PROFILE_SOURCE, ...)` e a expô-lo no `Server::App.new(..., a2a: ...)`, gateado por
  `PROFILE_SOURCE.fetch(agent)` em vez de `PROFILES[...]`.
- **`config/wiring.rb`** (base) troca `PROFILES` por uma `ProfileSource` também
  (ou a documenta como wiring de exemplo/teste), eliminando o `PROFILES = {}.freeze`
  do caminho A2A (`wiring.rb:100,154,157`).

Resultado: AgentCard e inbound A2A enxergam agentes criados no Studio.

### D7 — §9.5: delete de provider desfaz runtime

`DeleteLLMProvider` (`commands/delete_llm_provider.rb`) ganha o `configurator:`
injetado e, ao deletar, chama um novo `LLMConfigurator#unapply(api)` que zera os
accessors `#{api}_api_key`/`#{api}_api_base` no config global do RubyLLM quando eles
existem; se o RubyLLM não permite "desconfigurar", degrada para o banner
"restart recomendado" (que já existe, Fase 4 Etapa H). Confirmar o caminho no RubyLLM
antes (pode ser só setar `nil`).

---

## 5. Contrato — `ToolDefinition` (o schema de uma data-tool)

Value object durável (persistido pelo `ToolStore`, versionado). Forma proposta:

```ruby
ToolDefinition = Data.define(
  :name,          # String, identificador p/ o modelo (validação: [a-z0-9_], único)
  :description,   # String, descrição p/ o modelo (dirige catálogo + schema)
  :parameters,    # [{ name:, type: "string"|"number"|"boolean"|"array",
                  #    description:, required: true|false }]
  :request,       # { method:, url:, headers: {k=>v}, query: {k=>v}, body: String|nil }
  :response,      # { extract: "body_raw"|"status"|"json_path", path: "a.b.c"|nil }
  :secret_headers,# [String] nomes de header cujo valor é segredo (mascarado)
  :side_effect,   # bool (default derivado do method, D5)
  :timeout        # segundos (default do settings global)
)
```

Regras de validação (no Command e no value object):
- `name` único no overlay **e** não colide com tool de código (D2);
- `parameters[].type` ∈ tipos suportados; `required` default `true`;
- `request.method` ∈ `GET/HEAD/POST/PUT/PATCH/DELETE`; `url` é `https` (ou allowlist);
- `response.extract == "json_path"` ⇒ `path` presente;
- placeholders `{{x}}` em `url`/`query`/`headers`/`body` referem só `parameters` declarados.

---

## 6. Contratos de API & Commands (novos)

### Commands CQRS (novos, no CommandBus)

| Command | Payload | Efeito | Retorno |
|---------|---------|--------|---------|
| `:write_data_tool` | `ToolDefinition` (headers secretos podem vir `__OCULTO__`) | valida, reconcilia segredos, `ToolStore.write` (versiona), `overlay.reload`, emite `:data_tool_written` | `{ name:, updated_at: }` |
| `:delete_data_tool` | `{ name: }` | `ToolStore.delete`, `overlay.reload`, emite `:data_tool_deleted` | `{ name: }` |
| `:restore_data_tool` | `{ name:, index: }` | `ToolStore.restore`, `overlay.reload` | `{ name:, updated_at: }` |

Contrato de Command idêntico ao existente (`initialize(**deps)`, `call(command)`,
`raise ValidationError/NotFoundError`, emite `Harness::Event`, retorna valor de
domínio — `commands/write_skill.rb` é o molde).

### Endpoints do Studio (Roda, sob `/studio`, protegidos por sessão)

| Rota | Verbo | Handler → Command |
|------|-------|-------------------|
| `/tools` | GET | matriz allow/deny **+ índice de data-tools** (evolui `render_tools_matrix`) |
| `/tools/new` | GET | editor de data-tool (vazio) |
| `/tools/def/:name` | GET | editor de data-tool (carregado, segredo mascarado) |
| `/tools/def` | POST | `:write_data_tool` (create) |
| `/tools/def/:name` | POST | `:write_data_tool` (update) / `:delete_data_tool` (via `_method`) |
| `/tools/def/:name/restore` | POST | `:restore_data_tool` |
| `/tools/:id` | POST | **inalterado** — `:set_agent_tools` (allow/deny por agente) |

> **Nota de rota:** o POST de allow/deny por-agente hoje é `/tools/:id`
> (`app.rb:341`). Para não colidir com nomes de data-tool, a autoria fica sob
> `/tools/def/*` e a matriz por-agente segue em `/tools/:id`. Lembrar do `utf8(seg)`
> em segmentos capturados (bug corrigido na Fase 4 F: Roda entrega ASCII-8BIT).

---

## 7. Plano de implementação (etapas → PRs)

| Etapa | Tasks | Entrega | PR |
|-------|-------|---------|----|
| **A — Core: definição + store + tool** | 1-3 | `ToolDefinition` + validação; `ToolStore` (scope `tools`, versionado, mascarado); `DataDefinedTool` (HTTP + egress guard + extração), tudo com specs. **Sem UI, sem registro dinâmico ainda.** | PR 1 |
| **B — Registro dinâmico** | 4-5 | `OverlayToolRegistry` (base+store, `reload`, base-vence-colisão) plugado em `ToolCatalog` + executor (spec de paridade NF1); Commands `:write/delete/restore_data_tool` no bus/wiring. | PR 2 |
| **C — Studio UI** | 6-7 | Página de autoria (`/tools/def/*`: builder de params + config HTTP + editor island + segredo mascarado + versões); matriz `/tools` lista data-tools; prova HTTP+LLM ponta-a-ponta. | PR 3 |
| **D — Dívidas de wiring** | 8-9 | §9.6: A2A/AgentCard via `PROFILE_SOURCE` no deployment (+ base); §9.5: delete de provider desfaz runtime. | PR 4 |

**Dependências:** A é blocker de B e C. B é blocker de C (a UI dispara os Commands do
overlay). D é **independente** de A/B/C (pode ir em paralelo ou primeiro — é dívida
isolada). Ordem sugerida: A → B → C, com D encaixável a qualquer momento.

---

## 8. Riscos & edge cases

### Riscos

- **R1 — SSRF/egress (o maior).** Data-tool = requisição HTTP server-side controlada
  por config editável na UI. Sem a guarda NF2 (bloqueio de IP privado/metadata,
  https-only, allowlist opcional), vira vetor de SSRF. **Mitigação:** guarda de egress
  no `DataDefinedTool` **e** teste adversarial (tentar `http://169.254.169.254/…`,
  `http://localhost`, `http://10.x`) que deve dar `{error:}`.
- **R2 — Vazamento de segredo.** Header-credencial em log/auditoria/`to_h`.
  **Mitigação:** `SecretMasking` no store + evento de auditoria mascarado + teste de
  "0 vazamentos" (grep por valor real na resposta HTTP da UI e no event stream).
- **R3 — Colisão de nome com tool de código.** Data-tool sequestrando `remember`/
  `tool_search`/`load_skill`. **Mitigação:** base-vence no overlay (D2) + validação
  que rejeita nome já em uso na base.
- **R4 — Regressão de paridade (NF1).** Overlay muda o caminho quente
  (`executor.rb:515`). **Mitigação:** spec de paridade com store vazio + a suíte
  atual (1039 examples) verde.

### Edge cases

- Placeholder `{{x}}` referenciando parâmetro não declarado → erro de validação.
- Resposta não-JSON com `extract: json_path` → `{error:}` claro.
- Resposta gigante → corte por limite de tamanho (NF2).
- `side_effect: true` + resume de task → skip-on-resume (envelope, já coberto).
- Deletar data-tool que está no `tools_allow` de um agente → agente deixa de vê-la no
  próximo turno; allow/deny do profile fica com nome órfão (benigno — filtrado).
- §9.5: RubyLLM não permitir desconfigurar → cai no banner de restart (não quebra).

### Rollback

Cada etapa é 1 PR revertível. A e B são inertes com `ToolStore` vazio (NF1). D é
wiring — reverter volta ao A2A não-exposto no deployment (estado de hoje).

---

## 9. Open questions

1. **Guarda de egress — política default.** `https`-only + bloqueio de rede privada é
   consenso. Allowlist de hosts é opt-in por deploy (settings) ou obrigatória?
   Sugestão: opt-in, com aviso na UI quando vazia.
2. **Auth de data-tool além de header estático.** OAuth2/refresh-token fica fora de
   escopo (Fase 6?). V1 = header/bearer estático mascarado. Confirmar suficiência.
3. **Templating — motor.** Substituição textual `{{param}}` com escaping por contexto
   é suficiente para V1? (Sem condicionais/loops — se precisar, é feature nova.)
4. **`response.extract`.** `body_raw`/`status`/`json_path` cobrem o comum. Precisa de
   transformação (ex.: mapear campos, renomear)? Adiar para não virar mini-linguagem.
5. **§9.5 — confirmar RubyLLM.** Setar `config.<api>_api_key = nil` de fato
   desconfigura o provider no RubyLLM 1.16? Se não, delete degrada para restart.
6. **A2A + data-tools.** AgentCard hoje lista skills; deveria listar tools também?
   Fora de escopo desta fase (a §9.6 é só migrar a leitura de profile).

---

## 10. Dependências & blockers

- **Sem gems novas** para o headline: cliente HTTP pode ser `Net::HTTP` (stdlib) atrás
  de um `HttpClient` injetável — mantém o "zero-dep extra" e é testável por dublê.
  (Se quiser `Async::HTTP` para não bloquear o reactor, é uma decisão de D3 — avaliar,
  mas `Net::HTTP` num tool sob `ToolEnvelope`/timeout é aceitável para V1.)
- **Reusa:** registry/catalog/envelope/policies (tools), `SkillStore`/`SecretMasking`/
  `ConfigStore` (persistência), `SkillCatalog.reload` (padrão de overlay),
  o design system e os islands da Fase 4 (UI), `ProfileSource.coerce` +
  `A2A::App`/`AgentCard` (dívida §9.6), `LLMConfigurator` (§9.5).
- **Blocker interno:** Etapa A → B → C. D independente.
- **Não bloqueado por** multi-tenancy (§9.2) nem pelo render WhatsApp (§9.4), ambos
  adiados.

---

> ⚠️ **Spec AI-generated, requer revisão humana.** Atenção especial a §4 D2 (overlay
> no caminho quente do executor), §8 R1 (SSRF — a superfície de segurança nova mais
> séria) e §9.5 (confirmar RubyLLM antes de prometer "delete sem restart").
