---
title: Core concepts
nav_order: 3
has_children: true
permalink: /core-concepts/
---

# Core concepts

An agent is data: a profile, what it is allowed to do, its tools, its skills, and
what fills its prompt. These six pages are the vocabulary everything else on this
site assumes. Each one has a runnable counterpart under
[`examples/`](https://github.com/guizaols/insika/tree/main/examples/).

- **[Agents](AGENTS.md)** — the profile, the three ways to create one, and every key on it.
- **[Limits and policy](POLICY.md)** — the five layers that decide what an agent may do and what stops it.
- **[Tools](TOOLS.md)** — code tools, data-defined tools, MCP servers, and why a tool call goes missing.
- **[Skills](SKILLS.md)** — playbooks the agent loads only when the conversation calls for them.
- **[Context](CONTEXT.md)** — what fills a turn's prompt, the token budget, and cross-session memory.
- **[Workflows](WORKFLOWS.md)** — when the order of work belongs in Ruby instead of a prompt.
{: .card-grid }
