# OUR ENTRY, as an image, so it is `docker compose exec` like every other entrant
# instead of a host process. Build context is the REPO ROOT: the driver runs the
# engine from source, which is what "our entry" has to mean while the bench and the
# engine move together.
#
#   docker compose build insika
#
# Same base as the production image (ruby:4.0.6-slim, YJIT on), minus Litestream and
# the server: a bench turn is one embedded reply per process, no Falcon, no port.
FROM ruby:4.0.6-slim AS builder

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libssl-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
# The Gemfile consumes the gemspec, which reads version.rb and packaging.rb — all
# three before `bundle install`, exactly as the production image does.
COPY Gemfile Gemfile.lock insika.gemspec ./
COPY lib/insika/version.rb lib/insika/version.rb
COPY lib/insika/packaging.rb lib/insika/packaging.rb
RUN bundle install && rm -rf "${BUNDLE_PATH}"/cache/*.gem

FROM ruby:4.0.6-slim

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RUBY_YJIT_ENABLE=1 \
    INSIKA_DB=/data/insika.db \
    BENCH_PROMPT=/prompt/AGENTS.md
# The store is on the compose network — a private address, which the engine refuses
# by default and has to be told to allow. Same flags any deployment uses.
ENV INSIKA_EGRESS_ALLOW_HTTP=1 \
    INSIKA_EGRESS_ALLOW_PRIVATE=1

RUN mkdir -p /data
WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

# `driver` on PATH, under bundler, from /app — the same shape as every other
# entrant's adapter.
RUN printf '#!/bin/sh\nexec bundle exec ruby /app/evals/bench/harnesses/insika/driver\n' \
      > /usr/local/bin/driver && chmod +x /usr/local/bin/driver

CMD ["sleep", "infinity"]
