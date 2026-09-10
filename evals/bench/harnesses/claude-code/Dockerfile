# Claude Code as it ships, pinned. Pointed at OpenRouter through ANTHROPIC_BASE_URL,
# which is how it runs the same model as every other entrant: it speaks the Anthropic
# Messages shape and OpenRouter serves one.
FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code@2.1.266 \
 && npm cache clean --force

RUN mkdir -p /etc/bench /work
COPY mcp.json /etc/bench/mcp.json
COPY driver /usr/local/bin/driver
RUN chmod +x /usr/local/bin/driver

ENV ANTHROPIC_BASE_URL=https://openrouter.ai/api
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# Thinking ON at a medium budget, which is what every other entrant runs here. An
# earlier cut left it off after this model returned its whole answer inside a
# `thinking` block through OpenRouter's Anthropic shim; a 5/5 probe at this budget
# answers normally, so the row is at parity with the other five.
ENV MAX_THINKING_TOKENS=4096
# Non-root, because scorecard B needs --dangerously-skip-permissions and Claude Code
# refuses that flag as root. The same user runs scorecard A, so the two rows differ
# in what the harness may do and in nothing else.
RUN useradd --create-home --uid 1001 bench && chown -R bench:bench /work
USER bench
WORKDIR /work
CMD ["sleep", "infinity"]
