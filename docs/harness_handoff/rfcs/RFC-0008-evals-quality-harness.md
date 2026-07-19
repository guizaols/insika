---
rfc: "0008"
title: Evals & Quality Harness
status: Draft
type: Componente
created: 2026-07-19
supersedes: []
depends_on: ["0001", "0002", "0005", "0007"]
---

# RFC-0008 — Evals & Quality Harness

> **Status:** Draft. Detalha o subsistema de **avaliação de comportamento** do
> agente (item #10 do FOLLOWUP). Não é a constituição (0001) nem substitui a
> pipeline (0002) — descreve UM subsistema novo, sob as regras de RFC-0000.

## 1. Problema

Hoje o repo tem **teste de unidade** (RSpec, ~1400 exemplos, determinístico) e
**loadtest** (perf: TTFB/tokens/throughput — `docs/BENCHMARKS.md`). Não tem
**eval**: teste de *comportamento* do agente ponta-a-ponta. Consequência direta
(FOLLOWUP §9): **mexer em prompt/tool/modelo é no escuro** — não há rede que pegue
uma regressão de qualidade (a Bia parou de chamar `search_products`? passou a
alucinar CEP? ficou grosseira?) quando se troca o prompt ou o `default_model`
(agora fácil de trocar via #18/#19).

O motor já tem as peças que a maioria dos frameworks de eval precisa montar do
zero: `/v1/responses` (SSE drop-in), `ToolTraceStore` (args + resposta + status
por turno — RFC-0007/§3.1), fonte de seleção de modelo no `usage` (#18), e um
**corpus real já extraído** (179 msgs de user reais dos session logs do OpenClaw).

## 2. Objetivos / Não-objetivos

**Objetivos**
- Rodar um conjunto de **conversas-golden** contra um agente real e produzir um
  **veredito por conversa** (passou/falhou + score + porquê).
- Reusar o **mesmo replay do #6b** (loadtest de tráfego real): um replay serve de
  perf E de qualidade — não construir dois harnesses.
- Detectar **regressão** ao mudar prompt/tool/modelo: baseline + threshold + diff.
- Assertivas **determinísticas** (tool X foi chamada, 0 vazamento de PII/secret)
  E **subjetivas** (resolveu a dúvida? tom ok?) via **LLM-judge**.

**Não-objetivos (agora)**
- Não é dataset de fine-tuning nem RLHF.
- Não roda no CI por padrão (é não-determinístico, custa tokens, exige chave de
  provider + achei-b2b local) — roda **on-demand** e antes de mudanças sensíveis.
- Não substitui o RSpec (unidade continua sendo a rede determinística).
- Não é observabilidade de produção (isso é analytics, §9/#16).

## 3. Desenho

Três peças, todas **fora do core** (o eval é um *cliente* do motor, como o
loadtest — fala pela API pública, nunca lê store direto):

```
corpus (jsonl real) ──▶ [golden set]  ──▶ [runner: replay via /v1/responses]
                                                   │  (tool calls reais no achei-b2b)
                                                   ▼
                                          [trace do turno + resposta]
                                                   │
                                    ┌──────────────┴───────────────┐
                                    ▼                              ▼
                        [asserts determinísticos]         [LLM-judge (rubrica)]
                                    └──────────────┬───────────────┘
                                                   ▼
                                     [relatório + gating vs baseline]
```

### 3.1 Golden set (formato)

Um golden é um arquivo de dados (YAML/JSON em `evals/golden/<agent>/*.yml`), **não
código**, no espírito tools-como-dado. Cada caso:

```yaml
id: cacau-frete-cep
agent: bia-cacau
turns:                       # a conversa a reproduzir (do corpus real, curada)
  - user: "qual o frete pro 01310-100?"
expect:
  tools_called: [search_products?, shipping_quote]   # `?` = opcional
  must_not:
    - pii_leak            # asserção nomeada (CPF/telefone/token no output)
    - tool_error
  rubric: |               # critério p/ o LLM-judge (linguagem natural)
    Deve cotar frete pra São Paulo capital, sem inventar prazo, e sem prometer
    desconto não confirmado. Tom cordial e objetivo.
  min_score: 0.7          # nota mínima do judge (0..1) p/ passar
```

A matéria-prima são as **179 msgs reais** (`openclaw/agents/*/sessions/*.jsonl`);
a curadoria transforma um punhado delas em goldens com `expect`. Começar pequeno
(**~15–20 casos** cobrindo os fluxos-quentes: produto, frete, objeção, fora-de-
escopo) e crescer.

### 3.2 Runner (compartilhado com #6b)

Um `scripts/eval.rb` (ou `evals/runner.rb`) que:
1. lê o golden set;
2. para cada caso, cria sessão e dispara os turnos via **`POST /v1/responses`**
   (mesma superfície do loadtest; tool calls batem no **achei-b2b local** com
   `BIA_INTERNAL_API_TOKEN`);
3. coleta a resposta + o **trace de tool calls** (`ToolTraceStore`, já persistido)
   + o `usage` (modelo resolvido/fonte — #18);
4. entrega tudo pro avaliador (§3.3).

O **#6b** é o mesmo passo 1–2 medindo latência; **#10** adiciona 3–4. Entregar o
runner uma vez, com dois modos (`--mode perf|eval|both`). No modo `perf`, as
métricas são as mesmas do `scripts/loadtest.rb` (TTFB, total, tokens, P50/P95,
taxa de erro), agora sobre tráfego real — o que fecha o gap do #6b: latência de
tool call + turnos multi-round sob carga, coisa que o greeting sintético não
exercita.

**Pré-requisito de ambiente:** os agentes-alvo (`bia-cacau` etc.) precisam existir
no harness sob teste. Provisionar via **PackImporter** a partir dos packs reais em
`openclaw/workspace/agent-store-<id>/*.md` (mesma identidade das lojas do piloto)
— o runner documenta/automatiza esse passo para a rodada ser reproduzível do zero.

### 3.3 Avaliador (2 camadas)

- **Determinístico (barato, sempre roda):** `tools_called`/`must_not` viram checks
  puros sobre o trace — tool presente? status ok? regex de PII/secret no output?
  Zero custo de token, zero flakiness. É o que pega as regressões grosseiras.
- **LLM-judge (rubrica):** um passe LLM que recebe (conversa, resposta, rubrica) e
  devolve `{score: 0..1, pass: bool, reason}`. Roda com o **`utility_model`** (slot
  já existe em Settings — #18 — hoje sem consumidor; este é o primeiro). Mitigar
  flakiness: judge com temperatura 0, rubrica objetiva, e **quorum opcional**
  (N=3, mediana) para casos de fronteira.

### 3.4 Relatório & gating

Saída em `evals/reports/<timestamp>.json` + um sumário markdown (como
`BENCHMARKS.md`): por caso pass/fail + score + motivo; agregados por agente/fluxo.
**Baseline:** um `evals/baseline.json` versionado; o runner compara e falha (exit≠0)
se algum caso regride além de um `--tolerance`. É o que se roda **antes de mergear**
uma mudança de prompt/tool/modelo.

## 4. Decisões (com recomendação)

| # | Decisão | Recomendação |
|---|---------|--------------|
| D1 | Golden = output esperado literal, ou rubrica? | **Rubrica** (LLM-judge) + asserts determinísticos. Output literal é frágil com LLM não-determinístico. |
| D2 | Quem julga? | **`utility_model`** (Settings, #18), temp 0. Configurável; começa no mesmo provider da Bia. |
| D3 | Runner separado do loadtest? | **Não** — um runner, `--mode perf/eval/both`. Fecha #6b e #10 juntos. |
| D4 | Roda no CI? | **Não por padrão** (custo/chave/não-determinismo). Comando on-demand + gate manual pré-merge. Reavaliar no trilho OSS. |
| D5 | Onde vive? | `evals/` (goldens + runner + baseline + reports) — fora de `spec/`. Não é a suíte RSpec. |
| D6 | Dependência do achei-b2b? | Tool calls reais **por default** (fidelidade), com `--stub-tools` p/ rodar sem o achei-b2b (isola o julgamento do prompt do estado do backend). |

## 5. Faseamento

1. **Fase A — runner + asserts determinísticos** (sem LLM-judge): replay do corpus
   + checks de tool/PII sobre o trace + relatório. Já pega regressão grossa e
   entrega o **#6b** (modo perf) de brinde. Baixo risco, zero custo de judge.
2. **Fase B — LLM-judge + rubricas**: adiciona score subjetivo + `utility_model`
   (primeiro consumidor do slot) + quorum opcional.
3. **Fase C — gating + baseline**: `baseline.json` + `--tolerance` + sumário md;
   vira o gate pré-merge de mudanças de prompt/modelo.

Fase A já é útil sozinha; B e C incrementam.

## 6. Riscos

- **Flakiness do judge** → temp 0, rubrica objetiva, quorum, e preferir asserts
  determinísticos onde der.
- **Custo de token** → on-demand, `utility_model` barato, corpus enxuto.
- **Deriva do corpus/PII** → goldens são dados versionados; mascarar PII na
  curadoria (o `ToolTraceStore` já mascara secrets).
- **Acoplamento ao achei-b2b** → `--stub-tools` isola o eval de prompt do estado do
  backend.

## 7. Questões em aberto

- Curadoria dos goldens: manual (produto escolhe os casos) vs semi-automática
  (clusterizar as 179 msgs por intenção e amostrar)?
- Quorum do judge liga por padrão ou só em caso de fronteira?
- Baseline por-agente ou global? (provável por-agente, já que cada loja tem prompt
  próprio.)

## 8. Relação com outras RFCs / itens

- **RFC-0002 (pipeline)** e **RFC-0005 (context/memory)**: o eval exercita o turno
  completo por fora, não muda a pipeline.
- **RFC-0007 (control UI)**: um futuro painel de evals no Studio (fora de escopo
  aqui) leria os reports — o `ToolTraceStore` já é a base.
- **FOLLOWUP #6b** (loadtest real): **mesmo runner**. **#18** (config v2): fonte de
  modelo no `usage` + `utility_model` como judge. **#9** (evals §9): esta RFC é a
  materialização.
