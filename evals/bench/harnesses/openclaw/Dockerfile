# OpenClaw as it ships, pinned. The version is the one the deployment we know runs
# (2026.8.1) — a bench against "latest" is a bench nobody can reproduce next month.
FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g openclaw@2026.8.1 \
 && npm cache clean --force

ENV OPENCLAW_HOME=/oc
ENV OPENCLAW_STATE_DIR=/oc
# Two configs, one per scorecard: A allowlists the store's ten tools, B leaves
# OpenClaw's own sixty-odd on beside them. The driver installs the right one.
COPY openclaw-a.json /etc/bench/openclaw-a.json
COPY openclaw-b.json /etc/bench/openclaw-b.json
COPY driver /usr/local/bin/driver
RUN chmod +x /usr/local/bin/driver && mkdir -p /oc/workspace/bench

# The system prompt is mounted, not baked: scorecard A gives every entrant the same
# one, and the only way to guarantee that is for there to be one file.
CMD ["sleep", "infinity"]
