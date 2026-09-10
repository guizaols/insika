# OpenCode as it ships, pinned. Node install, OpenRouter as the provider (it is a
# first-class one in its model catalogue), and the store as a remote MCP server.
FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g opencode-ai@1.18.30 \
 && npm cache clean --force

RUN mkdir -p /etc/bench /work
# Two configs, one per scorecard: A is the store's ten tools and nothing else, B is
# OpenCode with its own read/write/bash/task surface on top of the same store.
COPY opencode-a.json /etc/bench/opencode-a.json
COPY opencode-b.json /etc/bench/opencode-b.json
COPY driver /usr/local/bin/driver
RUN chmod +x /usr/local/bin/driver

# No telemetry, no auto-update inside a pinned image.
ENV OPENCODE_DISABLE_AUTOUPDATE=1
WORKDIR /work
CMD ["sleep", "infinity"]
