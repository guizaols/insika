# syntax=docker/dockerfile:1
# Imagem de produção do harness (motor de agentes). Serve /v1/*, /studio
# e /up sob Falcon (async/streaming). O Studio já vem com o dist/ versionado —
# NÃO precisa de Node no build.
#
# Backend: SQLite (WAL) durável em HARNESS_DB. Em produção monte um volume e
# aponte HARNESS_DB pra dentro dele (ex.: /data/harness.db) — senão o Recovery
# não tem o que retomar após restart.

# ---- builder: compiles the native gems (sqlite3) --------------------------
# Ruby 4.0.x is the recommended/tested runtime (see .ruby-version and
# docs/BENCHMARKS.md — Ruby × YJIT matrix, FOLLOWUP §1.1). Keep this tag in sync
# with .ruby-version and with RUBY VERSION in Gemfile.lock.
FROM ruby:4.0.6-slim AS builder

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4

# libssl-dev + pkg-config: the `openssl` gem (4.0.2, compiled after the 4.0.6
# Gemfile.lock re-resolve) needs the OpenSSL headers + pkg-config to build its C
# extension — without them `bundle install` fails on ruby:4.0.6-slim (linux).
# wget + ca-certificates: to fetch the Litestream release tarball below.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libssl-dev pkg-config wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Litestream binary (opt-in continuous SQLite replication → S3/R2 for backup/DR;
# see deploy/entrypoint.sh + docs/DEPLOY.md). Fetched here in the builder and
# copied into the slim runtime so no download tooling lingers in the final image.
# TARGETARCH is provided by BuildKit (amd64 / arm64) and matches the asset names.
ARG TARGETARCH
ARG LITESTREAM_VERSION=0.3.13
RUN wget -q "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-${TARGETARCH}.tar.gz" -O /tmp/litestream.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/litestream.tar.gz litestream && \
    rm /tmp/litestream.tar.gz && \
    /usr/local/bin/litestream version

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/cache/*.gem && \
    (find "${BUNDLE_PATH}"/gems \( -name "*.c" -o -name "*.o" \) -delete || true)

# ---- runtime: slim, only what is needed to run ----------------------------
FROM ruby:4.0.6-slim AS runtime

# RUBY_YJIT_ENABLE=1 turns YJIT on at Ruby process startup (falcon inherits it) —
# equivalent to `ruby --yjit`; confirm with RubyVM::YJIT.enabled?. Measured in
# docs/BENCHMARKS.md: the CPU work per turn (serialization/SSE/context).
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RUBY_YJIT_ENABLE=1 \
    PORT=9292 \
    HARNESS_DB=/data/harness.db

# Roda como root: o volume durável (Railway Volume / k8s PVC) é montado em /data
# em RUNTIME, sobrepondo o dir da imagem — com usuário não-root o mount vem
# root-owned e o SQLite não conseguiria escrever o harness.db. Pro piloto
# (container single-tenant) root é aceitável; hardening não-root (fsGroup/
# init-chown) fica p/ o k8s. Ver docs/DEPLOY.md.
RUN mkdir -p /data
WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /usr/local/bin/litestream /usr/local/bin/litestream
COPY . .

# O volume /data é montado pelo orquestrador, NÃO pela instrução VOLUME do Docker
# (o Railway a rejeita). HARNESS_DB aponta pra /data (ver ENV acima).
EXPOSE 9292

# O entrypoint decide o boot: com LITESTREAM_REPLICA_URL setado, restaura o
# harness.db do replica (box nova) e supervisiona o app sob Litestream (backup/DR
# opt-in — ver deploy/entrypoint.sh + docs/DEPLOY.md); sem a var, dá `exec` direto
# no Falcon (custo zero, comportamento idêntico ao anterior). Falcon lê o config.ru
# (Boot -> Wiring -> recovery ANTES de aceitar conexão); bind em http (o proxy do
# Railway/Ingress faz o TLS). WEB_CONCURRENCY controla o nº de processos forkados
# (default 2; num box maior, aumente — ver docs/DEPLOY.md sobre SQLite WAL).
CMD ["sh", "deploy/entrypoint.sh"]
