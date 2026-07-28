# Insika Studio (Phase 4)

Server-rendered management UI (Roda + Hotwire), mounted under `/studio`. Replaces
OpenClaw's agent-studio — **one process, one deploy, one language**. It talks to the
runtime through the same surface as the API (dispatches Commands on the `CommandBus`,
reads the `ProfileSource`/stores); it **never** writes to a store directly.

## Run (without Node)

The front-end bundle (`assets/dist/*`) is **checked in**. `ruby scripts/serve_real.rb`
serves the Studio directly — no Node required:

```bash
export DEEPSEEK_API_KEY=...        # the agent's key (openclaw/.env.local)
export ADMIN_TOKEN=change-me       # Studio login token (D7)
ruby scripts/serve_real.rb         # → http://localhost:9292/studio
```

Log in at `/studio/login` with the `ADMIN_TOKEN`. Session cookie is httpOnly/SameSite=Lax
(D7); the session secret is derived from the admin token (stable across restarts).

## Edit the front-end (needs Node)

Only people touching the CSS/JS need Node. The pipeline is **esbuild + Tailwind** (D8):

```bash
cd studio
npm install
npm run build        # generates assets/dist/{application.js,application.css} (checked in)
npm run watch        # continuous rebuild in dev
```

- `assets/src/application.js` — entry: Stimulus + Turbo + controllers.
- `assets/src/controllers/` — islands (D9): `live-transcript` (SSE from /studio/events),
  `code-editor` (CodeMirror 6; used for authoring prompts/skills — Stage F).
- `assets/src/application.css` — Tailwind (`base`/preflight) + design system in
  `@layer components`.

Strict CSP `'self'` (no `unsafe-inline`): all JS/CSS comes from the same-origin bundle.

## Structure

```
studio/
  app.rb            # Studio::App (Roda): routes, cookie auth, CSRF, CSP, assets
  views/            # ERB (auto-escaped): layout, login, agents, playground, 404
  assets/src/       # front-end sources (Node)
  assets/dist/      # checked-in bundle (served from /studio/assets/dist/*)
  package.json      # build:css / build:js / build / watch
  tailwind.config.js
```

## Status (Stage E — tasks 12-14)

Pages ready: **login**, **agents (list)**, **playground (SSE)**. The authoring pages
(agents-detail/prompts/skills/tools/mcp/settings/system-files/chats) arrive in
Stages F/G. Config backend (Stages A–D) already complete.
