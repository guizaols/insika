# Rodar o Harness local

Sobe o motor single-process (a Bia/DeepSeek) servindo `/studio`, `/admin/*` e
`/v1/*`. Cada mensagem dispara o MESMO `send_message` da API — tools/skills/
memória reais.

## Subir

```bash
cd harness
DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

> Use **`bundle exec`** (a isolação do bundler importa — OTEL está no Gemfile).
> É single-process: `Ctrl-C` / `kill -9` libera a porta na hora.

Abra em `http://localhost:9292`:

| URL | O quê |
|-----|-------|
| `/studio` | UI de gestão (login com o token; default `local-demo`) |
| `/admin/chat` | conversar com a Bia (agente `bia`, `session_id: web` já pronto p/ multi-turn) |
| `/admin/events` | tool-cards ao vivo (filtre por `session_id: web`) |
| `/v1/responses` | ingresso OpenAI Responses (Bearer) — o contrato do gateway |
| `/v1/agents` | provisionamento por pack (Bearer) — `POST` importa, `DELETE /:id` remove |
| `/v1/messages` | send_message (SSE) |

## Variáveis (todas opcionais)

| Env | Default | Efeito |
|-----|---------|--------|
| `HARNESS_DB` | — (memória efêmera) | caminho SQLite → config + execução sobrevivem a restart |
| `BIND` | `http://localhost:9292` | host:porta |
| `ADMIN_TOKEN` | `local-demo` | token do `/studio` e `/admin` |
| `OPENCLAW_GATEWAY_TOKEN` | cai no `ADMIN_TOKEN` | Bearer de `/v1/responses` e `/v1/agents` |
| `DEEPSEEK_MODEL` | `deepseek-chat` | modelo |

Com persistência:

```bash
DEEPSEEK_API_KEY=sk-... HARNESS_DB=./harness.db bundle exec ruby scripts/serve_real.rb
```

## Observabilidade OTEL (opt-in) — coletor avulso

O OTEL é **desligado por default** (a gem nem carrega). Pra ver traces local, suba
um coletor OTLP avulso — o mais rápido é o **Jaeger all-in-one** (expõe OTLP em
`4318` e a UI em `16686`):

```bash
docker run --rm -d --name jaeger \
  -p 16686:16686 -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

Depois suba o motor com o OTEL ligado apontando pro coletor:

```bash
HARNESS_OTEL=1 OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

O `serve_real` imprime `OTEL → ligado/desligado` na subida. Converse no
`/admin/chat` e veja os traces em **`http://localhost:16686`** (serviço `harness`):
um span `harness.turn` por turno, com filhos `harness.tool`/`harness.data_tool` e
atributos de tokens/agente/modelo/latência. Parar o coletor: `docker rm -f jaeger`.

> Detalhes do que sai e como ligar: [`techspec/phase6-engine/telemetry-otel.md`](techspec/phase6-engine/telemetry-otel.md).
> Não versionamos `docker-compose` — o coletor é avulso, decisão de rodar local.
