# DEPLOY — Harness

Como rodar o motor em container (Railway agora, k8s depois) e como medir
performance/carga. Ver o racional de topologia de dados em [FOLLOWUP.md](FOLLOWUP.md) §1.

## Imagem (Docker)

`Dockerfile` (multi-stage, Ruby 3.3.5, YJIT ligado) serve `config.ru` sob Falcon.
O Studio já vem com o `dist/` versionado — **build sem Node**. O backend é SQLite
(WAL) durável em `HARNESS_DB`; monte um volume e aponte pra dentro dele.

```bash
docker build -t harness .
docker run -p 9292:9292 -v harness-data:/data \
  -e DEEPSEEK_API_KEY=sk-... \
  -e OPENCLAW_GATEWAY_TOKEN=troque-isto \
  harness
curl localhost:9292/up      # {"status":"ok"}
```

## Variáveis de ambiente

| Env | Default | Efeito |
|-----|---------|--------|
| `HARNESS_DB` | `/data/harness.db` (na imagem) | caminho SQLite durável (monte volume!) |
| `PORT` | `9292` | porta do bind http |
| `WEB_CONCURRENCY` | `2` | nº de processos (workers) do Falcon |
| `OPENCLAW_GATEWAY_TOKEN` | cai no `ADMIN_TOKEN` | Bearer de `/v1/responses` e `/v1/agents` (gateway) |
| `ADMIN_TOKEN` | `local-demo` | token do `/studio` e `/admin` (**troque em prod**) |
| `DEEPSEEK_API_KEY` | — | chave do provider. **Sem ela o motor SOBE** (`/up` verde), mas turnos falham até configurar (env ou Studio > LLM providers) — resiliência de nuvem |
| `DEEPSEEK_MODEL` | `deepseek-chat` | modelo |
| `ACHEI_INTERNAL_URL` | — | base p/ as data-tools chamarem `/api/internal/*` (ver abaixo) |
| `HARNESS_EGRESS_HOSTS` | — | allowlist de host de saída (SSRF guard) |
| `HARNESS_EGRESS_ALLOW_HTTP` / `_ALLOW_PRIVATE` | off | só p/ callback http/loopback (NÃO em cloud) |

### Tokens & rotação (separe os dois!)

São **dois** segredos com propósitos distintos — em produção use valores
**DIFERENTES** (o `OPENCLAW_GATEWAY_TOKEN` cair no `ADMIN_TOKEN` é só conveniência
de dev):

- **`ADMIN_TOKEN`** — login do `/studio` + Bearer do `/admin`. Superfície de
  OPERADOR (só você). Rotacionar é **seguro e independente**: muda no Railway,
  redeploy, e você faz login com o novo. NÃO afeta o achei-b2b.
- **`OPENCLAW_GATEWAY_TOKEN`** — Bearer do `/v1/responses` e `/v1/agents`. É o
  contrato com o **achei-b2b**. Rotacionar exige **trocar os dois lados juntos**
  (senão o WhatsApp quebra): atualize a var no Railway **e** o
  `OPENCLAW_GATEWAY_TOKEN` do achei-b2b no mesmo passo.

Gerar um token forte: `ruby -rsecurerandom -e 'puts SecureRandom.hex(24)'`.

### Callback pro achei-b2b (tools) — via ngrok

As data-tools chamam de volta `/api/internal/agent_tools/*` do achei-b2b. Com o
motor **no Railway** e o achei-b2b **na sua máquina** (`:3000`), exponha o Rails por
um túnel público https e aponte o motor pra ele:

```bash
# no manifesto/pack: base_url = {{env.ACHEI_INTERNAL_URL}}
ACHEI_INTERNAL_URL=https://bianca-thunderous-hypostatically.ngrok-free.dev
HARNESS_EGRESS_HOSTS=bianca-thunderous-hypostatically.ngrok-free.dev
```

