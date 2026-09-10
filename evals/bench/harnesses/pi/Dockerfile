# Pi as it ships, pinned. It carries no MCP by design, so the store reaches it
# through the bench's own bridge extension (mcp-bridge.js) — recorded beside its row,
# because that tool layer is ours and every other entrant's came from its vendor.
FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @earendil-works/pi-coding-agent@0.84.1 \
 && npm cache clean --force

RUN mkdir -p /etc/bench /work
COPY mcp-bridge.js /etc/bench/mcp-bridge.js
COPY driver /usr/local/bin/driver
RUN chmod +x /usr/local/bin/driver

ENV PI_OFFLINE=1
WORKDIR /work
CMD ["sleep", "infinity"]
