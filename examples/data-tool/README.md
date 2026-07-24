# data-tool

A tool defined as **data, not code**. `data_tool` declares an HTTP call — a name,
a JSON-Schema parameter list, and a URL template — and the running agent calls it
in its tool-loop. There's no Ruby tool class and no rebuild: the tool is a row you
could equally create at runtime through the control UI or a manifest.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/data-tool/currency_agent.rb "1 USD in BRL?"
```

Expected output (rate and wording vary):

```
Right now 1 USD is about 5.43 BRL (ECB reference rate for 2026-07-23).
```

Under the hood: the model calls `convert_currency(from: "USD", to: "BRL")`, the
harness fills the URL template and does the GET to
`https://api.frankfurter.app/latest`, and the JSON comes back into the tool-loop
for the model to summarize.

## Egress guard (SSRF protection) — read this

Data-tools make **server-side** HTTP calls, so the harness ships an egress guard
that is **strict by default: public HTTPS only.** This example works with no
configuration because its endpoint is public HTTPS.

A tool pointed at `http://…`, `localhost`, or a private/internal IP is **blocked**
by default — that's the SSRF defense. Two things to know:

- **It fails as a tool error, not a crash.** A blocked call returns
  `{ error: "destination blocked: …" }` to the model, so the conversation may
  *look* like it worked while nothing left the process. Always confirm real calls
  by the tool trace (a healthy call shows the backend's `200`), not by the reply.
- **Opting in is a deployment decision, not a DSL one.** To let tools reach an
  internal/private backend you set `INSIKA_EGRESS_ALLOW_HTTP` /
  `INSIKA_EGRESS_ALLOW_PRIVATE` and pin `INSIKA_EGRESS_HOSTS` on the *deployment*
  (see [`docs/DEPLOY.md`](../../docs/DEPLOY.md)). The in-process DSL runtime here
  is intentionally strict — public HTTPS only.

## Notes

- `{{from}}`/`{{to}}` are model parameters, validated against the tool's schema.
  `{{ctx.chat_id}}` / `{{ctx.store_id}}` / `{{ctx.agent_id}}` are also available and
  are filled server-side from the turn context (never by the model).
- Secrets go in headers named in `secret_headers` (e.g. a bearer token) and are
  masked in traces — never inline them in the URL or body.
