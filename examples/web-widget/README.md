# web-widget

**One `<script>` tag and you have an agent on your site.** No backend of yours, no
build step, no npm. This is the native channel for a team with no messaging stack —
if you already own WhatsApp or Slack, you want [relay-channel](../relay-channel/)
instead.

```html
<script src="http://127.0.0.1:9494/channels/web/asset/widget.js"
        data-agent="support" data-title="Ask Ocean Drop" defer></script>
```

That tag is the whole of `index.html` that matters. The rest of the page is a
pretend shop, so you can see the widget on something.

Full contract: [docs/CHANNELS.md](../../docs/CHANNELS.md#the-web-widget).

## Run it

Two terminals, no accounts, no tunnels.

**1 — the engine, with the widget turned on.** Both allowlists are the switch, and
a chat rate limit is required (a public endpoint with an LLM behind it and no
ceiling is an unmetered bill):

```bash
export INSIKA_WIDGET_ORIGINS=http://127.0.0.1:8080
export INSIKA_WIDGET_AGENTS=support
export DEEPSEEK_API_KEY=sk-…

ruby examples/web-widget/support_agent.rb
```

`support_agent.rb` is a five-line agent with `chat_rate_limit` set on it, so you do
not need to touch platform settings to satisfy the gate.

**2 — your site**, on the origin you allowlisted above:

```bash
ruby -run -e httpd examples/web-widget -p 8080
```

Open <http://127.0.0.1:8080> and click the bubble.

> The `src` in `index.html` points at `127.0.0.1:9494`, which is where
> `support_agent.rb` serves. Change both if you move ports — the widget derives the
> engine's address from its own `src`, so that one URL is the only place it is
> configured.

## What to try

- **Ask something, then reload the page.** The conversation continues: the widget
  kept the session id the engine minted for it in `localStorage`.
- **Open devtools and change `data-agent` to something else.** You get a `422`. An
  anonymous visitor addresses `INSIKA_WIDGET_AGENTS` and nothing else.
- **Load the page from `http://localhost:8080` instead of `127.0.0.1`.** Different
  origin, so it is refused — the allowlist is exact-match on purpose.
- **Unset `INSIKA_WIDGET_AGENTS` and restart.** The routes are gone (`404`), not
  open. Both allowlists are the switch.
- **Drop `chat_rate_limit` from the agent and restart.** `503`. This is the one
  place the engine refuses to serve rather than warn.

## Theming

The widget's entire styling API is a block of CSS custom properties. Set them
anywhere on your page and they win:

```css
:root {
  --insika-accent: #0f766e;   --insika-on-accent: #fff;
  --insika-bg: #fff;          --insika-fg: #111827;
  --insika-muted: #f0fdfa;    --insika-border: rgba(0,0,0,.12);
  --insika-font: "Inter", system-ui, sans-serif;
  --insika-offset: 20px;
}
```
