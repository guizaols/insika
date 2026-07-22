# DEPLOY — Harness

Como rodar o motor em container (Railway agora, k8s depois) e como medir
performance/carga.

## Imagem (Docker)

`Dockerfile` (multi-stage, Ruby 4.0.6, YJIT ligado) serve `config.ru` sob Falcon.
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
| `ADMIN_TOKEN` | `local-demo` | token de login do `/studio` (**troque em prod**) |
| `DEEPSEEK_API_KEY` | — | chave do provider. **Sem ela o motor SOBE** (`/up` verde), mas turnos falham até configurar (env ou Studio > LLM providers) — resiliência de nuvem |
| `DEEPSEEK_MODEL` | `deepseek-chat` | modelo |
| `CONSUMER_INTERNAL_URL` | — | base p/ as data-tools chamarem `/api/internal/*` (ver abaixo) |
| `HARNESS_EGRESS_HOSTS` | — | allowlist de host de saída (SSRF guard) |
| `HARNESS_EGRESS_ALLOW_HTTP` / `_ALLOW_PRIVATE` | off | só p/ callback http/loopback (NÃO em cloud) |
| `LITESTREAM_REPLICA_URL` | — | **liga o Litestream** (backup/DR). Vazio = desligado (default). Ver seção abaixo |
| `LITESTREAM_ENDPOINT` | — | endpoint S3-compatível (R2/MinIO). Vazio = AWS S3 |
| `LITESTREAM_REGION` | — | região do bucket (AWS: `us-east-1`; R2: `auto`) |
| `LITESTREAM_ACCESS_KEY_ID` / `LITESTREAM_SECRET_ACCESS_KEY` | — | credenciais do bucket (lidas nativamente pelo Litestream) |

### Tokens & rotação (separe os dois!)

São **dois** segredos com propósitos distintos — em produção use valores
**DIFERENTES** (o `OPENCLAW_GATEWAY_TOKEN` cair no `ADMIN_TOKEN` é só conveniência
de dev):

- **`ADMIN_TOKEN`** — login do `/studio` (cookie-auth). Superfície de
  OPERADOR (só você). Rotacionar é **seguro e independente**: muda no Railway,
  redeploy, e você faz login com o novo. NÃO afeta o consumer-app.
- **`OPENCLAW_GATEWAY_TOKEN`** — Bearer do `/v1/responses` e `/v1/agents`. É o
  contrato com o **consumer-app**. Rotacionar exige **trocar os dois lados juntos**
  (senão o WhatsApp quebra): atualize a var no Railway **e** o
  `OPENCLAW_GATEWAY_TOKEN` do consumer-app no mesmo passo.

Gerar um token forte: `ruby -rsecurerandom -e 'puts SecureRandom.hex(24)'`.

### Config estrito + `harness doctor` (item 23)

Disciplina de config estilo OpenClaw — **recusa chave desconhecida, sem
compat silenciosa de schema**. Duas partes:

**1. Gate de boot (`HARNESS_EGRESS_ALLOW_HTTP` etc.).** No boot, o motor valida o
ambiente contra o schema de chaves conhecidas (`Harness::EnvSchema`): tipo errado
(`HARNESS_PORT=abc`) e **chave desconhecida no namespace `HARNESS_`** (um typo como
`HARNESS_EGRES_ALLOW_HTTP` que o runtime ignoraria calado). Por **default só
AVISA** e sobe assim mesmo (*last-known-good* — uma chave rotacionada ou um typo
nunca derruba o serviço inteiro; mesma lógica do boot resiliente do DeepSeek).
Para **recusar o boot** num finding, ligue `HARNESS_CONFIG_STRICT=1`.
Detecção de chave desconhecida é escopada só ao prefixo `HARNESS_` (nosso); o
`OPENCLAW_` (compartilhado com o gateway OpenClaw), `LITESTREAM_` e `OTEL_` nunca
são marcados.

**2. `bin/harness doctor` — diagnóstico sob demanda.** Lê o **mesmo** backend
durável do servidor (`HARNESS_DB`) sem subir a app inteira (sem DeepSeek, sem
seed) — seguro rodar contra um volume em produção:

```bash
harness doctor            # relatório colorido; sai !=0 se houver erro
harness doctor --json     # relatório machine-readable (CI/monitoramento)
harness doctor --fix      # aplica os autofixes seguros e re-diagnostica
harness env               # lista as chaves conhecidas + valores atuais (segredos mascarados)
```

Checks: env (schema acima), versão de schema do settings (migração pendente →
`--fix` aplica), `default_model` de plataforma ausente (`--fix` semeia do
`DEEPSEEK_MODEL`), backend durável vs efêmero, provider LLM configurado,
`ADMIN_TOKEN` setado. Migrações de schema do settings são **explícitas** (nenhum
save do Studio reinterpreta dado de shape antigo em silêncio) — a v1 é o baseline;
um registro pré-versionamento é carimbado por `harness doctor --fix`.

