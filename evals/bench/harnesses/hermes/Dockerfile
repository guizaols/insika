# Hermes as it ships, pinned to the latest published release. Python; the CLI's
# one-shot mode (-q/--oneshot) is the turn, and AGENTS.md in the working directory is
# the system prompt — the same file every other entrant is given.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir hermes-agent==0.19.0 "mcp==1.28.1"

# The pip install of Hermes does not pull the MCP client itself, so an HTTP MCP
# server is refused with "upgrade the mcp package" until it is there. Pinned, like
# everything else in this bench.

COPY driver /usr/local/bin/driver
COPY setup /usr/local/bin/setup
RUN chmod +x /usr/local/bin/driver /usr/local/bin/setup && mkdir -p /work
WORKDIR /work
CMD ["sleep", "infinity"]
