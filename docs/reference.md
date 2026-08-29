---
title: Reference
nav_order: 8
has_children: true
permalink: /reference/
---

# Reference

The removability map, plus the paste-prompts that hand a journey to a coding
agent. A running instance serves each prompt at `GET /docs/<name>.md`, so you can
point Claude Code, Codex or Cursor at the URL instead of pasting the text.

- **[The domain-free core](domain.md)** — what ships in the gem, what a deployment declares, and how to clear it.
- **[Prompt — run every example](prompts/RUN-EXAMPLES.md)** — run `examples/` one at a time and explain what each proves.
- **[Prompt — add a tool or skill](prompts/ADD-TOOL.md)** — pick the right kind, wire the allowlist, prove it with one turn.
- **[Prompt — diagnose a failed turn](prompts/DIAGNOSE-TURN.md)** — symptom to mechanism, then fix one thing.
- **[Prompt — go live](prompts/GO-LIVE.md)** — tokens, volume, deploy, one authenticated turn, and the backup hole.
{: .card-grid }
