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

## Apontar o consumer-app para o harness local

O consumer-app (Rails, `:3000`) já fala o contrato do gateway. Para ele mandar os
turnos ao harness local (`:9292`) no lugar do gateway OpenClaw:

**1. Apontar o dispatcher para o harness.** O `OpenclawGatewayConfig` resolve a
URL assim: modo `emergency` usa `emergency_url`; senão `ENV["OPENCLAW_GATEWAY_URL"]`.
O token é sempre `ENV["OPENCLAW_GATEWAY_TOKEN"]`. Duas formas:
- **Admin (sem restart):** em `/admin/openclaw_gateway_configs`, ligue o modo
  **emergencial** com `emergency_url = http://localhost:9292`.
- **Env:** `OPENCLAW_GATEWAY_URL=http://localhost:9292` no consumer-app.

Faça o `OPENCLAW_GATEWAY_TOKEN` do consumer-app **bater** com o do harness
(`OPENCLAW_GATEWAY_TOKEN`, ou o `ADMIN_TOKEN` default `local-demo`).

**2. Deixar o harness CHAMAR DE VOLTA a API interna do consumer-app.** As data-tools
batem em `http://localhost:3000/api/internal/agent_tools/*` — `http` + loopback,
que o egress guard bloqueia por default (SSRF). Ligue o opt-in **parando no host
do consumer-app** ao subir o harness:

```bash
HARNESS_EGRESS_ALLOW_HTTP=1 HARNESS_EGRESS_ALLOW_PRIVATE=1 \
HARNESS_EGRESS_HOSTS=localhost,127.0.0.1 \
DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

> `HARNESS_EGRESS_HOSTS` restringe o egress liberado só ao host interno (defesa
> em profundidade) — sem ele, `ALLOW_PRIVATE` abre qualquer destino privado.

**3. Provisionar o agente da loja no harness.** O harness precisa do agente +
tools apontando de volta pro consumer-app. Um **pack** é a pasta:

```
<pack>/
  agent.config.json     # { id, model, provider, memory, metadata }
  *.md                  # IDENTITY/SOUL/AGENTS/TOOLS/... (viram prompt_files)
  skills/<nome>/SKILL.md
  tools/<tool>.json     # 1 data-tool por arquivo
```

Cada `tools/<tool>.json`:
- `request.url` = `http://localhost:3000/api/internal/agent_tools/<rota>`
  (⚠ o **nome** da tool = o que o modelo chama; a **rota** pode diferir — ex.
  `send_finalize_button`→`finalize_button`, `search_faq`→`search_faqs`,
  `call_support`→`support_requests`. Confira em `config/routes.rb` do consumer-app)
- `request.headers`: `X-Chat-Id: {{ctx.chat_id}}`, `X-Store-Id: {{ctx.store_id}}`,
  `X-Agent-Id: {{ctx.agent_id}}` (contexto de TURNO — Etapa B) +
  `Authorization: Bearer __BIA_INTERNAL_API_TOKEN__` como **`secret_header`**
- o `id` do agente deve bater com o `openclaw_agent_id` da Store no consumer-app
  (ele resolve a loja por `X-Agent-Id`; então `metadata.store_id` pode ficar vazio)

Provisione com o CLI (roda como cliente contra o server no ar — o token interno
entra por env, fora do disco):

```bash
HARNESS_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=local-demo \
BIA_INTERNAL_API_TOKEN=<token interno> \
bundle exec ruby scripts/import_pack.rb /caminho/do/pack
```

(ou `POST /v1/agents` na mão, ou criar tudo pelo `/studio`.)

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

> Não versionamos `docker-compose` — o coletor é avulso, decisão de rodar local.
