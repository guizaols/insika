# memory

**Cross-session memory.** With `memory true`, the agent gains a built-in
`remember` tool for durable facts, and those facts are injected back into the
prompt on later turns — including turns in a **different session**. Memory is
scoped per agent.

This is distinct from *session history* (the running transcript of one
conversation). Memory is the small set of durable facts that should outlive any
single conversation.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/memory/memory_agent.rb
```

Expected output (wording varies):

```
── session A ──
Got it — noted that you're vegetarian and based in Lisbon.
── session B ──
Since you're in Lisbon and vegetarian, here are a couple of veg-friendly spots …
```

Session B is a brand-new conversation — none of session A's messages are in its
context. The dinner suggestion is personal only because the *facts* were
remembered and re-injected.

## Notes

- `remember` is a **system tool**, wired automatically by the double gate
  "memory store present **and** `memory true`" — you don't add it to the allowlist.
- Without `INSIKA_DB`, memory lives in-process (fine for a single run, both
  sessions in one process). Set `INSIKA_DB=./memory.db` to make facts survive a
  restart.
- Facts and notes are also visible and editable in the control UI (`/studio`),
  per agent.
