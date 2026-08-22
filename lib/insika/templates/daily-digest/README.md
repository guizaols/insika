# daily-digest

**Always-on trail.** The report pipeline in one file: a recurring
`schedule` (the engine's own tick fires it), a `save_artifact`
tool (the report destination), and a store-free skill describing
*how* to build the report. No database, no store content — the day's
numbers are fake, inline text.

```bash
DEEPSEEK_API_KEY=sk-... ruby daily-digest/agent.rb
```

Expected output: a reply ending in `Report: /studio/artifacts/<id>`.

```bash
DEEPSEEK_API_KEY=sk-... ruby daily-digest/agent.rb --serve
```

Then open `/studio`, log in with the printed token, and either wait for the
schedule (22:00 America/Sao_Paulo) or send a message to the "reporter" agent
in the Playground — the artifact lands on the Artifacts tab either way.

## What's real here

- The **schedule** is a live engine feature: the tick actually fires this
  turn at the cron time, in the same process, no external cron needed.
- The **artifact** is a real signed/authenticated URL the report is saved
  to — open it and the HTML renders with its own strict CSP (`default-src
  'none'`), so the inline SVG chart has to be self-contained by
  construction, not by convention.
- The **numbers** are not. Swap the literal string in `agent.rb` for a
  `data_tool` against your own sales API and nothing else changes.

## Edit it

The skill's instructions are the actual report spec — change the palette,
add a second table, or add another chart. The schedule's `cron`/`tz` are
plain arguments.
