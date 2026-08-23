# Insika Studio

Server-rendered management UI (Roda + Hotwire), mounted under `/studio`. Replaces
OpenClaw's agent-studio — **one process, one deploy, one language**. It talks to the
runtime through the same surface as the API (dispatches Commands on the `CommandBus`,
reads the `ProfileSource`/stores); it **never** writes to a store directly.

## Run (without Node)

The front-end bundle (`assets/dist/*`) is **checked in**. `ruby scripts/serve_real.rb`
serves the Studio directly — no Node required:

```bash
export DEEPSEEK_API_KEY=...        # the agent's key
export ADMIN_TOKEN=change-me       # Studio login token
ruby scripts/serve_real.rb         # → http://localhost:9292/studio
```

Log in at `/studio/login` with the `ADMIN_TOKEN`. Session cookie is httpOnly/SameSite=Lax;
the session secret is derived from the admin token (stable across restarts).

## Edit the front-end (needs Node)

Only people touching the CSS/JS need Node. The pipeline is **esbuild + Tailwind**:

```bash
cd studio
npm install
npm run build        # generates assets/dist/{application.js,application.css} (checked in)
npm run watch        # continuous rebuild in dev
```

- `assets/src/application.js` — entry: Stimulus + Turbo + controllers.
- `assets/src/controllers/` — islands: `live-transcript` (SSE from /studio/events),
  `live-home` (the overview's live layer — same channel), `code-editor`
  (CodeMirror 6; used for authoring prompts/skills).
- `assets/src/application.css` — Tailwind (`base`/preflight) + design system in
  `@layer components`.

Strict CSP `'self'` (no `unsafe-inline`): all JS/CSS comes from the same-origin bundle.

## Motion

`layout.erb` declares `<meta name="view-transition" content="same-origin">`.
Turbo 8 Drive then routes same-origin visits through the View Transitions API —
no JS. The transition itself lives in `application.css` (`::view-transition-*`):
a ~160ms cross-fade, the sidebar pinned via `view-transition-name` so it reads
as fixed chrome, and a `prefers-reduced-motion` kill switch. Browsers without
support degrade to the plain swap.

## Miller columns / master-detail

Agents, Tools, MCP and the session viewer render a two-column drill whose
detail pane IS a `<turbo-frame>`. The pattern, end to end:

- **View**: index and detail share the master partial; rows carry
  `data-turbo-frame="<id>" data-turbo-action="advance"` so the detail loads
  beside the list while the URL still moves (refresh/deep-link work). Links
  that must leave the shell carry `data-turbo-frame="_top"`.
- **Route** (Roda): the render helper branches on
  `turbo_frame?("<id>")` — the `Turbo-Frame` request header. A frame request
  renders the pane alone (`render(view, locals: { frame_only: true },
  layout: false)`); anything else renders the full two-column shell. Non-matching
  frame ids and plain browser hits both get the full page.
- **Flash**: frame responses never see the layout, so the pane renders its own
  flash strip when `frame_only` — otherwise save confirmations vanish on frame
  submits.
- **Redirects** after POSTs inside a frame land back on the selected record's
  URL (e.g. `/studio/mcp?i=<name>`), because Turbo follows the 303 with the
  same frame header.

## Structure

```
studio/
  app.rb            # Studio::App (Roda): routes, cookie auth, CSRF, CSP, assets
  views/            # ERB (auto-escaped): layout, login, agents, playground, 404
                    #   + _agent_tab_* partials (one per detail tab, no abstraction)
  assets/src/       # front-end sources (Node)
  assets/dist/      # checked-in bundle (served from /studio/assets/dist/*)
  package.json      # build:css / build:js / build / watch
  tailwind.config.js
```

## Status (Stage E — tasks 12-14)

Pages ready: **login**, **agents (list)**, **playground (SSE)**. The authoring pages
(agents-detail/prompts/skills/tools/mcp/settings/system-files/chats) arrive in
Stages F/G. Config backend (Stages A–D) already complete.
