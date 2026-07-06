---
rfc: "0001"
title: Harness Architecture
status: Active
type: Constituição
created: 2026-07-05
supersedes: ["Harness v1", "Harness v2", "Harness v2.1", "Harness v3", "Harness v4"]
depends_on: []
---

# RFC-0001 — Harness Architecture

> **Constituição do projeto.** Este documento define a arquitetura estável do
> Harness: visão, princípios, plataformas, modelo conceitual e fronteiras. Ele
> **não** descreve *como* cada componente é implementado — isso vive nas RFCs de
> Componente (ver RFC-0000). Muda raramente, e só por emenda datada (§10).

---

## 1. Visão

Harness é uma **Agent Runtime Platform** construída sobre RubyLLM. Não fornece
inteligência nem uma nova abstração de agente — fornece a **infraestrutura
operacional** para executar agentes em produção.

> RubyLLM responde "como construir agentes?".
> Harness responde "como executar agentes em produção?".

A divisão é permanente e é parte da identidade do projeto: **RubyLLM é
inteligência, Harness é operação. Nada duplicado.**

---

## 2. Princípios de Design

Estes princípios são a base constitucional. Componentes os detalham; nenhum
componente pode violá-los.

1. **RubyLLM First.** Toda interação com LLM é do RubyLLM. Harness nunca
   reimplementa providers, chat, streaming, tool calling, agents, workflows,
   embeddings, MCP ou instrumentation.
2. **Uma única pipeline de execução.** Existe exatamente uma pipeline canônica
   (detalhada na RFC-0002). Toda feature integra a ela; nenhum componente cria um
   fluxo de execução paralelo.
3. **Reuse First.** Não se reinventa o que o ecossistema resolve. Sem job runner
   externo — durabilidade é um store plugável. Observabilidade reaproveita
   `RubyLLM::Instrumentation`.
4. **Standalone / OpenClaw.** Harness é um processo próprio, não um app nem
   plugin de Rails. "Núcleo Ruby puro" é inegociável.
5. **Command-Driven.** Toda interação vira um Command. Transportes só traduzem
   requisições em Commands. O Runtime executa Commands, nunca endpoints.
6. **Catalog ↔ Registry.** Conteúdo não-executável (skills, prompts, templates) →
   Catalogs. Componentes executáveis (tools, workflows, plugins, policies,
   capabilities) → Registries.
7. **Actor-Based Execution.** Cada Task é um Actor sobre Async/Fibers, permitindo
   pause/resume, cancelamento cooperativo e concorrência sem threads.
8. **Context fora do Runtime.** O Runtime nunca monta prompt. Contexto é
   responsabilidade exclusiva da Context Platform.
9. **Middleware modifica, Hooks alteram, Events observam.** Três papéis distintos,
   nunca confundidos.
10. **Convention over Configuration.** Skills e prompts seguem o padrão aberto
    AgentSkills (SKILL.md), portável com OpenClaw/Claude Code/Codex.
11. **Extensível por padrão.** Tudo é descoberto dinamicamente e estendido via
    Plugins/Middleware/Hooks. Núcleo pequeno.

---

## 3. Escopo

**Harness É:** um runtime com uma pipeline canônica que executa RubyLLM
Agents/Workflows; sessões, tasks e execuções; quatro plataformas; catálogos e
registries com descoberta dinâmica; persistência plugável; servidor com streaming.

**Harness NÃO é:** framework de LLM (RubyLLM); app ou plugin de Rails (é
standalone); job runner de propósito geral; sistema de observabilidade próprio;
provedor de canais (WhatsApp/Slack ficam no consumidor).

**Modelo de deploy:** serviço standalone estilo OpenClaw — processo long-lived,
Async/Fibers. Consumidores (ex.: Agent.Shop) falam por HTTP, exatamente como já
consomem o OpenClaw. O Harness não conhece canais.

---

## 4. Arquitetura de Plataforma

Quatro plataformas independentes, num único processo long-lived.

```
   Consumidor (Agent.Shop, dono do WhatsApp)  ──HTTP/SSE──►  igual ao OpenClaw
                                │
   ┌────────────────────────────────────────────────────────────────┐
   │             HARNESS  (processo long-lived, Async/Fibers)         │
   │                                                                  │
   │  ┌───────────────── Service Platform ─────────────────────────┐ │
   │  │  HTTP · SSE · WebSocket · CLI · SDKs                        │ │
   │  │  (só traduzem requisições em Commands)                      │ │
   │  └───────────────────────────┬────────────────────────────────┘ │
   │                              ▼  Commands                          │
   │  ┌──────────── Execution Platform  (pipeline: RFC-0002) ──────┐  │
   │  │  Command Bus · Runtime · Task Engine (Actors) ·            │  │
   │  │  Session Manager · Scheduler · Event Stream               │  │
   │  └───────┬───────────────────────────────────┬───────────────┘  │
   │          ▼                                   ▼                    │
   │  ┌── Context Platform ──┐         ┌── Extensibility Platform ──┐  │
   │  │ Skill/Prompt Catalog │         │ Registries (Tool/Workflow/ │  │
   │  │ Context Providers     │        │  Plugin/Policy/Capability)  │  │
   │  │ Policies · Memory     │        │ Plugins · Middleware · Hooks│  │
   │  │  (RFC-0005)           │        │  (RFC-0003, RFC-0004)       │  │
   │  └──────────────────────┘         └─────────────────────────────┘ │
   │                              │                                     │
   │                              ▼                                     │
   │        RubyLLM Agent / Workflow → RubyLLM → Provider              │
   │                                                                   │
   │  Persistence (RFC-0006): Session/Task/Checkpoint/Artifact/Plugin  │
   │               Stores (memory · sqlite · filesystem — plugáveis)   │
   └────────────────────────────────────────────────────────────────┘
```

