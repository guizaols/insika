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

Most Console-shell pages (see Design system below — Agents, Tools, MCP,
Chats/Session, Customers, Facts, Refinement) render a two-column drill whose
detail pane IS a `<turbo-frame>`. Skills, Settings, Knowledge and Evals use
the same `.drill` two-column layout but link to a plain full-page detail —
no `<turbo-frame>` — so the pattern below applies to the frame-based group
only:

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

## Design system

A visual redesign (13 tasks) replaced the original card-per-record, chip-filter
look with three page shells built on a shared token set (`views/_kpi.erb`,
`.chart`, `.page-head`, `table.grid`, `.drill` from the Task 1 foundation).
Every page in `views/` now uses one of these, or the plain `.page-head` +
`.card`/list layout for pages simple enough not to need one:

- **Console** (miller columns / master-detail drill, a `.drill` master list
  beside a detail pane): **Agents**, **Tools**, **MCP**, **Chats** + the
  **Session** viewer, **Customers**, **Facts**, **Refinement** render the
  detail pane as a `<turbo-frame>` — row clicks advance the URL without a
  full reload. **Skills**, **Settings**, **Knowledge**, **Evals** use the
  same two-column `.drill` layout but link to a plain full-page detail, with
  no `<turbo-frame>`.
- **Board** (a `.kpi-strip` of `_kpi.erb` tiles opens the page, followed by an
  inline-SVG `.chart`): **Home** (the Overview — KPI strip + a 24h `.chart`
  line + a 14-day bar chart), **Funnel** (a KPI strip + `.chart-funnel` per
  store), **Follow-ups** (a KPI strip + a `table.grid` of records).
- **Ledger** (`table.grid`: a sticky-header table, row-actions revealed on
  hover, `.identity`/`.status` cells): **Artifacts**, **Harvest**, **Tasks**.

**Playground** is its own full-height chat surface (config bar, scrolling
transcript, pinned composer) under a `.page-head`, not one of the three
shells above. **Approvals**, **Task** (detail), and **System files** are
plain `.page-head` + card/list pages, simple enough that they don't need a
shell. **Parity** predates this redesign and wasn't converted — it only
picked up the shared `crumbs_for` breadcrumb and an arrow-in-label cleanup
from Task 1; its `table.grid` markup is a coincidental pre-existing table,
not the Ledger shell, and it still renders `.pill` throughout rather than
`.identity`/`.status`.

### Shared partials

- `_kpi.erb(label:, value:, sub: nil, delta: nil)` — one metric in a
  `.kpi-strip`; `delta` colors green/red from a leading `-`.
- `_identity.erb(name:, sub:, id:)` — the avatar + name + mono sub-line unit
  every list of agents, customers and sessions renders a row from; the avatar
  hue comes from `avatar_hue(id)` so the same subject keeps its color across
  pages.
- `_empty.erb(icon:, text:, action_href: nil, action_label: nil)` — the empty
  state for a list: an icon, why it's empty, and (optionally) the one thing
  to do about it.

### Shared helpers (`app.rb`)

- `avatar_hue(id)` — a stable 1–9 hue bucket derived from the id's bytes, so
  an avatar's color never changes across renders or pages.
- `short_id(uuid)` — the readable 8-char head of a uuid; callers keep the
  full value in `title`/`data-copy` so nothing is lost to the truncation.
- `status_class(status)` — maps a status string to one of `ok`/`run`/`warn`/
  `err`/`neutral`/`info` for the `.status` pill, one mapping shared by every
  page instead of each view inventing its own.
- `agent_filter_form(path, current)` — the one shared "Agent: [all|<id>]"
  select, auto-submitting on change; replaces the old per-page chip rows.

### Embedded fonts

IBM Plex Sans (variable, weights 100–700, one 44KB `woff2-variations` file)
and IBM Plex Mono (400/500/600, three `woff2` files) — OFL-licensed, latin
subset — live under `assets/dist/fonts/` and are declared as `@font-face` at
the top of `application.css`, served same-origin via `font_path` (`app.rb`)
and preloaded from `layout.erb`. They are embedded rather than pulled from a
CDN (e.g. Google Fonts) because the Studio's CSP is `'self'` with no widened
`font-src`: a CDN font would either need a CSP exception or fail to load.
Same-origin fonts also mean no external request, and no runtime dependency
that can go down or get blocked, on every page load.
