# travel-planner

**Starter trail.** A trip-planning assistant built entirely from **declarative
data-tools** — no Ruby tool class, no rebuild. Three tools, three public
HTTPS APIs, zero API keys beyond your LLM provider's:

- `geocode_city` — Open-Meteo's geocoding API (city name → coordinates)
- `get_weather` — Open-Meteo's forecast API (coordinates → today's conditions)
- `convert_currency` — Frankfurter's reference exchange rates

```bash
DEEPSEEK_API_KEY=sk-... ruby travel-planner/agent.rb "3 days in Lisbon, budget 200 USD"
```

The model chains the first two tools itself (geocode, then weather) and
calls the third when a budget is mentioned — nothing here tells it the
order, the instructions just describe what each tool is for.

## Egress guard (SSRF protection)

Data-tools make **server-side** HTTP calls, so the engine ships an egress
guard that is strict by default: public HTTPS only. This template works
with zero configuration because all three endpoints are public HTTPS — a
tool pointed at `http://…`, `localhost`, or a private IP would be blocked
instead (`{ error: "destination blocked: …" }` back to the model, a clean
tool error, never a crash). Opting a private/internal target in is a
deployment env var (`INSIKA_EGRESS_ALLOW_HTTP`/`_PRIVATE`/`_HOSTS`), never a
DSL setting — see `docs/TOOLS.md`'s "MCP servers" / egress sections in the
installed gem's docs for the full contract.

## Edit it

Open `agent.rb` — it's the same file `insika new` copied and the same one
this README describes. Add a fourth data-tool, change the model, or point
an existing one at a different provider; nothing else needs to change.