Como o túnel é **https público**, o egress guard **estrito (default) já libera** —
NÃO precisa de `ALLOW_HTTP`/`ALLOW_PRIVATE` (esses são só p/ o loop 100% local).
Restringir `HARNESS_EGRESS_HOSTS` ao host do túnel é a postura segura (NF4).

## Railway

`railway.json` já configura builder Dockerfile, `startCommand`, healthcheck `/up` e
restart policy.

1. Crie o projeto/serviço a partir deste repo (builder = Dockerfile).
2. **Volume**: monte em `/data` (o `HARNESS_DB` default aponta pra lá) — sem volume,
   o SQLite é efêmero e o Recovery não retoma nada após redeploy.
3. **Vars**: `DEEPSEEK_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`, `ACHEI_INTERNAL_URL`,
   `HARNESS_EGRESS_HOSTS` (e `WEB_CONCURRENCY` conforme o plano/CPU).
4. Health check bate em `/up`.
5. Aponte o achei-b2b: `OPENCLAW_GATEWAY_URL=<url pública do Railway>` +
   `OPENCLAW_GATEWAY_TOKEN` batendo com o do motor (ver `RUNNING-LOCAL.md`).

## k8s (evolução)

SQLite não compartilha 1 arquivo entre nós. Caminhos (ver FOLLOWUP §1.3):
StatefulSet + PVC por pod + roteamento **sticky-by-agent** (shard por tenant), ou
**LiteFS**, ou o adapter **Postgres** (opcional). **Litestream** p/ backup/DR desde
cedo (ortogonal à topologia).

---

## Medir performance/carga

### 1. Teto de escrita do SQLite (sem provider) — `bench_store.rb`
Isola "SQLite aguenta multi-proc?" do ruído do LLM: N processos martelando escrita
no MESMO arquivo (WAL + busy_timeout — a config real).

```bash
bundle exec ruby scripts/bench_store.rb 1,2,4,8 3000
```

**Resultado medido (jul/2026, laptop, payload ~481B):**

| procs | writes/s (agregado) | p50 | p95 | max | locked |
|------:|--------------------:|----:|----:|----:|-------:|
| 1 | ~29.6k | 0.02ms | 0.04ms | 2.4ms | **0** |
| 2 | ~29.9k | 0.02ms | 0.04ms | 59ms | **0** |
| 4 | ~23.7k | 0.02ms | 0.05ms | 336ms | **0** |
| 8 | ~28.4k | 0.03ms | 0.05ms | 539ms | **0** |

**Leitura:** o throughput agregado fica ~25–30k writes/s independente do nº de
procs (teto de 1-escritor-por-vez do WAL), **zero "database is locked"** (o
`busy_timeout` absorve a contenção → vira latência de cauda, não erro), p95
microscópico. Um turno real é **provider-bound (segundos)** e faz um punhado de
escritas → o workload fica ~100x abaixo do teto. **Empiricamente, SQLite não é o
gargalo num único box.**

### 2. Carga end-to-end (com provider) — `loadtest.rb`
Bate em `POST /v1/responses` (SSE), o caminho de produção. Mede TTFB, total,
tokens, cache hit, P50/P95, taxa de erro. Roda contra local OU Railway.

```bash
HARNESS_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=xxx \
  bundle exec ruby scripts/loadtest.rb --agents bia --concurrency 16 --iterations 3
```

> Comparação **apples-to-apples** com o gateway OpenClaw: como o contrato SSE de
> `/v1/responses` é o mesmo, o `loadtest-gateway.mjs` do OpenClaw também roda
> apontando pro harness (`OPENCLAW_GATEWAY_URL=<url do harness>`).

### 3. Baseline vs multi-worker no mesmo box — `loadtest-local.sh`
Sobe Falcon com 1 worker e depois N, sobre o MESMO SQLite, e conta
"database is locked" nos logs.

```bash
DEEPSEEK_API_KEY=sk-... ./scripts/loadtest-local.sh 4 24
```
