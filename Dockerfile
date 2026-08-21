# syntax=docker/dockerfile:1
# Production image for the engine (agent engine). Serves /v1/*, /studio
# and /up under Falcon (async/streaming). The Studio ships with dist/ checked in —
# NO Node needed at build time.
#
# Backend: durable SQLite (WAL) at INSIKA_DB. In production mount a volume and
# point INSIKA_DB inside it (e.g. /data/insika.db) — otherwise Recovery
# has nothing to resume after a restart.

# ---- builder: compiles the native gems (sqlite3) --------------------------
# Ruby 4.0.x is the recommended/tested runtime (see .ruby-version and the
# Ruby × YJIT benchmark matrix). Keep this tag in sync
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
# The Gemfile consumes the gemspec (gemspec directive), which requires
# lib/insika/version.rb AND lib/insika/packaging.rb (RFC-0036's domain-payload
# boundary) — copy all three before bundle install, or evaluating the gemspec
# fails with "cannot load such file". The gemspec's `files` glob-fallback
# covers the .git-less build context.
COPY Gemfile Gemfile.lock insika.gemspec ./
COPY lib/insika/version.rb lib/insika/version.rb
COPY lib/insika/packaging.rb lib/insika/packaging.rb
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
    INSIKA_DB=/data/insika.db

# Runs as root: the durable volume (Railway Volume / k8s PVC) is mounted at /data
# at RUNTIME, shadowing the image's dir — with a non-root user the mount comes
# root-owned and SQLite could not write insika.db. For the pilot
# (single-tenant container) root is acceptable; non-root hardening (fsGroup/
# init-chown) is left for k8s. See docs/DEPLOY.md.
RUN mkdir -p /data
WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /usr/local/bin/litestream /usr/local/bin/litestream
COPY . .

# The /data volume is mounted by the orchestrator, NOT by Docker's VOLUME
# instruction (Railway rejects it). INSIKA_DB points to /data (see ENV above).
EXPOSE 9292

# The entrypoint decides the boot: with LITESTREAM_REPLICA_URL set, it restores
# insika.db from the replica (fresh box) and supervises the app under Litestream
# (opt-in backup/DR — see deploy/entrypoint.sh + docs/DEPLOY.md); without the var, it
# `exec`s Falcon directly (zero cost, identical to the previous behavior). Falcon reads
# config.ru (Boot -> Wiring -> recovery BEFORE accepting connections); binds over http
# (the Railway/Ingress proxy terminates TLS). WEB_CONCURRENCY controls the number of
# forked processes (default 2; on a bigger box, raise it — see docs/DEPLOY.md on SQLite WAL).
CMD ["sh", "deploy/entrypoint.sh"]
