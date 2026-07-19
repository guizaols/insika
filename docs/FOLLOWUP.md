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
>
> **Entregue na rodada seguinte (4 PRs #60–#63, mergeados 2026-07-17):**
> - **§1.4 Doc de loadtest** (`docs/LOADTEST.md`): guia por script + comparação
>   apples-to-apples harness vs gateway (nativo trocando `HARNESS_URL`, ou o
>   `loadtest-gateway.mjs` do OpenClaw sem modificar via `OPENCLAW_GATEWAY_URL`)
>   + hardening dos 3 scripts (`--dry-run` seguro, validação de flags). **Falta a
>   dimensão de comparação por versão de Ruby e o relatório — ver §1.1/§1.4.**
> - **§6 Protótipo `harness-code`**: toolset FS/shell (`plugins/harness-code/`:
>   `read_file`/`list_dir`/`grep` + `write_file`/`edit_file`/`bash` gated) + CLI
>   (`examples/harness-code/`) reusando approvals+sandbox do motor. Review de
>   segurança fechou 1 escape de sandbox via symlink + ReDoS no grep.
> - **§3/#10 Refresh de UI/UX do Studio**: sidebar cockpit + session telemetry
>   timeline (§3.1); corrigiu bug de CSP que deixava o trace sem estilo em prod.
> - **§5.1 Migração PT→EN — 1º passe**: `lib/harness/**` (~114 arquivos) +
>   `docs/TRANSLATION-TRACKER.md`. **Migração EM ANDAMENTO** (2º passe: `server/`,
>   `bin/`, `scripts/` composition-root, `config/`, `studio/`; ver tracker).
>
> **Entregue na rodada de benchmark (PRs #64–#69, mergeados 2026-07-18):**
> - **§1.1/§1.4 — matriz de benchmark + relatório FECHADOS** (`docs/BENCHMARKS.md`).
>   Ruby **4.0.6 default + YJIT** (PR #67); CPU bench (`bench_cpu.rb`, §2) + SQLite bench
>   (`bench_store.rb`, §3) + e2e vs OpenClaw (§5) + **pernas LOCAIS** (harness Falcon 4-proc
>   @~30k vs OpenClaw 4-gw, matched — §4a) + **harness Railway 4.0.6** (§4c). **Achado
>   central:** 4.0.6+YJIT ganha ~+19% no CPU-bound por-turno (§2) e ~+50–60% no path SQLite
>   (§3), mas o ganho é **mascarado pela latência do provider e2e** (Railway 4.0.6 ≈ 3.3.5
>   nos números de turno) → **§2 é o sinal limpo do motor**, não o e2e. Harness fecha turno
>   ~2,3–2,5× mais rápido que o OpenClaw a 4-proc (matched), com prompt-cache do DeepSeek.
> - **Fix de deploy (PR #69):** `libssl-dev`+`pkg-config` no Dockerfile builder — a gem
>   `openssl` 4.0.2 (compilada após o re-resolve do lock no 4.0.6) não buildava no
>   `ruby:4.0.6-slim` (linux); **a imagem 4.0.6 nunca tinha subido no Railway** — o piloto
>   rodava a 3.3.5 antiga. Corrigido; piloto agora em `4.0.6 +YJIT +PRISM` (Falcon 4-proc).
> - **§5.1 Tradução PT→EN — 2º/3º passes** (PRs #65/#66): `server/`/`config/`/composition-root
>   + specs + strings model-facing. Falta só **este documento** (traduzir por último).
> - **⏳ GAP que ficou — teste de carga com TRÁFEGO REAL** (não-sintético): TODAS as pernas
>   acima usam o mesmo greeting enlatado (1 turno, usuário novo, **0 tool call**, não bate no
>   achei-b2b). O corpus real já está extraído (**179 msgs reais de user** dos session logs do
>   OpenClaw: cacau 97 / natura 51 / vaio 31). Próximo passo abaixo (§1.4 ação 5 + §9 evals).
>
> **Entregue nesta rodada (config de LLM v2, item 18 / §10):**
> - **`ModelResolver`** — resolução Chat > Agent > default de plataforma no início do turno,
>   `model_policy` sobre o modelo resolvido, cadeia de fallback + fonte de seleção
>   (`:chat`/`:agent`/`:platform_default`) + semântica `pinned` (pin de usuário falha ALTO).
>   Novos slots em Settings (`default_model`/`default_provider`/`fallback_models`/
>   `utility_model`); `model` opcional no profile; `params`/`model_policy` por agente;
>   override por chat (`:create_session {model, provider}` → slot reservado `vars["__llm__"]`,
>   fora do prompt). Gotcha de mutação global documentado no `LLMConfigurator`. **Deferido:**
>   rotação mid-turn pela cadeia de fallback (mexe no laço de streaming) + consumo do
>   `utility_model`.

---

## 1. Performance & Infra

### 1.1 Atualizar para Ruby 4 — vale a pena por performance?
**Recomendação: sim, subir a versão do Ruby — mas o ganho vem do YJIT, não de Ractors.** ✅ **ENTREGUE**

> **Fechado (PRs #67/#69, `docs/BENCHMARKS.md`):** shipado **Ruby 4.0.6 default + YJIT**
> (`.ruby-version`/`mise.toml`/Dockerfile/Gemfile.lock re-resolvido; suíte verde em 3.3.5 e
> 4.0.6). Matriz medida `{3.3.5, 4.0.6} × {YJIT off/on} × {local, Railway}` + vs OpenClaw.
> **Resposta:** vale — 4.0.6+YJIT é o cell mais rápido (~+19% CPU-bound por-turno §2, ~+50–60%
> no path SQLite §3), **de graça** (YJIT já on no container). Mas confirma a tese "motor
> I/O-bound": o ganho é CPU-side e **some no e2e** (Railway 4.0.6 ≈ 3.3.5), então **§2 é o
> sinal de motor**, não §4/§5. Texto abaixo mantido como o racional original.

- O `Gemfile` já declara `ruby ">= 3.2"` e roda em 3.3.5. Subir para 3.4+/4.0 é
  **baixo risco** (poucas breaking changes; o Prism vira parser default, frozen
  string literals caminham para default — o projeto já usa `# frozen_string_literal`).
- O ganho real de perf num motor **I/O-bound** (o tempo do turno é dominado pela
  latência do provider LLM, não por CPU Ruby) é o **YJIT** ligado por padrão e
  mais maduro. Ligar YJIT (`RUBY_YJIT_ENABLE=1` / `--yjit`) é o item de maior
  retorno por menor esforço.
- **Benchmark por versão de Ruby (decisão do produto):** o loadtest deve medir o
  **delta entre o Ruby atual (3.3.5) e a nova versão** (3.4+/4.0), com e sem YJIT
  — não só "antes/depois do bump". Como o gargalo é I/O, a parte CPU-bound (parse,
  serialização, montagem de contexto/prompt, event loop) é onde o YJIT/nova versão
  aparecem; o `bench_store.rb` (CPU/SQLite puro, sem provider) isola esse sinal, e
  o `loadtest.rb` mede o turno ponta-a-ponta. Rodar a matriz **local E Railway**
  (o ambiente de deploy real pode ter perfil de CPU/IO diferente).
- **Ação:** (1) bump da versão + YJIT no runtime; (2) matriz de benchmark
  `{Ruby atual, Ruby novo} × {YJIT off, YJIT on} × {local, Railway}` via §1.4;
  (3) **relatório** comparativo (tabelas de TTFB/total/tokens/throughput + o
  `bench_store` CPU-bound) versionado no repo e uma **apresentação na doc**
  (`docs/BENCHMARKS.md`) incluindo a **comparação vs OpenClaw** (mesmo contrato
  SSE — ver §1.4). Medir antes de assumir o ganho.

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
  - **Litestream (opcional/configurável):** replicação contínua para S3 (backup/
    DR/restore) — HA barata sem trocar de banco. **Decisão do produto:** entregar
    como **opt-in configurável** (liga por env/flag, apontando bucket/credenciais),
    não ligado por padrão — quem quiser durabilidade externa habilita; quem roda
    single-box efêmero não paga o custo. Independe da topologia.
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
  3. **Litestream opt-in** para backup/DR (configurável por env/flag, desligado
     por padrão; barato, ortogonal à topologia).
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
  1. ✅ Doc "como comparar" reusando o `loadtest-gateway.mjs` contra o harness —
     ENTREGUE (`docs/LOADTEST.md`, PR #60).
  2. ✅ `scripts/loadtest.rb` (net-http, TTFB+total+tokens+P50/P95) — ENTREGUE.
  3. ✅ `scripts/loadtest-local.sh` (baseline 1 proc vs N procs do Falcon; checa
     "database is locked" — prova o §1.3) — ENTREGUE.
  4. ✅ **Comparação por versão de Ruby + relatório (§1.1) — ENTREGUE** (PRs #67/#69):
     matriz `{3.3.5, 4.0.6} × {YJIT off/on} × {local, Railway}` + `bench_cpu.rb`/
     `bench_store.rb` + rodada **vs OpenClaw** (mesmo contrato via `OPENCLAW_GATEWAY_URL`),
     consolidada em `docs/BENCHMARKS.md` (§2 CPU, §3 SQLite, §4a/§4c pernas local/Railway,
     §5 vs OpenClaw). Fecha §1.1 e §1.4.
  5. 🔴 **PENDENTE — loadtest de TRÁFEGO REAL (não-sintético):** todos os números acima
     usam um greeting fixo (1 turno, 0 tool call → não exercita achei-b2b nem o tool-loop).
     Falta um **replay de conversas reais**: uma ferramenta que sorteia mensagens variadas do
     corpus já extraído (**179 msgs reais** dos session logs em `openclaw/agents/*/sessions/
     *.jsonl`) e dispara com **`BIA_INTERNAL_API_TOKEN`** (de `achei-b2b/.env`) para os tool
     calls **baterem no achei-b2b local de verdade**. Mede o path completo sob carga (latência
     de tool + turnos multi-round). Identidades das lojas reconstruíveis de
     `openclaw/workspace/agent-store-<id>/*.md`. Casa com **evals §9** (as mesmas conversas
     golden servem de regressão de qualidade, não só de perf).

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
  - **Por último no roadmap (decisão do produto):** extrair em gems — `harness-core`
    (motor), `harness-server` (Rack/SSE), `harness-studio` (engine montável /
    mountable Rack app), `harness-otel`, e plugins como gems `harness-plugin-*`.
    Quem quer só o motor pega o core; quem quer a UI monta o studio. **É o item de
    MENOR prioridade** — só depois de docs/site (§5) e do resto estabilizado; o
    monorepo segue como default até lá (a fronteira de API já permite extrair sem
    reescrever, então adiar não custa opção).
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

### 3.2 Feedback de UI/UX — rodada 2 (2026-07-19)
**Contexto:** feedback do produto sobre o Studio pós-refresh (#62), com o
**agent-studio como referência visual** (screenshots 1.png/2.png de 19/07).
Portar o **padrão de UX**, não a stack (a regra do §3 continua: Hotwire, sem
front Node).

- **O que melhorou:** o menu/navegação ("melhorou muito").
- **Dores apontadas:** conteúdo ainda feio visualmente; **sem busca/filtros**
  (agents/tools/skills/sessões); **sem editor de markdown bom** para os prompts;
  **toggles feios**; falta refinamento geral.
- **O que o agent-studio faz bem (checklist de port):**
  - Layout **3 painéis com drill-down**: lista de agents (busca no topo + badge
    `owner`/`specialist`) → seções do agent (General/Prompts/Skills/File History
    + grupo SISTEMA: Modelo LLM/ToolCalls/Memória) → detalhe da seção.
  - **ToolCalls por grupo** com contador `N/N on`, toggle por grupo E por tool,
    estado `travada` (tool gated, não-editável) e aviso de política no topo
    ("Sem gate — recebe todas (mostradas ligadas). Desligue o que não quiser e
    salve."). Mapeia direto no nosso allowlist por grupo.
  - **Editor de prompt** com highlight de markdown (CodeMirror-like), arquivo-alvo
    visível (`AGENTS.md`), salvar com Cmd+S, e o prompt fatiado em **seções
    nomeadas** (Prompt principal/Identidade/Personalidade/Habilidades/Negócio/
    Ferramentas/Memória/Chat/Calendário/Usuário/Heartbeat) — casa com o formato
    de pack (AGENTS.md + companheiros) que o PackImporter já consome.
- **Ação:** (1) busca + filtros nas listas do Studio; (2) editor de prompt
  CodeMirror em modo markdown (highlight + preview; o CodeMirror já está no
  Studio para tools); (3) redesign dos toggles com estados on/off/travada +
  contadores `N/N on` por grupo; (4) passe de polish visual (tipografia,
  espaçamento, hierarquia) sobre o layout 3 painéis.
- **✅ ENTREGUE (#19, esta PR).** (1) island `list-filter` (busca client-side,
  CSP-safe) em agents/skills/tools/chats com contador e Esc-limpa; (2) editor de
  prompt com syntax-highlight markdown + toggle Preview (renderer markdown próprio,
  zero-dep) + salvar com Cmd/Ctrl+S; (3) matriz de tools redesenhada — switch
  `all tools`, contador `N/N on` vivo (island `toggle-counter`) e estado **locked**
  para tool no denylist (deny sempre vence, checkbox desabilitado); (4) passe de CSS
  (filter-bar, switch, subgroup de params, preview pane). **Junto foi surfaçada a
  config v2 (§10 / #18) na UI**, que antes só existia no domínio: Settings ganhou a
  seção *Model defaults* (`default_model`/`default_provider`/`fallback_models`/
  `utility_model`); o config do agente ganhou `params` (temperature/max_tokens/
  thinking, com coerção numérica) + `model fence` (`model_policy.allow`); e o
  Playground ganhou override de modelo por chat (pin no `create_session`, só em
  conversa nova). Deferido honesto: preview é um renderer mínimo (não CommonMark
  completo) e o layout 3-painéis com drill-down do agent-studio não foi portado
  (ficou no incremento de busca/toggles sobre o layout atual).
- **Fix de CSP descoberto testando no browser (Playwright MCP):** o
  `style-src 'self'` estrito bloqueava o `<style>` que o style-mod do CodeMirror
  injeta (base theme + o novo syntax-highlight) E a progress bar do Turbo → editor
  sem highlight + erros no console. Corrigido com **nonce por request** (Roda
  `add_style_src([:nonce, …])` + `<meta name="csp-nonce">` que o Turbo lê e o
  `EditorView.cspNonce` consome), **mantendo o CSP estrito** (sem `unsafe-inline`).
  Também limpou uma falha pré-existente (o editor nunca teve o base theme sob esse
  CSP). Verificado em tela: highlight renderiza, 0 erros de console. (`element.style.*`
  via CSSOM nunca foi bloqueado — só `<style>` injetado.)

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

- **5.1 Inglês em todo o código/testes/comentários.** 🔄 **EM ANDAMENTO.** Para
  OSS internacional isso é bloqueador. Trabalho **grande, porém mecânico** — em
  passes por módulo, com a suíte verde como rede. Progresso:
  - ✅ **1º passe (PR #63):** `lib/harness/**` (~114 arquivos) — comentários,
    docstrings e mensagens de erro/log; identificadores públicos preservados.
  - 🔄 **2º passe (em curso):** `server/`, `bin/`, `scripts/` composition-root,
    `config/`, comentários remanescentes do `studio/`, `Gemfile`.
  - ⬜ **Pendente:** nomes de teste em `spec/**`; mensagens travadas por contrato
    de spec (traduzir junto com a assert); strings model-facing (`desc:`/prompts);
    identificadores públicos (com cuidado p/ não quebrar contrato); **este próprio
    documento** (traduzir por último). O estado detalhado vive em
    `docs/TRANSLATION-TRACKER.md`. Ordem: comentários/mensagens → nomes de teste →
    identificadores públicos.
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
- **5.6 Onboarding LLM-first (`/start.md`).** O truque do Flue ("Read
  https://flueframework.com/start.md then help create my first agent"): servir do
  **próprio harness** um `start.md` endereçado ao coding agent do usuário —
  estruturado como skill (gather context → decisões com REGRAS, não prosa →
  build com paths/snippets exatos → checklist de auto-verificação → constraints
  contra os failure modes conhecidos: "nunca inventar API key", "não criar
  workflow só pra testar agente") — + um `/models.json` machine-readable + docs
  espelhadas em `.md` cru. É `rails new` reimplementado como prompt, com o
  generator sendo o agente que o usuário já tem. Custo baixíssimo (a surface
  HTTP já existe) e a maior alavancagem de DX da pesquisa do §8.1. Depende de
  §5.3/§5.4 existirem minimamente.
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
- **Ação:** ✅ **protótipo `harness-code` ENTREGUE (PR #61)** — toolset FS/shell
  (`plugins/harness-code/`) com approvals + sandbox (`Workspace`) reusando o motor,
  e CLI mínima (`examples/harness-code/`) sobre `/v1/responses`. Próximos passos
  (pós-OSS): frame `approval_requested` de 1ª classe no adapter, hard-kill de
  timeout no `bash`, diff preview no prompt de approval.

---

## 7. Aprendizado por conversas — knowledge graph / "wiki" por agente

**Recomendação: construir uma CAMADA DE APRENDIZADO que destila conversas + tool
calls num grafo de conhecimento por agente, retrievable no turno e curável por
humano no Studio.** 🟡 (alto valor de produto; diferencial — nem o Flue tem isso)

- **Por que dá pra fazer bem aqui:** o motor já tem as 4 peças que faltam à maioria:
  (a) **memória cross-session por agente** (MemoryStore), (b) **trace de tool calls**
  (ToolTraceStore — args + resposta, acabamos de entregar), (c) **Context Providers**
  (o ponto de injeção no turno — Memory/Skill/ToolSearch já injetam), (d) **skills**
  (conhecimento curado). Falta o LOOP que fecha: conversa → conhecimento → injeção.
- **Desenho (GraphRAG por agente):**
  1. **Captura (já temos a matéria-prima):** transcrições de sessão + ToolTraceStore
     (o que foi perguntado, qual tool rodou, o que voltou, o que funcionou/falhou).
  2. **Destilação (job em background / fim de sessão):** um passe LLM extrai
     **fatos + entidades + relações** (produtos, dúvidas frequentes, políticas,
     objeções, CEP↔CD, "cliente pediu X e resolveu com Y") → nós e arestas.
  3. **Store de grafo por agente:** nós (entidade/fato) + arestas (relação) +
     embeddings, em SQLite (tabelas `kg_nodes`/`kg_edges` + índice vetorial via
     `sqlite-vec`, ou cosine simples). Durável no mesmo backend, escopado por agente
     (isolamento por loja, como tudo aqui).
  4. **Retrieval no turno:** um `Context::Providers::Knowledge` novo — dado a
     mensagem, faz match semântico + **expande pelas arestas** (GraphRAG) e injeta
     os fatos relevantes no contexto (mesma mecânica do Memory provider, na escada
     de confiança do §3/Fase 6).
  5. **Feedback:** respostas + resultados de tool re-alimentam o grafo → melhora
     com o uso. Guardrails: dedup, **confiança/decay** (fato velho pesa menos),
     e **curadoria humana** (o "wiki").
- **O ângulo "wiki":** uma tela no Studio que mostra o grafo/fatos por agente,
  **editável pelo operador** — funde auto-aprendido + curado (aprovar/rejeitar/
  editar fatos). Casa com a skill `graphify` (grafo de conhecimento) que já usamos.
- **Riscos:** custo do passe de destilação (rodar em lote/assíncrono, não no turno);
  qualidade da extração (LLM-judge + curadoria); PII no grafo (masking + retenção).
- **Ação:** (1) `KnowledgeGraphStore` (nós/arestas/embeddings por agente); (2) job
  de destilação (sessão/trace → fatos, assíncrono); (3) `Knowledge` context provider
  (GraphRAG no turno); (4) tela wiki no Studio (curadoria). Começa **simples**:
  destilar fatos → memória (já injetada) antes do grafo completo.

---

## 8. Benchmark: Flue (`pi.dev`/pi-agent-core) — conseguimos chegar nesse nível?

**Resposta curta: já estamos no MESMO nível arquitetural — à frente em algumas
coisas — e atrás em DX/alcance de deploy e em 2–3 primitivos.** 🟡

O [Flue](https://github.com/withastro/flue) (time do Astro) é um **"agent harness
framework"** em TypeScript sobre o **pi-agent-core** (`new Agent({...})` — o
"pi.dev" é o loop de agente por baixo). É **exatamente a nossa categoria**. Os
primitivos dele: Agents (stateful autônomos), Workflows, **Sandboxes** (containers
virtual/local/remoto), **Durable Execution**, **Subagents**, Tools tipadas, Skills
(`SKILL.md`, progressive disclosure — idêntico ao nosso), MCP Servers,
Observability (OTEL/Braintrust/Sentry), **Channels** (Slack/Teams/Discord/GitHub).
Deploya em Node/Cloudflare/GitHub Actions/GitLab/Render/Daytona.

| Primitivo | Harness | Flue |
|-----------|---------|------|
| Agentes stateful + tool-loop | ✅ | ✅ |
| Skills `SKILL.md` + progressive disclosure | ✅ (igual) | ✅ |
| Tools tipadas (JSON Schema) | ✅ (+ tools-como-DADO, hot-reload) | ✅ (código TS) |
| MCP | ✅ (ingestão, Fase 7) | ✅ |
| Durable execution / resume | ✅ (checkpoint/recovery — **forte aqui**) | ✅ |
| Observability OTEL | ✅ | ✅ (+ Braintrust/Sentry) |
| Workflows | ✅ (registry) | ✅ |
| **Sandboxes** (exec de código em container) | ❌ (é o §6 `harness-code`) | ✅ |
| **Channels** (Slack/Teams/Discord/GitHub) | parcial (WhatsApp via achei, A2A, `/v1/responses`) | ✅ (1ª classe) |
| **Subagents** (delegação) | parcial (workflows/A2A) | ✅ (1ª classe) |
| **Deploy multi-runtime/edge** | ❌ (Ruby/Falcon; Railway) | ✅ (edge/CI) |
| **Aprendizado por conversa** (§7) | ❌ (proposto — **ninguém tem**) | ❌ |
| Tools-como-dado + ingestão por manifesto (hot) | ✅ (**diferencial**) | ❌ (tool = código) |
| Provider-agnóstico multi-LLM em runtime | ✅ | ✅ (via pi-agent-core) |

**Onde estamos À FRENTE:** tools-como-dado com hot-reload/manifesto (adicionar tool
sem deploy), durable execution/resume batido em produção, e um **piloto real
rodando** (WhatsApp→loja). **Onde o Flue lidera:** sandboxes, channels de 1ª classe,
deploy em edge/CI, e sobretudo **DX + comunidade** (TypeScript, CLI polida, docs).

**Conseguimos chegar lá?** Sim — o núcleo já está no nível. O caminho é: (a) DX/OSS
(§5 — docs, gems, inglês), (b) **channels como camada de 1ª classe** (§9), (c)
**sandboxes** (§6 `harness-code`), (d) **subagents** como primitivo limpo. A aposta
onde PODEMOS liderar: **tools-como-dado + aprendizado por conversa (§7)** — duas
coisas que o Flue não tem.

### 8.1 Deep-dive no core dos 4 projetos de referência (2026-07-19)

Analisamos o CÓDIGO (não só docs) de openclaw/openclaw, NousResearch/hermes-agent,
earendil-works/pi e withastro/flue. Fato estrutural: **Flue não é motor do zero —
ele embrulha o `pi-agent-core`** (pi = motor: loop puro ~800 linhas → `Agent`
stateful → `AgentHarness` durável; Flue = produto: workflows, channels, sandboxes,
config). É exatamente a nossa divisão core/produto. O que importa pro harness:

- **pi/Flue — roubar:**
  - **Durabilidade por fronteira de turno:** append de toda mensagem no
    `message_end` + mutações mid-run (modelo/tools) bufferizadas e flushed no
    `turn_end` (`save_point`); resume = fold do log + continue com o invariante
    "última msg = user/toolResult". Nosso checkpoint/resume já cobre isso, mas o
    **log de entries que inclui `model_change`/`active_tools_change`/`compaction`
    como ENTRIES** (não side-tables) é mais limpo — contexto vira um fold puro.
  - **Filas steering vs follow-up** com drain mode: steering interrompe ENTRE
    turnos; follow-up só dispara quando o agente terminou. A resposta certa pra
    "usuário digitou enquanto o agente rodava" (relevante p/ WhatsApp!).
  - **Regras de subagent (verbatim):** campos de CAPACIDADE (instructions/tools/
    skills/subagents) **nunca herdam** (omitido = nenhum); campos de AMBIENTE
    (model/thinking) herdam como default; filho sem durabilidade própria (vive no
    envelope do pai); depth cap + detecção de ciclo em definition-time; resultado
    do filho = tool result + id da sessão filha linkada.
  - **Defensivos:** `stop_reason: length` → falhar TODOS os tool calls do turno
    (args truncados podem validar e estar incompletos); nomes de tool reservados
    com erro alto; tool interrompida sem resultado durável NUNCA re-executa em
    recovery (marca "interrupted, unknown outcome").
  - **Workflows com escopo HONESTO:** o Flue explicitamente NÃO faz
    checkpoint/replay de código — workflow = função at-most-once com **run record
    durável + event stream + I/O validado por schema**; retry é do app
    (idempotency key). Nosso `WorkflowRegistry` deve copiar esse escopo (runId +
    eventos + validação via dry-schema), não virar Temporal.
- **OpenClaw — a filosofia que o mercado copiou + roubar:**
  - **"Agents como o OpenClaw trouxe ao mundo"** = agente como **entidade
    persistente definida por arquivos markdown num workspace** (AGENTS.md/SOUL.md/
    USER.md/IDENTITY.md/MEMORY.md + `memory/YYYY-MM-DD.md`/HEARTBEAT.md/BOOTSTRAP.md)
    + **main session** (a conversa rolante que é "a vida do agente") + **heartbeat**
    proativo. **Estamos alinhados:** o `generate-merchant-pack` produz exatamente
    esse formato e o PackImporter consome.
  - **Semântica de fonte de seleção de modelo** (o detalhe mais maduro — ver §10):
    pin do usuário falha ALTO; fallback automático se auto-recupera (reproba o
    primary, anuncia 1×); rotação de credencial DENTRO do provider antes de pular
    de modelo.
  - **Config estrito + `doctor --fix`:** recusa boot com chave desconhecida,
    last-known-good, toda migração de schema explícita ("no silent config compat")
    — a melhor disciplina de produtização do repo.
  - **Bindings** `(channel, account, peer) → agentId` most-specific-wins como
    primitivo de roteamento multi-tenant: dado puro, testável, UI-friendly — o
    shape certo p/ roteamento de merchants no achei-b2b.
  - **Heartbeat como spec pequena e completa** (token `HEARTBEAT_OK` + activeHours
    + isolatedSession + lightContext) — roubar verbatim quando chegar a vez.
  - **Pular:** control-plane WS + nodes/devices/apps nativos e o plugin SDK
    gigante (~60 extensions, ~20 hook points) — custo de 600 contribuidores, não
    alvo; nosso SSE `/v1/responses` já cobre o control-plane.
- **hermes-agent — escala brutal, arquitetura por acreção (216k stars):**
  - **Anti-exemplo que valida o nosso desenho:** `AIAgent` com ~95 kwargs e ~20
    callbacks de construtor, arquivos de 300–700KB — o loop precede um modelo de
    eventos; nosso Event Stream tipado é a resposta melhor.
  - **Roubar:** (a) registro declarativo de tools com **discovery sem import** +
    `check_fn` de disponibilidade + **budget de tamanho de resultado por tool** +
    toolsets compostos; (b) **durabilidade de delegação:** dispatch persistido,
    completion entregue **como turno NOVO quando idle** (nunca spliced no meio de
    um turno — preserva role alternation e prompt cache), claim/release +
    recovery de delegações abandonadas; (c) **verification-on-stop policy-only**
    (ledger passivo de evidência + 1 continuation bounded quando o modelo tenta
    parar após editar código sem evidência de teste) — a auto-correção mais
    barata por linha; (d) transport ABC estreito (só convert/normalize; retries/
    streaming/creds fora) — nosso boundary RubyLLM já é assim, manter.

**Resposta à pergunta "estamos alinhados / quão longe da produtização?":** no
MOTOR estamos no nível (loop, durabilidade — a nossa é mais forte que a dos
workflows do Flue —, skills, MCP, tools-como-dado à frente); na FILOSOFIA estamos
alinhados (pack = workspace de arquivos, como o OpenClaw). O delta de produtização
está em: DX/onboarding (§5.6 start.md, doctor), semântica de config de modelo
(§10), subagents/heartbeat como primitivos limpos (§8.1), e os gaps já mapeados
do §9 (evals, guardrails, channels, analytics).

---

## 9. O que falta pra ser produto de verdade (gaps de produto)

Além do que já está mapeado (escala §1, OSS §5, learning §7), os gaps que separam
"motor que funciona" de "produto pronto": 🟡

- **Evals / harness de qualidade** 🔴 — testes de COMPORTAMENTO do agente (não só
  unit): conversas-golden + LLM-judge, regressão quando muda prompt/tool/modelo.
  Hoje temos loadtest (perf) mas não eval (qualidade). É o que o Flue cobre com
  Braintrust. **Sem isso, mexer no prompt é no escuro.** **Atalho já disponível:** o
  corpus de **179 conversas reais** extraído para o loadtest real (§1.4 ação 5 / #6b) é a
  matéria-prima direta das conversas-golden — o mesmo replay serve de perf E de eval.
- **Guardrails / segurança de conteúdo** 🔴 — moderação, PII, defesa a
  jailbreak/prompt-injection, validação de saída. Crítico p/ marca em produção.
- **Channels de 1ª classe** 🟡 — hoje WhatsApp entra via achei-b2b. Uma camada de
  adapters (web-widget, Slack, Instagram, etc.) abre novos casos sem reescrever o
  motor. (Paridade com o Flue.)
- **Analytics / dashboard operacional** 🟡 — métricas por conversa (resolução,
  CSAT, custo/turno, taxa de sucesso de tool, abandono). O trace (§3.1) é a
  matéria-prima; falta agregação + tela.
- **Handoff humano** 🟡 — a skill `escalation-to-human` existe; falta o produto:
  inbox do operador, assumir/devolver conversa, notificação.
- **Custo/orçamento por agente/tenant** 🟡 — teto de gasto, alerta, corte gracioso
  (o usage por turno já é capturado — Fase 6).
- **Rate-limit / anti-abuso** na borda 🟡 — por chat/tenant.
- **A/B de prompt/modelo por agente** 🟢 — comparar variações com tráfego real.
- **Onboarding self-serve de loja** 🟢 — provisionar um agente pela UI (o
  PackImporter + Studio já dão a base).
- **Versionamento/rollback de config** 🟢 — prompts/tools já têm histórico; falta
  o "publicar versão / reverter" no produto.
- **Secrets/vault** 🟡 — hoje ENV; um resolvedor de secrets (o seam já existe na
  ingestão de tools) evoluindo p/ vault.

**Ordem sugerida p/ "produto pronto":** evals (🔴, destrava iterar com segurança) →
guardrails (🔴) → analytics/handoff (operação) → channels (crescimento) → o resto
conforme demanda.

---

## 10. Configuração de LLM — providers, modelo default, overrides (feedback 2026-07-19)

**Recomendação: fechar o "config de LLM v2" — default de plataforma + override por
Agent (já existe) e por Chat (novo) + fallbacks com semântica de fonte — em cima do
que o RubyLLM já oferece nativamente.** ✅ **ENTREGUE** (resolução v2; ver nota abaixo)

> **Fechado (item 18):** `Harness::ModelResolver` resolve o modelo no início do turno
> na precedência **Chat > Agent > default de plataforma**, aplica `model_policy` sobre o
> modelo RESOLVIDO (um pin de chat nunca escapa da cerca do agente), resolve a cadeia de
> fallback + a **fonte de seleção** (`:chat`/`:agent`/`:platform_default`) e o flag
> `pinned` (pin de usuário "falha ALTO" — sem fallback silencioso). Novos slots:
> `default_model`/`default_provider`/`fallback_models`/`utility_model` em Settings; `model`
> agora OPCIONAL no profile; `params` (temperature/max_tokens/thinking) e `model_policy`
> por agente; override por chat via `POST :create_session {model, provider}` (guardado num
> slot reservado `vars["__llm__"]`, nunca renderizado no prompt). A fonte resolvida viaja no
> `usage` do turno (telemetria/billing) e o gotcha de mutação global está documentado no
> `LLMConfigurator`. **Deferido (follow-up honesto):** a ROTAÇÃO em tempo de execução pela
> cadeia de fallback (retry cross-modelo mid-turn) — hoje a cadeia é resolvida e exposta,
> mas a troca mid-stream (que mexe no laço de streaming) fica para uma fatia própria. O
> `utility_model` está no slot mas ainda não é consumido (destilação §7/compaction).

- **O que JÁ existe (mais do que parecia):**
  - **N providers em runtime:** `LLMProviderStore` (CRUD com masking de `api_key`
    via sentinela) + `LLMConfigurator` (aplica/desfaz `<api>_api_key`/`_api_base`
    no RubyLLM **a quente, sem restart**) + tela em Settings (api/base_url/
    auth_header/api_key/models). O RubyLLM cobre ~13 providers nativos + qualquer
    endpoint OpenAI-compatible via `openai_api_base`.
  - **Modelo por Agent:** `AgentProfile#model/provider` →
    `RubyLLM.chat(model:, provider:, assume_model_exists:)` no `Executor#create_chat`.
  - Settings globais já cobrem: streaming, request_timeout, max_retries,
    turn/tool timeout, compaction (keep_last).
- **Gaps (o pedido do produto):**
  1. **Modelo default de plataforma:** hoje `model:` é OBRIGATÓRIO no profile e o
     "default" real é `ENV["DEEPSEEK_MODEL"]` no composition root
     (`config/deployment.rb`). Ação: `default_model` em Settings (mapeia p/
     `RubyLLM.config.default_model`), `model` opcional no profile, resolução
     **Chat > Agent > default de plataforma**.
  2. **Override por Chat/sessão:** não existe. RubyLLM suporta nativo (`model:`
     por chat criado; `with_model` troca mid-conversation preservando histórico).
     Ação: `model`/`provider` opcionais na sessão, aplicados no `create_chat`;
     decidir se expõe no `POST /v1/responses` ou só no Studio/Admin.
  3. **Params de geração por Agent:** temperature/max_tokens/thinking não são
     expostos no profile.
  4. **Fallbacks + semântica de fonte (OpenClaw, §8.1):** `primary → fallbacks[]`
     com o detalhe maduro — **pin do usuário falha ALTO** (nunca fallback
     silencioso); **fallback automático se auto-recupera** (reproba o primary,
     anuncia a transição 1×); rotação de credencial DENTRO do provider antes de
     pular pro próximo modelo. + slot **`utility_model`** (tarefas internas
     baratas: títulos, destilação do §7, compaction).
  5. **`model_policy.allow`** por agente (refs exatas + wildcard `provider/*`) —
     governança barata de quais modelos um agente pode usar.
- **Gotchas RubyLLM (pesquisa 2026-07-19):** o config global é **singleton mutável
  — nunca mutar por request** (o `LLMConfigurator` hoje faz `RubyLLM.configure` a
  quente: ok como operação admin rara, documentar a corrida); credenciais POR
  TENANT exigem `RubyLLM.context` (dup isolado do config, cachear por tenant) —
  contexto é para CREDENCIAIS/endpoint/timeout variarem, não para modelo variar;
  `assume_model_exists: true` exige `provider:` e perde metadata do registry
  (context window, pricing); validar override no write com
  `RubyLLM.models.find(model, provider)` rescue `ModelNotFoundError`; logar
  `chat.model.id`/`chat.model.provider` RESOLVIDOS (alias→ID varia por provider)
  p/ telemetria/billing; timeout/retries são config-level → budget de latência
  por agente também pede context.
- **Onde MAIS ter configs desse tipo (inventário Flue/OpenClaw como checklist):**
  - **Plataforma (Settings):** `default_model`, fallbacks, `utility_model`,
    logging/nível.
  - **Por agente (profile):** model/provider ✅, params de geração, compaction
    (reserve/keep tokens), limits ✅ (`max_tool_calls`), `model_policy`, memória
    on/off ✅, sandbox (harness-code), heartbeat (futuro).
  - **Por chat/sessão:** model override, thinking level.
  - **Por tool:** timeout (✅ global; falta por-tool), **max result size**
    (hermes), budget por tool.
- **Ação:** (1) ✅ `default_model` em Settings + `model` opcional no profile +
  resolução Chat>Agent>default (`ModelResolver`); (2) ✅ override por sessão
  (`:create_session {model, provider}` → `vars["__llm__"]`); (3) ✅ params de geração
  no profile (`params` → `with_temperature`/`with_max_output_tokens`/`with_thinking`);
  (4) 🟡 fallbacks com selection-source — **cadeia + `pinned`/`source` RESOLVIDOS e
  expostos**; rotação mid-turn deferida; (5) ✅ `model_policy.allow` (exato + wildcard
  `provider/*`), enforced no modelo resolvido; (6) ✅ gotcha de mutação global
  documentado no `LLMConfigurator`.

---

## Priorização recomendada (sequenciamento)

| # | Item | Tema | Prioridade | Depende de |
|---|------|------|------------|------------|
| 1 | Dockerfile + Railway (1 box, SQLite WAL já on) p/ shadow do piloto | Infra | ✅ ENTREGUE | — |
| 2 | Loadtest + doc de comparação (`loadtest.rb`/`-local.sh` + `LOADTEST.md`) | Perf | ✅ ENTREGUE | 1 |
| 3 | Trace de tool calls no viewer do chat (§3.1) | UI/UX | ✅ ENTREGUE | — |
| 4 | Refresh de UI/UX do `studio/` (§3/#10) | UI/UX | ✅ ENTREGUE | — |
| 5 | Protótipo `harness-code` (toolset FS/shell + CLI + sandbox) | Ideias | ✅ ENTREGUE | — |
| 6 | Bump Ruby + YJIT **+ matriz de benchmark `{Ruby atual/novo}×{YJIT}×{local/Railway}` + relatório vs OpenClaw** (`docs/BENCHMARKS.md`) | Perf | ✅ ENTREGUE | 2 |
| 6b | **Loadtest de TRÁFEGO REAL** (replay do corpus de 179 msgs + tool calls no achei-b2b; §1.4 ação 5) — o que fecha o "não-sintético" | Perf/Produto | 🔴 | 6, 10 |
| 7 | Medir teto de escrita SQLite N-procs (✅ via `bench_store.rb`) + **Litestream opt-in/configurável** (backup/DR) | Infra | 🔴 | 2 |
| 8 | Migração PT→EN — 1º passe ✅; **2º passe 🔄 em curso** | Docs/OSS | 🔴 (p/ OSS) | — |
| 9 | Docs de arquitetura + diagramas + README + site | Docs/OSS | 🔴 (p/ OSS) | 8 |
| 10 | **Evals / harness de qualidade** (golden + LLM-judge; §9) | Produto | 🔴 | — |
| 11 | **Guardrails** (moderação/PII/anti-injection; §9) | Produto | 🔴 | — |
| 12 | Escala horizontal (SE preciso): sharding por tenant + sticky, ou LiteFS, ou adapter Postgres | Infra | 🟡 | 7 |
| 13 | Doc dos 2 tiers de plugin + 2–3 plugins nativos + convenção de hub | Plugins | 🟡 | 9 |
| 14 | **Aprendizado por conversa** — knowledge graph/wiki por agente (§7) | Produto | 🟡 | 10 |
| 15 | **Channels de 1ª classe** (web-widget/Slack/…; §8/§9) | Produto | 🟡 | — |
| 16 | Analytics/dashboard + handoff humano (§9) | Produto | 🟡 | 3 |
| 17 | **Extração em gems** (`harness-core/-server/-studio/-otel`) — **POR ÚLTIMO** | Ecossistema | 🟢 (último) | 9, 13 |
| 18 | **Config de LLM v2**: default de plataforma + override por Chat + fallbacks/selection-source + `model_policy` (§10) | Config | ✅ ENTREGUE (rotação mid-turn deferida) | — |
| 19 | UI/UX rodada 2: busca/filtros + editor markdown de prompt + toggles/polish (§3.2) + surfaçar config v2 na UI | UI/UX | ✅ ENTREGUE (3-painéis drill-down deferido) | 4 |
| 20 | Onboarding LLM-first: `/start.md` + `/models.json` + docs em `.md` (§5.6) | Docs/OSS | 🟡 | 9 |
| 21 | **Subagents como primitivo** (isolamento Flue + durabilidade de delegação hermes; §8.1) | Produto | 🟡 | — |
| 22 | Workflows expostos: runId + event stream + I/O validado — escopo honesto do Flue (§8.1) | Produto | 🟢 | — |
| 23 | Config estrito + `harness doctor --fix` (§8.1) | Infra/DX | 🟡 | — |

**Três trilhos paralelos naturais:**
- **Produto/Escala** (1–6 entregues → **6b loadtest de tráfego REAL** (fecha o
  "não-sintético", casa com evals #10) → **7 Litestream opt-in** → 12 escala): piloto →
  produção → múltiplas lojas.
- **OSS/Ecossistema** (8 migração → 9 docs → 13 plugins → **17 gems, por último**):
  prepara o projeto para a comunidade (paridade de DX com o Flue — §8). A extração em
  gems é o **último** item do trilho — o monorepo é o default até docs/site prontos.
- **Produto pronto** (10→11→14→15→16): evals + guardrails primeiro (destravam iterar
  com segurança), depois learning/channels/analytics. É o que separa "motor" de
  "produto" e onde dá pra **liderar** (learning §7 + tools-como-dado, que o Flue não tem).

Decisões que **destravam** os trilhos e dependem de você/produto: **onde hospedar**
(Railway→k8s) e **quando "abrir"** o projeto (dispara o trilho OSS, começando pela
migração para inglês — em curso).

> **CI/workflow: adiado por ora (decisão do produto).** O repo não tem
> `.github/workflows`; os PRs são validados por **code-review + suíte rodada
> localmente** antes do merge. Montar um workflow (bundle + rspec nos PRs) fica
> para quando o fluxo de contribuição justificar (provável junto do trilho OSS,
> §5.5).

---

## Deferrals herdados (contexto)

- **Fase 7 Etapa E:** transporte MCP real (stdio/sessão/unwrap — só POST JSON-RPC
  stateless hoje), injeção de credencial da instância MCP no binding, corte
  dinâmico de schema por flag (piloto usa allowlist estática).
- **Motor:** hooks que não são tools (card dispatch/carrossel, sentiment→override),
  multi-provider/route por turno — produto marcou como não-necessários para o
  piloto.
