---
rfc: "0006"
title: Persistence & Stores
status: Draft
type: Componente
created: 2026-07-05
supersedes: []
depends_on: ["0001", "0002"]
---

# RFC-0006 — Persistence & Stores

> Detalha o estágio de Persistence da pipeline (RFC-0002) e as interfaces de
> store. Princípio constitucional: sem job runner externo — durabilidade vem de
> **stores plugáveis**, Registry-driven. O núcleo não sabe onde grava.

## 1. Interface comum de Store

Todos os stores implementam o mesmo contrato mínimo, escopado por namespace.

```ruby
module Harness
  module Store
    # scope: separa tenants/domínios (ex.: "sessions:tenant_x")
    def get(scope, key)            # -> value | nil
    def set(scope, key, value)     # -> value
    def delete(scope, key)         # -> bool
    def list(scope, prefix = nil)  # -> [keys]
    def transaction(&blk)          # atômico quando o backend suporta
  end
end
```

`value` é serializável (JSON/MessagePack). Chaves são strings hierárquicas
(`task:123`, `checkpoint:123:turn:4`). Stores são registrados no Registry
(RFC-0001), então o backend é trocável sem tocar na lógica.

## 2. Os cinco stores

| Store            | Guarda                                                    |
|------------------|----------------------------------------------------------|
| **Session Store**| sessão: transcript/mensagens, variáveis, refs de memória |
| **Task Store**   | task: status, histórico de Executions, estado da mailbox |
| **Checkpoint Store**| snapshot por turno para retomar (pause/resume/restart) |
| **Artifact Store**| blobs/arquivos (tickets, anexos, saídas) — filesystem   |
| **Plugin Store** | KV por plugin (namespace isolado por plugin id)          |

### 2.1 Session
`session:<id>` → `{ messages:[], vars:{}, memory_refs:[], created_at, updated_at }`.
Reconstrução do transcript é a fonte da verdade; eventos ao vivo são estado de
entrega (mesmo modelo do OpenClaw Control UI).

### 2.2 Task / Execution
`task:<id>` → `{ status, command, executions:[], mailbox_state }`.
Status: `queued|running|waiting|paused|completed|failed|cancelled`. Cada
**Execution** é uma tentativa, preservando histórico (retry não sobrescreve).

### 2.3 Checkpoint
`checkpoint:<task_id>:turn:<n>` → estado serializado suficiente para retomar do
início do turno n: cursor da conversa, tools pendentes, contexto resolvido.
Ver §5 (granularidade).

### 2.4 Artifact
Orientado a filesystem: `artifact:<session_id>:<name>` → path/blob. Metadados no
Session Store; bytes no Artifact Store.

### 2.5 Plugin
`plugin:<plugin_id>:<key>` → value. Isolado por plugin; um plugin não lê o
namespace de outro.

## 3. Backends

| Backend       | Uso                                             |
|---------------|-------------------------------------------------|
| **Memory**    | dev/teste (efêmero)                             |
| **SQLite**    | produção standalone — **default**               |
| **Filesystem**| Artifact Store (blobs), auditável/git-friendly  |
| **Postgres**  | plugin `harness-postgres` — multi-instância     |
| **ActiveRecord**| opcional, só se embutido no Rails — não default |

## 4. Durabilidade & recuperação

Ao iniciar, o runtime:
1. lê o Task Store e encontra tasks em `running`/`waiting`/`paused`;
2. carrega o último Checkpoint de cada uma;
3. retoma a partir do checkpoint (ou marca `failed` se irrecuperável).

Sem fila externa: a durabilidade é a soma Task Store + Checkpoint Store. Heartbeats
e agendamento (RFC-0002 §Scheduler) persistem seu próximo disparo no store.

## 5. Granularidade do checkpoint (questão da RFC-0002, resolvida aqui)

**Decisão:** checkpoint **por turno** (não por tool). Um turno = uma iteração
completa do loop do agente (prompt → modelo → tools → resposta parcial). Racional:

- por-tool multiplicaria escritas e o volume do store sem ganho real — se uma tool
  falha no meio do turno, o turno inteiro é re-executado do último checkpoint, o
  que é seguro desde que tools sejam idempotentes ou reentrantes;
- por-turno alinha com o ponto natural de pause/resume (`INPUT_REQUIRED`) e com o
  cancelamento cooperativo (checado no limite do turno).

Tools com efeito colateral não-idempotente devem declarar isso e o Runtime
registra sua conclusão no checkpoint do turno para não re-executá-las na retomada.

## 6. Concorrência multi-processo

Escala horizontal = múltiplos processos com store compartilhado.

- **SQLite:** modo WAL; adequado a um nó com boa concorrência de leitura. Para
  multi-nó, migrar para Postgres.
- **Postgres:** multi-instância real.
- **Modelo de escrita:** **last-write-wins** por default (simples, suficiente para
  sessão/task de um dono). Onde há disputa real (uma task assumida por dois
  processos), usar **lease/lock otimista** no Task Store (claim com token + TTL).

## 7. Retenção & GC

Política configurável: TTL de sessões inativas, poda de Executions/checkpoints
antigos após conclusão, arquivamento de artefatos. GC roda como task Async
periódica (Scheduler).

## 8. Estado atual & pendências

- **Feito:** nada persistente ainda — o `agent_runtime` é stateless (histórico
  vem do consumidor). É o gap central da Fase 1.
- **Fase 1:** interface Store; Memory + SQLite; Session/Task/Checkpoint Stores;
  recuperação no boot.
- **Fase 2:** Artifact/Plugin Stores; Postgres; retenção/GC; lease/lock.

## 9. Questões em Aberto

1. Serialização do checkpoint: formato e tamanho para sessões longas.
2. Migração de backend (SQLite → Postgres) sem downtime.
3. Lease/lock: quando a disputa multi-processo é real o suficiente para justificar.
4. Criptografia em repouso de sessões/memória sensível.