- **Execution Platform** — coordena a execução via a pipeline canônica
  (**RFC-0002**): Command Bus, Runtime, Task Engine (Actors), Session Manager,
  Scheduler, Event Stream.
- **Context Platform** — monta contexto: Catalogs, Context Providers, Policies,
  Memory (**RFC-0005**). O Runtime nunca monta prompt.
- **Extensibility Platform** — resolve executáveis e estende a execução:
  Registries, Plugins (**RFC-0003**), Middleware, Hooks, Capabilities
  (**RFC-0004**).
- **Service Platform** — expõe o runtime; todo transporte traduz para Commands.

---

## 5. Modelo Conceitual

A separação **Catalog ↔ Registry** organiza tudo e resolve a colisão histórica
de "Skill" (asset vs executável).

| Conceito       | O que é                                  | Onde vive        | Executável? |
|----------------|------------------------------------------|------------------|-------------|
| **Skill**      | instrução SKILL.md (progressive)         | Skill Catalog    | não         |
| **Prompt**     | template de prompt                       | Prompt Catalog   | não         |
| **Tool**       | operação atômica (`RubyLLM::Tool`)       | Tool Registry    | sim         |
| **Workflow**   | orquestração (código Ruby)               | Workflow Registry| sim         |
| **Agent**      | config + loop (RubyLLM::Agent / Profile) | —                | sim         |
| **Capability** | intenção → implementação                 | Capability Reg.  | indireção   |
| **Policy**     | regra pré-execução (allow/deny, custo)   | Policy Registry  | sim         |
| **Plugin**     | pacote de extensão                       | Plugin Registry  | sim         |
| **Command**    | intenção de interação                    | Command Bus      | —           |
| **Session**    | conversa persistente                     | Session Store    | —           |
| **Task**       | unidade de trabalho (Actor)              | Task Store       | —           |
| **Execution**  | uma tentativa de uma Task                | Checkpoint Store | —           |
| **Context Provider** | fonte de um pedaço de contexto     | Context Platform | sim         |
| **Middleware** | modifica a execução                      | Extensibility    | sim         |
| **Hook**       | altera comportamento no lifecycle        | Extensibility    | sim         |
| **Event**      | fato observacional                       | Event Stream     | não         |

> **Skill vs Workflow:** capacidade executável de alto nível (Research, Planning)
> é um **Workflow** (Registry). "Skill" é o asset SKILL.md (Catalog). A
> constituição fixa esta distinção; os detalhes de cada um vivem nos Componentes.

---

## 6. Relação com RubyLLM

| RubyLLM (inteligência)   | Harness (operação)                        |
|--------------------------|-------------------------------------------|
| Providers                | Runtime Executor                          |
| Chat                     | Session Manager                           |
| Tool Calling             | Task Engine + Tool Execution              |
| Agents                   | Command Bus + Scheduler                    |
| Agentic Workflows        | Workflow Registry                         |
| MCP                      | Plugin System                             |
| Instrumentation          | Event Stream (+ bridge opcional)          |
| Embeddings               | Memory / Stores                           |
| Model Selection          | Capability Resolution                     |
| Streaming                | Service Platform                          |

Responsabilidades complementares e permanentes.

---

## 7. Fronteiras de Componente

A constituição declara *que* estes componentes existem. O *como* de cada um é uma
RFC de Componente:

| Subsistema                    | RFC de Componente |
|-------------------------------|-------------------|
| Pipeline canônica de execução | RFC-0002          |
| Plugin System & manifesto     | RFC-0003          |
| Capability Resolution         | RFC-0004          |
| Context Providers & Memory    | RFC-0005          |
| Persistence & Stores          | RFC-0006          |

Novos subsistemas entram como novas RFCs de Componente, não como seções aqui.

---

## 8. Nomenclatura & Namespace

Decisão a fechar antes do primeiro release público (muda nome de gem e
namespaces): "Harness" é um termo sobrecarregado (já designou eval/regression,
território de `RubyLLM::Tribunal`); o prefixo `RubyLLM::` sinaliza oficialidade
(coerente com Schema/MCP/Instrumentation como projetos de comunidade). Opções:
manter `RubyLLM::Harness` ou adotar nome próprio com o tópico `ruby-llm`.

---

## 9. Estado transitório

Roadmap, status de implementação e o mapeamento com o código **não pertencem à
constituição**. Vivem em `BACKLOG.md`, que pode mudar a qualquer momento sem
emenda.

---

## 10. Histórico de Emendas

Emendas entram aqui como adendos datados, preservando o texto original acima.

- **2026-07-06 — Emenda 1 (escopo do princípio 5, Command-Driven).**
  O princípio 5 ("Toda interação vira um Command") passa a ser lido como:
  *Commands cobrem interações de **mutação**; **consultas** são leituras da
  Service Platform diretamente sobre os stores, sem passar pelo Runtime.*
  Racional: Command existe para dar lifecycle a uma intenção (validação,
  Task, eventos, checkpoint); leituras não têm lifecycle e envolvê-las em
  Command adiciona cerimônia sem garantia. Preserva-se a intenção original —
  o Runtime nunca executa endpoints e transportes não contêm lógica de
  negócio (a leitura é `store.find` + serialização, nada mais). Policies de
  leitura (authz por tenant), quando chegarem (Fase 2), entram como
  middleware da Service Platform, não como Commands. Origem: techspec Fase 1
  (`docs/techspec/00-overview.md` D3).
