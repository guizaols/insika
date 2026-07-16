# Fase 6 · Observabilidade — OpenTelemetry (opt-in)

> Entrega a metade de **observabilidade** da task 10 (tokens/custo/latência), via
> OTEL, sem tocar o núcleo. O piloto shadow (a outra metade) é separado. Deploy no
> Railway foi descartado (Etapa D) — o OTEL exporta para qualquer coletor OTLP.

## 1. Ideia (por que é "inteligente")

O harness já tem uma **espinha de observabilidade**: o *Event Stream*. Todo turno
emite eventos estruturados (`task_started`, `tool_call`/`tool_result`,
`data_tool_call`, `task_completed`/`task_failed`/`task_cancelled`), cada um com
`meta.at`/`task_id`/`session_id`/`seq`. A Telemetry **consome** esse stream e
emite spans OTEL — o núcleo (Executor/tools) **não ganha nenhuma chamada OTEL**
(Events observam; Telemetry traduz). É o mesmo princípio "Events observam" já
adotado pelo SSE.

## 2. O que sai

Um **span por turno** (`harness.turn`) com **spans-filho** por tool
(`harness.tool`) e por data-tool (`harness.data_tool`), correlacionados por
`task_id`. Latência = duração do span (dos timestamps reais de `meta.at`).
Tokens/custo, agente e modelo = **atributos** — o backend (SigNoz/Tempo/Jaeger)
agrega em métricas. Não dependemos do SDK de métricas do OTEL (menos maduro em Ruby).

| Atributo | Onde |
|----------|------|
| `harness.task_id`, `harness.session_id`, `harness.agent`, `harness.command` | span de turno |
| `harness.tokens.input/output/total/cached`, `harness.model` | span de turno (do usage) |
| `harness.status` (`ok`/`error`/`cancelled`) + status OTEL de erro | span de turno |
| `harness.tool` | span de tool |
| `harness.tool`, `harness.http.status` | span de data-tool |

**Pré-requisito que veio junto:** o Executor passou a **capturar o usage de
tokens** da resposta do provider (`input/output/total/cached` + `model`) e a
emiti-lo no evento terminal. Isso também **preenche o `usage` do `/v1/responses`**
(`response.completed`), que antes ia vazio — ganho de fidelidade com o
`OpenclawDispatcher`, além de alimentar o OTEL.

## 3. Ligar/desligar (opt-in, paridade quando off)

Ligado por env — nenhuma flag nova de código:
- `HARNESS_OTEL=1`, **ou** as envs padrão do OTEL (`OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_TRACES_EXPORTER`).

Destino/protocolo/headers seguem a **config padrão do SDK OTEL** (env) — aponte
`OTEL_EXPORTER_OTLP_ENDPOINT` para o coletor. `OTEL_SERVICE_NAME` nomeia o serviço
(default `harness`).

**Desligado (default):** `Telemetry.setup` devolve `nil`, a gem OTEL **nem é
carregada** (require lazy, como o ruby_llm) e nada é instrumentado — zero
overhead. Travado por `load_guard_spec` ("require harness não carrega
OpenTelemetry").

**Local (coletor avulso):** para ver traces na máquina, suba um coletor OTLP
avulso — o mais rápido é o Jaeger all-in-one (OTLP em `4318`, UI em `16686`):

```bash
docker run --rm -d --name jaeger -p 16686:16686 -p 4318:4318 jaegertracing/all-in-one:latest
HARNESS_OTEL=1 OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
  DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

Traces em `http://localhost:16686` (serviço `harness`). Não versionamos
`docker-compose` — o coletor é avulso (ver [`docs/RUNNING-LOCAL.md`](../../RUNNING-LOCAL.md)).

## 4. Desenho (testabilidade)

- **`Telemetry::Recorder`** — PURO: traduz Event → spans falando com um `tracer`
  duck-typed (`start_span`/`set_attribute`/`record_error`/`finish`). Não
  referencia `OpenTelemetry::` — testado com um tracer FAKE. `record` **nunca
  levanta** (telemetria não derruba turno); órfãos são ignorados; correlação de
  tool é FIFO; turnos abandonados são limpos (cap `MAX_OPEN`).
- **`Telemetry.setup`** — BOUNDARY da gem (como o `create_chat` do Executor):
  require lazy + configura o SDK + devolve um `Recorder` ligado ao `OTelTracer`.
  Coberto por um smoke com o **SDK real** + exporter em memória (nome/atributos/
  hierarquia/`Status.error`).
- **`Telemetry.attach`** — assina o Event Stream e alimenta o Recorder num fiber
  de vida-longa (irmão do serving). No-op se `recorder` nil.

## 5. Wiring

`config/deployment.rb`: `TELEMETRY = Telemetry.setup(...)` (nil se desligado).
`scripts/serve_real.rb`: `Telemetry.attach(event_stream:, recorder: TELEMETRY)`
dentro do reactor de serving. Para servir via `config.ru`/Falcon, uma linha
equivalente de `attach` no boot do worker liga o mesmo consumo.

## 6. Riscos
- **Consumidor lento:** cada subscription do Event Stream tem cap de 1000
  eventos; se a telemetria ficasse muito atrás, a subscription fecharia (para a
  telemetria, não o turno). As ops de span são baratas — folga ampla no piloto.
- **Turno sem evento terminal** (kill -9): o span ficaria aberto; o cap
  `MAX_OPEN` do Recorder fecha os mais antigos (memória limitada).
