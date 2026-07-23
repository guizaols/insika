# skills

A **skill** is a named playbook the agent loads on demand. The agent sees only the
skill's name and one-line description up front (**Level 1**, cheap — it's always in
the prompt); it pulls the full body into context (**Level 2**) via the built-in
`load_skill` tool, and only when a turn actually calls for it. That's *progressive
loading*: an agent can "know" many skills exist while paying for the text of only
the ones it opens.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/skills/skill_agent.rb "refund order #4471"
```

Expected behavior (wording varies):

```
→ load_skill("refunds")
I can help with that. Order #4471 — can you confirm the purchase was within the
last 30 days? If so, I can offer store credit right away, or a refund to your
card if you'd prefer.
```

The agent loaded the `refunds` skill, then followed its steps (confirm the window,
offer store credit first) instead of improvising.

## Notes

- `load_skill` is a **system tool** — it's wired automatically whenever an agent
  has skills, so you never add it to the tool allowlist.
- Skills live in the store (SQLite), not in code. You can add or edit one at
  runtime through the control UI or `POST /v1/agents` — no redeploy.
- A skill body is a `SKILL.md` (YAML frontmatter `name` + `description`, then the
  playbook). The DSL wraps the frontmatter for you; raw `SKILL.md` content passes
  through untouched.
