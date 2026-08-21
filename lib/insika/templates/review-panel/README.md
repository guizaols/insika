# review-panel

**Teams trail.** The `Insika.system` snippet from the gem's main examples
README, promoted to a runnable template: a "reviewer" lead with no
expertise of its own delegates to two specialists — security and
performance — IN PARALLEL, then synthesizes one prioritized fix.

```bash
DEEPSEEK_API_KEY=sk-... ruby review-panel/agent.rb
```

`panel.reply("reviewer", …)` — the target agent is always explicit; with
several agents in one system, inferring which one should answer would be a
guess, and a wrong guess is a silently wrong conversation.

## Edit it

Add a third specialist (a `style` reviewer, say), list it in `subagents`,
and the lead's synthesis prompt already generalizes — it doesn't name the
specialists, just says "both".
