# research-analyst

**Advanced trail.** Four agents in one `Insika.system`: three specialists
(market, technical, risk) and a lead ("analyst") that has no expertise of
its own and must delegate. The MODEL decides to fan out — nothing in Ruby
orchestrates the parallel calls.

```bash
DEEPSEEK_API_KEY=sk-... ruby research-analyst/agent.rb "a subscription box for specialty coffee"
```

Under the hood: the lead calls `spawn_subagents` once with all three
specialist ids, they run **in parallel** (each in an isolated context — a
child never sees the parent's conversation), and the lead synthesizes their
three answers into one recommendation.

Nothing forces the model to delegate — that's the trade of a model-driven
pattern over a hand-coded workflow. If it answers alone instead, the fix is
the lead's prompt, not the code: it needs to be told, plainly, that it has
no expertise of its own.

## Edit it

Add a fourth specialist (`agent("competitors") { … }`, then add it to
`subagents`), or turn any specialist into a `Insika.agent` with its own
data-tools — a subagent is an ordinary agent, capability included.
