# harness-code — a code agent on the harness engine

A **prototype** Claude-Code-style coding agent built entirely *on top of* the
harness engine (no core changes). It combines:

- a **FS/shell toolset** shipped as an autodiscoverable plugin
  (`plugins/harness-code/`): `read_file`, `list_dir`, `grep`, `write_file`,
  `edit_file`, `bash`;
- an **agent profile** (`harness-code`) that allows those tools and puts the
  write/shell ones behind the engine's human-approval gate;
- a **minimal CLI** (`bin/harness-code`) that talks to the engine over the same
  `POST /v1/responses` (SSE) contract used in production.

## Security boundary

Two independent controls protect the highest-risk tools:

1. **Sandbox (always on, enforced by the tools).** Every path a tool touches is
   resolved through `HarnessCode::Workspace`, which confines all operations to a
   single **workspace root** (`HARNESS_CODE_ROOT`, default: cwd). `..` traversal,
   absolute paths outside the root, and symlinks are rejected *before any IO* —
   the final path component may never be a symlink (a write target that is a
   symlink, including a *broken* one pointing outside the root, is refused rather
   than followed), and any existing target's realpath must stay inside the root.
   `bash` runs with its working directory pinned to the root
   (advisory — a shell can still reach absolute paths, which is why it is also
   approval-gated).
2. **Approval (reuses the engine).** `write_file`, `edit_file`, and `bash` are
   marked `side_effect: true` in the plugin manifest and listed in the profile's
   `approvals_required`. The builtin `ApprovalRequired` policy marks them and the
   existing `ToolEnvelope` gate **suspends the turn** (`:waiting`) until an
   operator resolves the pending action via `approve_action` — the same durable,
   crash-safe path used everywhere else. No parallel approval path was created.

Read-only tools (`read_file`, `list_dir`, `grep`) are not approval-gated.

> **Hard requirement — `side_effect: true` ⇒ `approvals_required`.** The engine
> does *not* auto-gate side-effecting tools; the manifest's `side_effect` flag
> only informs the checkpoint/resume machinery. The human gate is applied purely
> by the profile listing the tool in `approvals_required`. Therefore **every**
> tool marked `side_effect: true` in `harness.plugin.yml` **MUST** appear in the
> profile's `approvals_required` — this is a non-negotiable security
> prerequisite, not a convenience. Omitting one lets a mutating/shell tool run
> ungated. To make this drift impossible, `boot.rb` derives `approvals_required`
> directly from the manifest (union of all `side_effect: true` tools) instead of
> hard-coding the list.

## Run it

Two terminals. **Server:**

```bash
HARNESS_CODE_ROOT=/path/to/your/project \
DEEPSEEK_API_KEY=sk-...            # or ANTHROPIC_API_KEY / OPENAI_API_KEY (+ set HARNESS_CODE_PROVIDER/MODEL) \
ruby examples/harness-code/server.rb
```

**CLI** (prints the exact command on server startup):

```bash
HARNESS_CODE_URL=http://localhost:9292 \
HARNESS_CODE_TOKEN=local-code \
ruby examples/harness-code/bin/harness-code
```

Example session:

```
you> what ruby files are here and what does the main one do?
code> → list_dir
      → read_file
      This project has ...

you> add a frozen_string_literal magic comment to lib/foo.rb
code> → edit_file
⚠ approval required: edit_file({"path":"lib/foo.rb","old_string":"...","new_string":"..."})
approve? [y/N] y
→ approved
      Done — added the magic comment.
```

Set `HARNESS_CODE_YES=1` to auto-approve (non-interactive/demo).

## Env

| var | default | meaning |
|-----|---------|---------|
| `HARNESS_CODE_ROOT` | cwd | workspace root the tools are sandboxed to |
| `HARNESS_CODE_TOKEN` | `local-code` | bearer for `/v1/responses` |
| `HARNESS_CODE_MODEL` | `deepseek-chat` | model id |
| `HARNESS_CODE_PROVIDER` | `deepseek` | RubyLLM provider |
| `HARNESS_DB` | (unset → memory) | SQLite path for durable state |
| `BIND` | `http://localhost:9292` | server bind URL (server.rb) |
| `HARNESS_CODE_URL` | `http://localhost:9292` | server URL (CLI) |
| `HARNESS_CODE_YES` | (unset) | `1` = auto-approve every FS/shell action |

## Layout

```
plugins/harness-code/         # the toolset (autodiscoverable plugin, RFC-0003)
  harness.plugin.yml          # manifest: tool names + side_effect flags
  plugin.rb                   # register(api): block factories, shared Workspace
  lib/harness_code/
    workspace.rb              # the sandbox boundary
    tools/{read_file,list_dir,grep,write_file,edit_file,bash}.rb

examples/harness-code/        # the example app (consumes the core as a lib)
  boot.rb                     # deployment wiring: engine + plugin + profile + app
  server.rb                   # Async::HTTP server launcher
  bin/harness-code            # the CLI client (net/http + json, stdlib only)

spec/plugins/harness_code/    # tests: workspace, tools, approval wiring
```

## Not in the prototype (next steps)

- Approval over the pure `/v1/responses` contract: the OpenAI Responses adapter
  has no frame for `approval_requested`, so the CLI watches the raw `/v1/events`
  SSE stream and resolves via `POST /v1/commands/approve_action`. A first-class
  approval frame in the adapter would remove that side-channel.
- `bash` blocks the fiber for the duration of the command (no hard timeout kill);
  a production runner would spawn detached and kill on timeout.
- Diff previews in the approval prompt, richer `grep` (globs/ignore files),
  streaming shell output, multi-workspace, and per-tool allow/deny beyond the
  read-vs-write split.
