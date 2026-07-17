# FOLLOWUP — Harness (roadmap de evolução)

> **Status:** documento vivo (fora do processo de RFC). Organiza as decisões
> estratégicas levantadas após a **Fase 7** (tool host genérico) concluída.
> **Contexto:** o motor já roda um piloto ponta-a-ponta (1 loja, substituindo o
> gateway OpenClaw). As Fases 0–7 entregaram runtime de turno, SSE, sessão,
> memória, resume durável, multi-agente, provisionamento por pack, data-tools em
> JSON Schema/manifesto, grupos, ingestão MCP e observabilidade OTEL. O que segue
> é o **próximo horizonte**, agrupado por tema, com recomendação + porquê + itens
> acionáveis.

Legenda de prioridade: 🔴 alta · 🟡 média · 🟢 baixa/oportunista.

> **Já entregue nesta rodada (pós-piloto Railway):**
> - **Deploy Railway** (Dockerfile/railway.json/`/up`) + loadtest (`bench_store.rb`/
>   `loadtest.rb`/`loadtest-local.sh`) + fix de boot SQLite multi-proc. Ver
>   `docs/DEPLOY.md`.
> - **Trace de tool calls no Studio** (§3.1) — args + resposta + status por turno,
>   com masking/truncation. `ToolTraceStore` + `ToolEnvelope`.
> - **Resiliência de boot:** `DEEPSEEK_API_KEY` ausente vira **warn** (não `raise`)
>   — o motor sobe, turnos falham com erro claro até a chave existir.
> - **Separação de tokens** documentada (`ADMIN_TOKEN` vs `OPENCLAW_GATEWAY_TOKEN`
>   + rotação) em `docs/DEPLOY.md`.

---

## 1. Performance & Infra

### 1.1 Atualizar para Ruby 4 — vale a pena por performance?
**Recomendação: sim, subir a versão do Ruby — mas o ganho vem do YJIT, não de Ractors.** 🟡

- O `Gemfile` já declara `ruby ">= 3.2"` e roda em 3.3.5. Subir para 3.4+/4.0 é
  **baixo risco** (poucas breaking changes; o Prism vira parser default, frozen
  string literals caminham para default — o projeto já usa `# frozen_string_literal`).
- O ganho real de perf num motor **I/O-bound** (o tempo do turno é dominado pela
  latência do provider LLM, não por CPU Ruby) é o **YJIT** ligado por padrão e
  mais maduro. Ligar YJIT (`RUBY_YJIT_ENABLE=1` / `--yjit`) é o item de maior
  retorno por menor esforço.
- **Ação:** bump da versão + YJIT no runtime + rodar a suíte e um loadtest antes/
  depois (ver §1.4) para medir o delta real.

### 1.2 Podemos usar Ractors além de Fibers?
**Recomendação: não agora — é a ferramenta errada para este gargalo.** 🟢

