# Harness Studio (Fase 4)

UI de gestão server-rendered (Roda + Hotwire), montada sob `/studio`. Substitui o
agent-studio do OpenClaw — **um processo, um deploy, uma linguagem**. Fala com o
runtime pela mesma superfície da API (despacha Commands no `CommandBus`, lê o
`ProfileSource`/stores); **nunca** escreve em store direto.

## Rodar (sem Node)

O bundle de front (`assets/dist/*`) é **versionado**. `ruby scripts/serve_real.rb`
serve o Studio direto — não precisa de Node:

```bash
export DEEPSEEK_API_KEY=...        # chave do agente (openclaw/.env.local)
export ADMIN_TOKEN=troque-isto     # token de login do Studio (D7)
ruby scripts/serve_real.rb         # → http://localhost:9292/studio
```

Login em `/studio/login` com o `ADMIN_TOKEN`. Cookie de sessão httpOnly/SameSite=Lax
(D7); o secret de sessão deriva do token de admin (estável entre restarts).

## Editar o front (precisa de Node)

Só quem mexe no CSS/JS precisa do Node. O pipeline é **esbuild + Tailwind** (D8):

```bash
cd studio
npm install
npm run build        # gera assets/dist/{application.js,application.css} (versionados)
npm run watch        # rebuild contínuo em dev
```

- `assets/src/application.js` — entry: Stimulus + Turbo + controllers.
- `assets/src/controllers/` — islands (D9): `live-transcript` (SSE de /v1/events),
  `code-editor` (CodeMirror 6; usado na autoria de prompts/skills — Etapa F).
- `assets/src/application.css` — Tailwind (`base`/preflight) + design system em
  `@layer components`.

CSP estrita `'self'` (sem `unsafe-inline`): todo JS/CSS vem do bundle same-origin.

## Estrutura

```
studio/
  app.rb            # Studio::App (Roda): rotas, auth por cookie, CSRF, CSP, assets
  views/            # ERB (escape automático): layout, login, agents, playground, 404
  assets/src/       # fontes do front (Node)
  assets/dist/      # bundle versionado (servido por /studio/assets/dist/*)
  package.json      # build:css / build:js / build / watch
  tailwind.config.js
```

## Estado (Etapa E — tasks 12-14)

Páginas prontas: **login**, **agents (lista)**, **playground (SSE)**. As páginas de
autoria (agents-detail/prompts/skills/tools/mcp/settings/system-files/chats) chegam
nas Etapas F/G. Backend de config (Etapas A–D) já completo.
