---
rfc: "0002"
title: Runtime Pipeline
status: Draft
type: Componente
created: 2026-07-05
supersedes: ["RFC-001.1"]
depends_on: ["0001"]
---

# RFC-0002 — Runtime Pipeline

> Detalha o **caminho canônico de execução** declarado no princípio 2 da
> RFC-0001. Absorve e substitui o antigo RFC-001.1, corrigindo dois pontos.

## 1. Motivação

Todo transporte (HTTP, SSE, WebSocket, CLI, SDK e protocolos futuros como A2A)
converge para a **mesma** pipeline. Ao fixá-la, os demais componentes (Plugins,
Registries, Skills, Context Providers, Middleware, Stores) tornam-se
infraestrutura de suporte, não modelos de execução concorrentes.

## 2. Princípios (herdados da RFC-0001)

- Há exatamente uma pipeline de execução.
- Todo transporte traduz requisições em Commands.
- O Runtime nunca monta prompt (isso é da Context Platform).
- Middleware modifica execução; Hooks alteram comportamento; Events observam.
- Persistência acontece fora da lógica de negócio.
- RubyLLM permanece responsável pela execução do modelo.

## 3. Fluxo canônico

```
                         Command
                            │
        ┌── before_prompt ──┤
        │   Context Builder │ (Session·Memory·Workspace·Skill·Prompt·
        └── after_prompt  ──┤  Plugin·Artifact·Request Providers)   [RFC-0005]
                            │
                            ▼
                       Policy Engine        (tool/skill allow-deny, custo,
                            │                aprovação, restrição de tenant)
                            ▼
                     Middleware Pipeline     (auth, authz, rate limit,
                            │                tracing, cost, prompt rewrite)
                            │
        ┌ before_task/before_agent ─┐
        │      Runtime Executor      │  (lifecycle, scheduling, cancel,
        │            │               │   pause/resume, checkpoint coord.)
        │            ▼               │
        │        RubyLLM  ◀──────┐   │   ← loop do agente
        │            │           │   │
        │            ▼           │   │
        │   before_tool ┐        │   │
        │   Tool Execution (Async concorrente / sequencial)
        │   after_tool  ┘        │   │
        │            └───────────┘   │
        └ after_agent/after_task ────┘
                            │
                            ▼
                       Persistence            (checkpoint · session · task)  [RFC-0006]
                            │
                            ▼
                        Response  ◀════════════════════════╗
                                                           ║
   Event Stream  ══ contínuo durante TODO o turno ════════╝
   (TaskStarted · ToolStarted/Completed · content deltas · CheckpointCreated …)
                → projetado ao vivo em SSE / WebSocket
```

## 4. Estágios

1. **Command** — toda interação começa como Command
   (`CreateSession`, `CreateTask`, `SendMessage`, `ResumeTask`, `CancelTask`,
   `ApproveAction`, `TriggerWorkflow`). Independente de transporte.
2. **Context Builder** — agrega os Context Providers habilitados (RFC-0005). O
   Runtime nunca monta prompt.
3. **Policy Engine** — decide o que é permitido antes da execução: tool/skill
   allow-deny, limites de custo, aprovação humana, restrição de tenant.
4. **Middleware Pipeline** — pode modificar a execução: auth, authz, rate limit,
   tracing, cost tracking, prompt rewriting.
5. **Runtime Executor** — só coordena: lifecycle, scheduling, cancelamento,
   pause/resume, coordenação de checkpoint.
6. **RubyLLM** — todas as interações com o modelo. Nunca duplicado.
7. **Tool Execution** — operações atômicas, sequenciais ou concorrentes via
   Async/Fibers.
8. **Persistence** — checkpoint/session/task, como estágio próprio (RFC-0006).
9. **Response** — projeção do resultado para HTTP/SSE/WebSocket/CLI/SDK.

## 5. Ordem e racional

- **Context antes de Policy.** A política precisa saber quais skills/tools o
  contexto trouxe para poder filtrar. Montar contexto primeiro, decidir depois.
- **Policy separado e antes de Middleware.** Autorização ("pode?") vem antes de
  efeitos colaterais operacionais ("como processar/limitar": rate limit, tracing,
  cost).
- **Runtime coordena, não monta contexto nem executa modelo.**
- **Persistence fora da lógica de negócio**, como estágio próprio.

## 6. Correção 1 — Hooks são *wrappers*, não um estágio

O RFC-001.1 listava Hooks como um estágio único após o Tool Execution, mas
incluía `before_task`/`before_agent`/`before_prompt` — que são *antes*. Correção:
Hooks são **pares before/after que envolvem estágios**:

- `before_prompt` / `after_prompt` → envolvem o **Context Builder**.
- `before_task` / `after_task` → envolvem o turno inteiro no **Runtime Executor**.
- `before_agent` / `after_agent` → envolvem cada chamada de **agente**.
- `before_tool` / `after_tool` → envolvem cada **Tool Execution**.

Hooks podem **alterar** comportamento (diferente de Events). Isso mantém a regra
de "uma pipeline" sem a contradição do diagrama linear.

## 7. Correção 2 — Event Stream e Response são contínuos

O RFC-001.1 tratava Event Stream e Response como passos terminais. Em turnos
interativos, o agente emite `content` deltas e eventos **durante** a execução (o
que o Agent.Shop consome para mostrar "buscando…" e o texto streamando).
Correção: o **Event Stream é concorrente ao turno inteiro** e a **Response é uma
projeção contínua** (SSE/WS) para turnos interativos; terminal apenas para
chamadas não-streaming.

## 8. Regra arquitetural

A Runtime Pipeline é o **único caminho de execução válido**. Toda feature futura
(execução distribuída, DAGs, capability resolution, human-in-the-loop, federação
A2A, coordenação multi-runtime) **estende estágios existentes** em vez de criar um
fluxo paralelo.

## 9. Faseamento do Actor Model

O Runtime Executor trata cada Task como um Actor (Async/Fibers, mailbox). Alvo
completo introduzido em duas fases:

- **Fase 1:** Task = fiber Async, mailbox mínima (`cancel`, `user_message`),
  checkpoint por turno.
- **Fase 2:** mailbox completa (`approval`, `timeout`, `heartbeat`); Sessions como
  Actors. O vocabulário `INPUT_REQUIRED` (A2A) serve de referência para
  "aguardando entrada/aprovação".

## 10. Questões em Aberto

1. Conjunto mínimo de Commands e sua evolução.
2. Granularidade do checkpoint: **resolvida na RFC-0006 §5** (por turno, não por
   tool).
3. Contrato de erro/timeout por estágio (propagação e retomada).