### Callback pro consumer-app (tools) — via ngrok

As data-tools chamam de volta `/api/internal/agent_tools/*` do consumer-app. Com o
motor **no Railway** e o consumer-app **na sua máquina** (`:3000`), exponha o Rails por
um túnel público https e aponte o motor pra ele:

```bash
# no manifesto/pack: base_url = {{env.CONSUMER_INTERNAL_URL}}
CONSUMER_INTERNAL_URL=https://bianca-thunderous-hypostatically.ngrok-free.dev
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
3. **Vars**: `DEEPSEEK_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`, `CONSUMER_INTERNAL_URL`,
   `HARNESS_EGRESS_HOSTS` (e `WEB_CONCURRENCY` conforme o plano/CPU).
4. Health check bate em `/up`.
5. Aponte o consumer-app: `OPENCLAW_GATEWAY_URL=<url pública do Railway>` +
   `OPENCLAW_GATEWAY_TOKEN` batendo com o do motor (ver `RUNNING-LOCAL.md`).

## Backup/DR — Litestream (opt-in, configurável)

O volume único é o **único ponto de perda total** entre piloto e produção
(corrupção/sumiço do disco = adeus conversas + config). O Litestream faz
**replicação contínua** do `harness.db` (WAL) para um bucket S3/R2, sem trocar de
banco e **sem uma linha de Ruby**.

É **desligado por padrão** e liga por ENV — quem roda single-box efêmero não paga
custo; quem quer durabilidade externa habilita apontando um bucket. O gatilho é
uma única variável, `LITESTREAM_REPLICA_URL`:

- **vazia (default):** o `deploy/entrypoint.sh` dá `exec` direto no Falcon. O
  binário do Litestream nem é invocado — comportamento idêntico ao anterior.
- **setada:** numa box nova o entrypoint **restaura** o `harness.db` do replica
  *antes* do app abrir o banco (`litestream restore -if-replica-exists`; no-op se
  o bucket ainda estiver vazio) e depois **supervisiona** o app
  (`litestream replicate -exec`), replicando o WAL continuamente e fazendo um
  sync final no shutdown (SIGTERM do Railway).

### Ligar em produção (Railway)

Adicione as vars (mantendo o volume em `/data`):

```bash
# AWS S3
LITESTREAM_REPLICA_URL=s3://meu-bucket/harness
LITESTREAM_REGION=us-east-1
LITESTREAM_ACCESS_KEY_ID=AKIA...
LITESTREAM_SECRET_ACCESS_KEY=...

# Cloudflare R2 (S3-compatível): mesmo, + endpoint e region=auto
LITESTREAM_REPLICA_URL=s3://meu-bucket/harness
LITESTREAM_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
LITESTREAM_REGION=auto
LITESTREAM_ACCESS_KEY_ID=...
LITESTREAM_SECRET_ACCESS_KEY=...
```

As credenciais são lidas nativamente pelo Litestream (não ficam no
`deploy/litestream.yml`, que só referencia URL/endpoint/region via `${VAR}`).

### Restore drill (o "done" de verdade — sem drill, backup não conta)

O gap piloto→produção só fecha quando um restore foi **exercitado**. Duas formas:

**1. Local, automatizado (prova o mecanismo, zero credencial):** usa a imagem
real + um replica `file://`, sobe → replica → apaga o volume → sobe outra box →
restaura → confere que a linha-marcador sobreviveu e o `/up` está verde.

```bash
scripts/litestream-restore-drill.sh      # requer docker, sqlite3, curl
# → [drill] PASS — marker … restored from replica; /up green on the new box.
```

**2. Produção (o drill que conta pro go-live):** contra o bucket real.

```bash
# a. com o serviço no ar e replicando, gere alguma config/conversa e confirme
#    que o replica tem gerações:
litestream snapshots -config deploy/litestream.yml "$HARNESS_DB"

# b. suba uma box NOVA (volume vazio) com as mesmas LITESTREAM_* → o entrypoint
#    restaura sozinho no boot. Valide manualmente no /studio que conversas e
#    config vieram de volta. Alternativa manual do restore:
litestream restore -config deploy/litestream.yml -o /tmp/restored.db "$HARNESS_DB"
```

Registre a data do drill no runbook de corte (§12 G8 do FOLLOWUP).

## k8s (evolução)

SQLite não compartilha 1 arquivo entre nós. Caminhos:
StatefulSet + PVC por pod + roteamento **sticky-by-agent** (shard por tenant), ou
**LiteFS**, ou o adapter **Postgres** (opcional). **Litestream** (acima) p/ backup/DR
desde cedo — ortogonal à topologia.

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
