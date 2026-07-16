# syntax=docker/dockerfile:1
# Imagem de produção do harness (motor de agentes). Serve /v1/*, /admin/*, /studio
# e /up sob Falcon (async/streaming). O Studio já vem com o dist/ versionado —
# NÃO precisa de Node no build.
#
# Backend: SQLite (WAL) durável em HARNESS_DB. Em produção monte um volume e
# aponte HARNESS_DB pra dentro dele (ex.: /data/harness.db) — senão o Recovery
# não tem o que retomar após restart.

# ---- builder: compila as gems nativas (sqlite3) ---------------------------
FROM ruby:3.3.5-slim AS builder

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/cache/*.gem && \
    (find "${BUNDLE_PATH}"/gems \( -name "*.c" -o -name "*.o" \) -delete || true)

# ---- runtime: slim, só o necessário pra rodar -----------------------------
FROM ruby:3.3.5-slim AS runtime

# Falcon liga YJIT quando disponível; garante o runtime enxuto.
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
COPY . .

# O volume /data é montado pelo orquestrador, NÃO pela instrução VOLUME do Docker
# (o Railway a rejeita). HARNESS_DB aponta pra /data (ver ENV acima).
EXPOSE 9292

# Falcon serve lê o config.ru (Boot -> Wiring -> recovery ANTES de aceitar
# conexão). Bind em http (o proxy do Railway/Ingress faz o TLS). WEB_CONCURRENCY
# controla o nº de processos forkados (default 2 aqui; num box maior, aumente —
# ver docs/DEPLOY.md sobre SQLite WAL e o teto de escrita medido pelo bench).
CMD ["sh", "-c", "bundle exec falcon serve --bind http://0.0.0.0:${PORT} --count ${WEB_CONCURRENCY:-2}"]