- A arquitetura é **um único reactor Async com fibers cooperativas** e **stores/
  registries mutáveis compartilhados** (sem mutex — a corretude vem de "1 reactor,
  fibers cooperativas", ver `command_bus.rb`, `overlay_tool_registry.rb`). Ractors
  exigem que todo dado compartilhado seja **shareable** (congelado/imutável); os
  stores não são. Adotar Ractors = **re-arquitetura profunda**, não um add-on.
- Ractors atacam paralelismo **CPU-bound** multi-core. Nosso gargalo é **I/O**
  (provider + `/api/internal/*`), que as fibers já resolvem com alta concorrência
  num core. E o ecossistema (ruby_llm, sqlite3, muitas gems) ainda **não é
  ractor-safe**.
- A forma correta de usar múltiplos cores aqui é **multi-processo** (workers do
  Falcon / pods no k8s) — exatamente o modelo multi-proc do OpenClaw. Isso conecta
  com a **topologia de dados** do §1.3 (SQLite N-procs numa máquina, ou sharding
  por tenant entre máquinas).
- **Ação:** manter fibers; documentar essa decisão para não reavaliarem por engano.

### 1.3 Railway agora, k8s depois — e o SQLite aguenta produção?
**Recomendação: SQLite é a escolha certa como default e JÁ está configurado para
produção. A questão não é "trocar por Postgres" — é TOPOLOGIA. Postgres vira um
backend OPCIONAL.** 🔴

> Revisão de uma recomendação anterior boa demais. SQLite em produção é prática
> corrente (Rails 8 com Solid Queue/Cache/Cable + Litestack; 37signals/fizzy;
> vários relatos de deploy Rails+SQLite). O código do harness já reflete isso.

- **O `Stores::SQLite` já usa a receita completa de produção:** `journal_mode =
  WAL` (leitores concorrentes + 1 escritor), `synchronous = NORMAL`,
  `busy_timeout = 5s` (absorve contenção de escrita entre processos), transações
  `BEGIN IMMEDIATE` (evita o deadlock de upgrade) e serialização de escrita
  in-process por `Async::Semaphore`. O "database is locked" que eu havia citado
  **já está mitigado por construção**.
- **1 máquina, N processos (workers do Falcon): funciona HOJE.** WAL dá leitura
  concorrente; o `busy_timeout` absorve a contenção entre procs; as escritas por
  turno são poucas e curtas (session/task/checkpoint) e o workload é
  **provider-bound** (turnos de segundos) — o teto de escrita do SQLite fica
  distante. É o modelo "single big box" do 37signals.
- **O único limite DURO do SQLite** é **multi-MÁQUINA compartilhando 1 arquivo**
  (SQLite não é feito para FS de rede). Só aí a topologia importa — e há caminhos
  SQLite-native que **casam com o design do harness** (isolamento por agente já
  existe):
  - **Sharding por tenant (recomendado se precisar horizontal):** 1 arquivo
    SQLite por loja/agente, roteado **sticky-by-agent** (o modelo do OpenClaw,
    `OPENCLAW_STATE_DIR` por proc). Escala horizontal por tenant **sem banco
    compartilhado**. Trabalho novo: um "sharded store" que roteia por tenant → uma
    instância de Store (pequeno, alinhado à arquitetura).
  - **Litestream:** replicação contínua para S3 (backup/DR/restore) — HA barata
    sem trocar de banco. Vale adotar cedo, independe da topologia.
  - **LiteFS (fly.io):** FS distribuído com 1 primary writer + réplicas de
    leitura, se quiser multi-node com um DB lógico.
- **Postgres continua no radar como OPÇÃO, não requisito:** a abstração de Store
  (`Harness::Stores::*` — há `SQLite` e `Memory`) torna um adapter `Postgres`
  barato de escrever, para quem já vive em Postgres gerenciado e prefere um banco
  central multi-tenant. É escolha do operador, não pré-requisito de escala.
- **k8s com SQLite:** StatefulSet + PersistentVolume por pod + roteamento sticky
  (shard por tenant, ou tenants-por-pod), OU LiteFS. Não obriga Postgres.
- **Ação (sequência revisada):**
  1. Dockerfile + Railway (WAL já ligado) — o piloto roda em **1 box** sem tocar
     no backend.
  2. **Medir antes de assumir:** loadtest N-procs numa máquina (§1.4) para provar
     o teto real de escrita — evita otimização prematura de topologia.
  3. **Litestream** para backup/DR desde cedo (barato, ortogonal à topologia).
  4. **Só se** precisar horizontal multi-node: decidir topologia — (a) sharding
     por tenant + sticky (recomendado), (b) LiteFS, ou (c) adapter Postgres — e
     implementar a escolhida.

### 1.4 Script de loadtest similar ao do OpenClaw
**Recomendação: reusar o `loadtest-gateway.mjs` do OpenClaw JÁ (o contrato é o
mesmo) + entregar um equivalente Ruby nativo no repo.** 🔴

- **Vantagem enorme:** o harness expõe `POST /v1/responses` **SSE drop-in** do
  gateway. O `loadtest-gateway.mjs` (mede TTFB, total, tokens, cache-hit, P50/P95,
  taxa de erro, round-robin de portas) **funciona apontando pro harness sem
  mudar nada** — basta `OPENCLAW_GATEWAY_URL=http://localhost:9292`. Isso dá a
  **comparação apples-to-apples** harness vs gateway que o piloto shadow precisa.
- Para o repo OSS (sem depender de Node), portar um `scripts/loadtest.rb` nativo
  espelhando as métricas, e um `scripts/loadtest-local.sh` que sobe N processos do
  Falcon (baseline single vs multi) como o `loadtest-local.sh` do OpenClaw faz.
- **Ação:**
  1. Doc curto "como comparar" reusando o `loadtest-gateway.mjs` contra o harness.
  2. `scripts/loadtest.rb` (async/net-http, TTFB+total+tokens+P50/P95).
  3. `scripts/loadtest-local.sh` (baseline 1 proc vs N procs do Falcon; checar
     "database is locked" como o script do OpenClaw faz — prova o §1.3).

---

## 2. Testes — trocar RSpec por Minitest?

**Recomendação: não reescrever os 1311 specs agora; reavaliar na extração de gems
(§4), quando Minitest passa a fazer mais sentido.** 🟢

- **A favor do Minitest:** vem com o Ruby (menos deps), mais rápido, menos
  "mágica" — o idioma padrão de **gems** e alinhado à estética minimalista de OSS
  (ex.: o okf-gem que você citou). Bom para um projeto que quer ser lib do
  ecossistema RubyLLM.
- **Contra a migração agora:** há **1311 exemplos passando** em RSpec; reescrever
  por gosto é custo alto e risco de regressão sem ganho de produto. RSpec também é
  o que a maioria dos contribuidores Ruby conhece.
- **Meio-termo pragmático:** quando quebrar em gems (§4), **novos pacotes nascem
  em Minitest**; o core migra só se/quando a extração exigir. Não bloquear nada
  nisso hoje.

---

## 3. UI/UX — Studio dentro do projeto ou paralelo?

**Recomendação: manter no monorepo agora, mas desenhar para extração; a costura
já existe (a API HTTP). Melhorar o `studio/` puxando o visual do agent-studio.** 🟡

- **Estado atual:** o `studio/` **já vive neste repo** (Ruby + Hotwire/Stimulus/
  Tailwind + CodeMirror, servido pelo próprio harness). Ele NÃO acopla ao core —
  fala com o motor pela **mesma API HTTP** (Commands/reads). Essa é exatamente a
  fronteira que permite extrair depois sem reescrever.
- **"Trazer o agent-studio pra dentro":** o agent-studio bonito é Next.js (stack
  diferente). O caminho de menor custo é **portar o visual/UX** (design, layout,
  fluxos) para o `studio/` Hotwire — não portar a stack. Assim mantém tudo
  servido por Ruby, sem um front Node separado no runtime.
- **Ecossistema RubyLLM ("quebrar as peças" vs "tudo junto"):** o modelo do
  RubyLLM é **gems pequenas e focadas**. Recomendação:
  - **Agora:** monorepo, para velocidade. O core e o studio já estão desacoplados
    pela API.
  - **Na hora do OSS (§4/§5):** extrair em gems — `harness-core` (motor),
    `harness-server` (Rack/SSE), `harness-studio` (engine montável / mountable
    Rack app), `harness-otel`, e plugins como gems `harness-plugin-*`. Quem quer
    só o motor pega o core; quem quer a UI monta o studio.
- **Ação:** (1) refresh de UI/UX do `studio/` inspirado no agent-studio; (2)
  garantir que o studio consome só a API pública (nada de acesso a store direto —
  a regra constitucional já veta isso no `server/`); (3) planejar a extração como
  parte do §4.

### 3.1 Visibilidade de tool calls no chat (debug) ✅ ENTREGUE
**Entregue:** o viewer de sessão (`/studio/sessions/:id`) mostra, por turno, QUAIS
tools rodaram + os ARGS enviados + a RESPOSTA + status/latência. Impl: um
`Harness::ToolTraceStore` (durável, por sessão, com masking de chaves sensíveis +
truncation) que o `ToolEnvelope` alimenta por call; o Studio renderiza em
accordions. Segue abaixo o desenho original (mantido como referência). **Evoluções
possíveis:** flag por-agente p/ trace verboso, export como atributo de span OTEL,
paginação/limpeza por sessão (`ToolTraceStore#clear` já existe).

- **Dor real (veio do piloto):** ao debugar a loja no Railway, só dava pra ver as
  mensagens user/assistant — não dava pra ver que `search_products` foi chamado,
  com quais `query_filter_pairs`, e o que o `/api/internal/*` devolveu. Hoje isso
  exige `railway ssh` + inspeção manual do SQLite. Inaceitável pra operar.
- **O que já existe (reusar):** o motor **emite** eventos de tool no Event Stream
  (`data_tool_call` com `tool` + `status`; tool-cards ao vivo em `/admin/events`)
  e há **spans OTEL** (Fase 6: `harness.tool`/`harness.data_tool` com atributos).
  **Mas:** (a) o `data_tool_call` carrega SÓ nome+status (por segurança — 0
  vazamento de header/secret), **sem args nem corpo da resposta**; (b) esses
  eventos são efêmeros (stream), não ficam anexados à sessão pra ver DEPOIS.
- **O gap:** persistir um **trace de tool-call por turno** (nome, args do modelo,
  request resolvido SEM secrets, status HTTP, corpo da resposta — truncado/
  mascarado) e renderizá-lo no viewer da sessão, alinhado ao turno. O Executor/
  ToolEnvelope já têm args + resultado na mão; falta um evento/registro mais rico
  (ou anexar ao Task/checkpoint) que o Studio leia.
- **Tensão de segurança (resolver no design):** args e resposta podem trazer PII/
  dados sensíveis; os `secret_headers` já são mascarados, mas o CORPO não. Regras:
  mascarar credenciais, truncar payloads grandes, e gatear atrás do admin (é tela
  de operador). Considerar um flag por-agente/deploy p/ ligar o trace verboso.
- **Ação:** (1) capturar o trace de tool-call (args + request mascarado + status +
  resposta truncada) por turno — evento rico e/ou persistido no Task; (2) render
  no `/studio/sessions/:id` (accordion por tool call, alinhado ao turno); (3)
  masking/truncation + gate de admin; (4) opcional: exportar como span OTEL
  attribute p/ quem usa SigNoz.

---

## 4. Plugins — como trabalhar, nativos, terceiros, hub

**Recomendação: dois níveis de extensão — dados (data-tools/manifesto, sem código)
e código (gems com autodiscovery). Hub começa como convenção de nome, evolui p/
web depois.** 🟡

- **Base já existe:** `plugin_loader` + autodiscovery (RFC-0003) + exemplo
  `plugins/weather` (`harness.plugin.yml` + `plugin.rb`). E a Fase 5/7 trouxe
  **tools-como-dado** (data-tools/manifesto), que é um caminho de extensão sem
  código, hot, sem rebuild.
- **Dois tiers de extensão (comunicar isso claramente):**
  - **Tier 1 — dados (sem código):** integrações HTTP viram **data-tools /
    manifesto** (JSON Schema + binding). Barreira baixíssima, hot-reload, seguro
    (egress guard, secret masking, allowlist por grupo). É o caminho para "a
    comunidade adiciona integrações".
  - **Tier 2 — código (gems):** capabilities novas, policies, context providers,
    stores, providers de LLM → **gems `harness-plugin-*`** com autodiscovery
    (RFC-0003). É o caminho para "estender o motor".
- **Nativos:** shippar um conjunto curado (o `weather` é o exemplo; candidatos:
  http genérico, tempo/data, busca web, e os builtins de "code harness" do §6).
- **Terceiros:** sim — via as duas trilhas. O contrato do manifesto (Tier 1) e o
  contrato de plugin (Tier 2, RFC-0003) são os pontos de extensão públicos.
- **Hub:** começar simples — **convenção de nome** no RubyGems (`harness-plugin-*`)
  + uma **lista curada** no repo/docs (como o "registry público de skills/plugins"
  já previsto na Fase 3 do BACKLOG). Um **hub web** (busca/registro de skills,
  tools e plugins) é evolução posterior.
- **Ação:** (1) documentar os dois tiers com exemplos; (2) definir o contrato/SemVer
  de plugin de código; (3) publicar 2–3 plugins nativos como referência; (4)
  convenção `harness-plugin-*` + lista curada.

---

## 5. Docs & OSS

**Recomendação: tratar como uma fase própria — é o que destrava o engajamento da
comunidade. Pré-requisito nº 1: migrar o projeto para inglês.** 🔴

- **5.1 Inglês em todo o código/testes/comentários.** Hoje comentários, mensagens
  e (parcialmente) identificadores estão em **português**. Para OSS internacional
  isso é bloqueador. É um trabalho **grande, porém mecânico** — fazer em passes
  por módulo, com a suíte verde como rede. **Este próprio documento deve ser
  traduzido** quando a migração acontecer. Ordem sugerida: comentários/mensagens →
  nomes de teste → identificadores públicos (com cuidado p/ não quebrar contrato).
- **5.2 Documentação de arquitetura com diagramas.** Já há techspecs por fase e
  RFCs (`docs/harness_handoff/rfcs/`). Consolidar num conjunto navegável:
  - Visão geral do motor (pipeline canônica: Command Bus → Context Builder →
    Policy → Middleware → Executor/tool-loop → Event Stream/SSE).
  - Diagramas **Mermaid** (sequência de um turno; fluxo de uma data-tool com
    contexto de turno; ingestão de manifesto; SSE/streaming; recovery/resume).
  - "Por quê" de cada decisão (as techspecs já têm muito disso — curar e traduzir).
- **5.3 README técnico forte** — quickstart (subir com Falcon, criar um agente,
  provisionar um pack, primeiro turno via `/v1/responses`), contrato da API, e
  ponteiros para a doc de arquitetura.
- **5.4 Site de docs.** O exemplo citado (**okf-gem / okfgem.com** do @serradura)
  é ótima referência de doc de gem Ruby: enxuta, exemplos primeiro, site limpo.
  Avaliar também: docs do próprio **RubyLLM**, Hanami, dry-rb, ROM (todos com boa
  doc de ecossistema). Stack candidata: um static site (o `docusaurus-expert`/
  Docusaurus já aparece no tooling) ou algo Ruby-native.
- **5.5 Engajamento OSS.** CONTRIBUTING, CODE_OF_CONDUCT, templates de issue/PR,
  o processo de RFC já existente (RFC-0000), licença, e as "decisões pendentes"
  do BACKLOG (nome/namespace do projeto, stateless vs stateful default) — resolver
  antes do release público.
- **Ação:** (1) passe de tradução PT→EN por módulo; (2) árvore de docs +
  diagramas Mermaid; (3) README quickstart; (4) escolher e montar o site; (5)
  arquivos de comunidade + resolver as decisões pendentes.

---

## 6. Ideia — usar o harness como harness de código (tipo Claude Code / Hermes)

**Recomendação: viável e ótimo para dogfooding/OSS — é um agente + toolset + front
novos sobre o mesmo motor, não uma mudança de core.** 🟡

- O motor já tem o essencial: **provider-agnóstico**, **tool-loop**, sessões,
  **resume durável**, skills (progressive disclosure), memória, **ingestão MCP**,
  approvals/policies, SSE. É a mesma fundação de um Claude Code.
- O que falta é um **toolset de código** (os "34 Core builtins" que o OpenClaw
  tinha e que o harness deliberadamente NÃO implementou, por serem builtins do
  gateway): `read`/`write`/`edit` de arquivo, `bash`/shell, `grep`/busca,
  subagents, e um **front CLI/TUI** local. São tools novas (código, Tier 2) + um
  cliente de terminal falando com o `/v1/responses`/`/v1/messages`.
- **Como encaixar:** um **perfil de agente "harness-code"** com esse toolset e um
  front CLI — provavelmente um **exemplo/aplicação separada** no ecossistema
  (`harness-code`), consumindo o core como lib. Bom vetor de marketing OSS ("o
  motor roda tanto seu bot de WhatsApp quanto seu agente de código").
- **Cuidado:** tools de FS/shell são as de maior superfície de risco — reusar o
  modelo de **approvals** (já existe) e sandbox/allowlist com rigor.
- **Ação:** protótipo `harness-code` (toolset FS/shell com approvals + CLI mínima)
  como aplicação de exemplo, depois do core estar OSS-ready.

---

## Priorização recomendada (sequenciamento)

| # | Item | Tema | Prioridade | Depende de |
|---|------|------|------------|------------|
| 1 | Dockerfile + Railway (1 box, SQLite WAL já on) p/ shadow do piloto | Infra | 🔴 | — |
| 2 | Loadtest: reusar `loadtest-gateway.mjs` no harness + `scripts/loadtest.rb` | Perf | 🔴 | 1 |
| 3 | Medir teto de escrita SQLite N-procs + Litestream (backup/DR) | Infra | 🔴 | 2 |
| 4 | Bump Ruby + YJIT (medir com o loadtest) | Perf | 🟡 | 2 |
| 5 | Escala horizontal (SE preciso): sharding por tenant + sticky, ou LiteFS, ou adapter Postgres | Infra | 🟡 | 3 |
| 6 | Migração PT→EN (código/testes/comentários) | Docs/OSS | 🔴 (p/ OSS) | — |
| 7 | Docs de arquitetura + diagramas + README + site | Docs/OSS | 🔴 (p/ OSS) | 6 |
| 8 | Extração em gems (`harness-core/-server/-studio/-otel`) | Ecossistema | 🟡 | 7 |
| 9 | ✅ **Trace de tool calls no viewer do chat (args+resposta, masking) — debug (§3.1)** — ENTREGUE | UI/UX | ✅ | — |
| 10 | Refresh de UI/UX do `studio/` (inspirado no agent-studio) | UI/UX | 🟡 | — |
| 11 | Doc dos 2 tiers de plugin + 2–3 plugins nativos + convenção de hub | Plugins | 🟡 | 7 |
| 12 | Protótipo `harness-code` (toolset FS/shell + CLI) | Ideias | 🟢 | 8 |

**Dois trilhos paralelos naturais:**
- **Trilho Produto/Escala** (1→2→3→4→5, + **9** como quick-win de operação): leva o
  piloto a produção e a múltiplas lojas. O #9 (trace de tool calls) é o mais urgente
  do dia-a-dia — sem ele não dá pra debugar turno em produção.
- **Trilho OSS/Ecossistema** (6→7→8→10→11→12): prepara o projeto para a comunidade.

Decisões que **destravam** os trilhos e dependem de você/produto: **onde hospedar**
(Railway→k8s) e **quando "abrir"** o projeto (dispara o trilho OSS, começando pela
migração para inglês).

---

## Deferrals herdados (contexto)

- **Fase 7 Etapa E:** transporte MCP real (stdio/sessão/unwrap — só POST JSON-RPC
  stateless hoje), injeção de credencial da instância MCP no binding, corte
  dinâmico de schema por flag (piloto usa allowlist estática).
- **Motor:** hooks que não são tools (card dispatch/carrossel, sentiment→override),
  multi-provider/route por turno — produto marcou como não-necessários para o
  piloto.
