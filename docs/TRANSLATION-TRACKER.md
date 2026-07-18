# Translation Tracker (PT -> EN)

Tracks the mechanical Portuguese -> English translation of the `harness` core
library (FOLLOWUP §5.1). Scope of this pass: **comments, log/error/exception
messages and developer-facing strings** in `lib/harness/**/*.rb` and
`lib/harness.rb`.

Out of scope for this pass (by design): public identifiers, wire/API-contract
strings (SSE event names, JSON keys, `status` values, OTEL span attributes),
and everything under `spec/`, `server/`, `studio/`, `bin/`.

## Method / safety net

Every batch was validated against the full RSpec suite (~1325 examples). No
example may go red. Error messages that are asserted **verbatim** by a spec are
deliberately left in Portuguese here (translating them would require
coordinated edits to `spec/`, which is out of scope for this pass) and are
listed under "Deliberately deferred" below.

## Translated in this pass

### Core engine
- `lib/harness/command_bus.rb`
- `lib/harness/errors.rb`
- `lib/harness/event_stream.rb`
- `lib/harness/middleware.rb`
- `lib/harness/session_actor.rb`
- `lib/harness/recovery.rb`
- `lib/harness/store.rb`
- `lib/harness/tool_envelope.rb`
- `lib/harness/executor.rb`
- `lib/harness/task_actor.rb`

### Stores / chat
- `lib/harness/stores/sqlite.rb`
- `lib/harness/stores/memory.rb`
- `lib/harness/chat_builder.rb`

### Commands
- `lib/harness/command.rb`
- `lib/harness/commands/*.rb` (all 33 command handlers)

### Context
- `lib/harness/context/builder.rb`, `catalog_provider.rb`, `fragment.rb`,
  `priority.rb`, `provider.rb`
- `lib/harness/context/providers/*.rb` (memory, prompt, request, session,
  skill, tool_search)

### Tools & tool infra
- `lib/harness/tool_definition.rb`, `tool_registry.rb`, `tool_catalog.rb`,
  `tool_manifest.rb`, `tool_store.rb`, `tool_trace_store.rb`,
  `overlay_tool_registry.rb`
- `lib/harness/tools/*.rb` (a2a_remote, data_defined_tool, load_skill,
  remember, tool_search) — comments only; model-facing descriptions deferred
  (see below)

### Stores / catalogs
- `lib/harness/session_store.rb`, `task_store.rb`, `checkpoint_store.rb`,
  `checkpoint.rb`, `config_store.rb`, `memory_store.rb`, `mcp_store.rb`,
  `agent_file_store.rb`, `system_file_store.rb`, `pending_action_store.rb`,
  `skill_store.rb`, `settings_store.rb`, `llm_provider_store.rb`,
  `prompt_catalog.rb`, `skill_catalog.rb`

### Capability / policy / registry / telemetry
- `lib/harness/capability_registry.rb`, `capability/resolved_tool.rb`,
  `policy/engine.rb`, `policy/policy.rb`, `policy_registry.rb`, `registry.rb`,
  `allowlist.rb`, `workflow_registry.rb`, `hooks.rb`, `coercion.rb`,
  `event.rb`, `turn_state.rb`, `token_estimator.rb`, `telemetry.rb`,
  `telemetry/recorder.rb`

### Top-level / edge
- `lib/harness.rb`
- `lib/harness/egress_guard.rb`, `secret_masking.rb`, `http_client.rb`,
  `mcp_http_client.rb`, `mcp_tool_ingestor.rb`, `pack.rb`, `pack_importer.rb`,
  `plugin.rb`, `plugin/loader.rb`, `profile_source.rb`, `frontmatter.rb`,
  `agent_profile.rb`, `llm_configurator.rb`

All comments/docstrings were translated. Non-locked, non-asserted
error/log/exception messages were translated too. All parse (`ruby -c`) and the
full suite stays green (1325 examples, 0 failures).

## Deliberately deferred (contract-locked error messages)

These string literals are asserted verbatim by specs. Translating them requires
a coordinated `lib` + `spec` change and is deferred to a follow-up pass. Each
entry: fragment asserted -> source file(s) / spec(s).

| PT fragment (asserted) | Source | Spec |
| --- | --- | --- |
| `tool excedeu` | `tool_envelope.rb` | `executor_pipeline_spec.rb` |
| `irrecuperável: sem checkpoint` | `recovery.rb` | `recovery_spec.rb`, `server/admin_app_spec.rb` |
| `não registrado em tool_registry` | `executor.rb` | `executor_capability_spec.rb` |
| `middleware curto-circuitou sem halt_reason` | `executor.rb` | `executor_pipeline_spec.rb` |
| `em execução` | `commands/resume_task.rb` | `commands/resume_task_spec.rb` |
| `insolúvel` | `context/builder.rb` | `context/builder_spec.rb` |
| `já existe` | `skill_store.rb`, `tool_store.rb`, `plugin/loader.rb` | `skill_store_spec.rb`, `tool_store_spec.rb` |
| `já resolvida` | `pending_action_store.rb` | `pending_action_store_spec.rb` |
| `não é JSON` | `tools/data_defined_tool.rb`, `mcp_http_client.rb` | `data_defined_tool_spec.rb`, `mcp_http_client_spec.rb` |
| `não encontrada` / `não encontrado` | `tools/load_skill.rb`, `tools/data_defined_tool.rb` | `load_skill_spec.rb`, `data_defined_tool_spec.rb` |
| `obrigatório` + `ausente` (required param) | `tools/data_defined_tool.rb` | `data_defined_tool_spec.rb` |
| `obrigatória ausente:` / `não permitidas:` | `tool_manifest.rb` / `plugin/loader.rb` | `plugin/loader_spec.rb`, `trigger_workflow_flow_spec.rb` |
| `tool de código` | `commands/*` (data-tool validation) | `data_tool_commands_spec.rb`, `import_tools_spec.rb` |
| `type inválido` | `tool_definition.rb` | `tool_definition_spec.rb` |
| `url é obrigatória` | `tool_definition.rb`, data-tool commands | `tool_definition_spec.rb`, `data_tool_commands_spec.rb` |
| `não suportada` | `tool_definition.rb` | `tool_definition_spec.rb` |
| `http não permitido` | `egress_guard.rb` | `egress_guard_spec.rb` |
| `skill '...' não disponível para este agente` | `tools/load_skill.rb` | `tools/load_skill_spec.rb` |

Additional spec-asserted messages kept in Portuguese (discovered during the
batch, same reason — verbatim/regex asserts in `spec/`):
`tool_definition.rb` (`name deve casar`, `param '...' duplicado`,
`parameters (topo) deve ser type object`, `required cita propriedade
inexistente`, `array exige 'items'`, `param de topo ... deve casar`,
`extract 'json_path' exige path`, `contexto de turno desconhecido`),
`tool_manifest.rb` (`... nunca literal — R3`, `... vazaria sem masking`),
`commands/set_skill_agents.rb` (`agent_ids deve ser lista`),
`commands/update_settings.rb` (`patch vazio`),
`commands/trigger_workflow.rb` (`chaves desconhecidas no payload`),
`tools/data_defined_tool.rb` (`destino bloqueado:` prefix, `resposta não é
JSON`, `caminho '...' não encontrado`, `parâmetro(s) obrigatório(s)
ausente(s)`), `tool_trace_store.rb` (`…(truncado)` suffix),
`tool_store.rb` (`tool '...' já existe` / `não encontrada`),
`egress_guard.rb` (`esquema não suportado`, `host ausente`, `destino em rede
privada bloqueado`), `mcp_tool_ingestor.rb` (`instância MCP ... desabilitada`,
`... sem url ... stdio`, `... não encontrada`), `plugin/loader.rb`
(`plugin.yml está deprecado`, `config inválida`, `falha ao carregar`, the
`register_*` warns, `keyword(s) não suportada(s)`, `chave obrigatória
ausente:`, `chaves não permitidas:`), `llm_configurator.rb` (`sem api_key`),
`registry.rb` (`já registrada`, `não registrada`), `policy/engine.rb`
(`policy não registrada`), `agent_file_store.rb` / `system_file_store.rb` /
`skill_store.rb` (`já existe`, `não encontrado/a`, `versão ... inexistente`),
`pending_action_store.rb` (`já resolvida`), `commands/resume_task.rb`
(`em execução`, `irrecuperável`, `não encontrada`),
`commands/create_agent.rb` (`agente '...' já existe`),
`commands/import_tools.rb` + `commands/write_data_tool.rb` (`... já é uma tool
de código`), several `commands/*` `não encontrado/a` NotFoundError messages.

Note: `subscription overflow` (event_stream) and `rejected by operator`
(tool_envelope) were already in English and are asserted as such — kept.

## Deferred: model-facing prompt / description strings

These are Portuguese strings the **LLM** reads (tool/param descriptions,
`format_for_prompt` bodies, one normal-path tool result). They are neither
comments nor developer-facing errors, so they fall outside this pass's scope;
translating them changes prompt/model-facing content and deserves its own
review. Left in Portuguese:
- `tools/a2a_remote.rb` — `param :message, desc:`
- `tools/load_skill.rb` — `description` + `param :name, desc:`
- `tools/remember.rb` — `description` + `param :value`/`:key` descs
- `tools/tool_search.rb` — `description` + `param :query, desc:` + the
  `{ matched: [], message: "nenhuma ferramenta encontrada para ..." }` result
- `tool_catalog.rb` — `format_for_prompt` heredoc (`"Antes de usar uma tool
  acima, chame tool_search..."`)
- `skill_catalog.rb` — `format_for_prompt` heredoc (`"Antes de agir numa
  tarefa que casa com uma skill acima, chame a tool `load_skill`..."`)
- `mcp_tool_ingestor.rb` — default tool description fragment `"... do servidor
  MCP ..."` (partially translated; verify)

## Second pass (FOLLOWUP §5.1) — done

Scope of this pass: comments, docstrings and non-contract log/error/exception
messages plus operator-facing UI copy in the composition-root and transport
layers. Full suite stays green (1362 examples, 0 failures).

### `server/**` (Rack/SSE transport + A2A + admin) — done
- `server/app.rb`, `server/boot.rb`, `server/responses.rb`, `server/sse_body.rb`,
  `server/admin_auth.rb`, `server/admin/app.rb`.
- `server/a2a/*.rb` (app, client, errors, http, message, protocol, remotes,
  task_projection, agent_card).
- Coupled spec edits (a translated message asserted verbatim, updated together
  with its source):
  - `server/a2a/client.rb` `não concluiu` -> `did not complete`; spec
    `spec/harness/server/a2a/client_spec.rb` regex `/não concluiu/` ->
    `/did not complete/`.
  - `server/a2a/remotes.rb` warn `malformado` -> `malformed`; spec
    `spec/harness/server/a2a/remotes_spec.rb` `output(/malformado/)` ->
    `/malformed/`.
- Admin nav label `"índice"` -> `"index"` (lone PT label among otherwise-English
  nav labels; only asserted-by-href in specs, safe).
- `admin disabled` / `gateway disabled` were already English and asserted as
  such — kept.

### Composition-root scripts — done
- `scripts/import_pack.rb`, `scripts/run_real.rb`, `scripts/serve_real.rb`,
  `scripts/openclaw_to_pack.rb`, `scripts/openclaw_to_manifest.rb` — comments,
  usage/abort/warn strings and console banners. No spec asserts these.
- (`scripts/loadtest.rb`, `loadtest-local.sh`, `bench_store.rb`, `README.md`
  were already English — untouched.)

### `config/**`, `config.ru`, `Gemfile` — done
- `config/deployment.rb`, `config/wiring.rb`, `config.ru`, `Gemfile` — comments
  and the one `[deploy]` boot warn.

### `studio/app.rb` — done
- Remaining Ruby comments + all operator-facing `with_flash(...)` confirmation
  strings (agent/skill/tool/provider/MCP/system-file CRUD). No spec asserts
  these. ERB views/UI copy were migrated in an earlier refresh.

## Deferred in this pass

- `config/wiring.rb:175` — the A2A remote-tool fallback **description**
  (`"Delega a tarefa ao agente A2A remoto '...'."`) is model-facing (the LLM
  reads it), matching the 1st-pass deferral of `tools/a2a_remote.rb` and other
  model-facing prompt/description strings. Left in Portuguese.
- `scripts/run_real.rb` — the demo conversation content (sample customer
  messages to the PT-speaking `bia` agent) is input DATA, not comments/logs.
  Left in Portuguese. `vars` values like `"canal" => "studio"/"navegador"` are
  data and left as-is.

## Third pass (FOLLOWUP §5.1) — done

Scope of this pass: the two remaining buckets — **`spec/**` developer-facing prose**
(comments + `describe`/`context`/`it` descriptions) and the **model-facing
prompt/description strings** deferred by passes 1–2. Full suite stays green on both
Rubies (1362 examples, 0 failures on 3.3.5 and 4.0.6).

### `spec/**` — done
- All `describe`/`context`/`it` labels and inline comments across the suite
  translated to English. `lib/**` is now **0 Portuguese** (verified by grep).
- Coupled edits (a translated value asserted verbatim — source + assert changed
  together, caught by running the suite):
  - `tool_catalog_spec.rb`: `FakeTool` descriptions + the `search(...)` term that
    matched them (`"destinatário"`/`"fatura"` → English words present in the new
    descriptions); the `entries.first.description` exact-match assert.
  - `tools/tool_search_spec.rb` + `context/providers/tool_search_spec.rb`: tool
    descriptions + the `execute(query: ...)` terms that must still match them.
  - `frontmatter_spec.rb` + `commands/skill_authoring_spec.rb`: the `: `-in-prose
    regression fixtures — translated the description input **and** the
    `include(...)` substring assert together (kept a literal `: ` in the prose so
    the test still exercises the tolerant parser).
  - `e2e/smoke_phase2b_spec.rb`: the `query` value that is echoed and asserted.
  - Internal test-tool names renamed consistently within a file
    (`enviar_pedido` → `send_order`, `enviar` → `send`).

### Model-facing prompt/description strings — done
The strings deferred in passes 1–2 (the LLM reads them) are now English:
`tools/a2a_remote.rb` (`param :message` desc), `tools/load_skill.rb`,
`tools/remember.rb`, `tools/tool_search.rb` (descriptions + param descs + the
"no tool found" result), `tool_catalog.rb` / `skill_catalog.rb`
`format_for_prompt` heredocs, and `config/wiring.rb:175` (A2A fallback
description). The earlier contract-locked error messages were also translated
together with their asserts (suite green confirms the pairs are consistent).

## Deliberately left in Portuguese (domain fixture DATA)

Consistent with the 1st/2nd-pass deferral of `run_real.rb` demo content and `vars`
values, these are **test input data, not developer-facing prose**, so they stay in
Portuguese (translating a pervasive cross-file fixture identifier adds risk —
including lexicographic-order asserts — for zero reader value):
- The domain skill-name fixtures **`"pedido"`** (order) and **`"cardapio"`** (menu)
  used across ~9 specs, and the body/description/conversation content around them
  (`"faz pedido"`, `"faz o pedido"`, `"pedido confirmado"`, `"seed do disco"`,
  `"editado no studio"`, …).
- `spec/fixtures/openclaw_tools/*.ts` — sample OpenClaw merchant tools (fixture
  data mirroring real packs).
- `scripts/run_real.rb` demo conversation + `vars` (as before).

Easy to revisit if we later want fully-English fixtures; flagged here so the
decision is explicit and overridable.

## Remaining (not yet started)

- ERB views not covered by the UI refresh (if any) and `studio/**` non-Ruby
  assets (JS/CSS) — out of scope for the Ruby-comment passes.
- `Gemfile.lock` (generated; no human prose to translate).

## Follow-up: identifiers requiring contract coordination

Left untouched in this pass (renaming breaks wire/contract and many specs):
class/method names, SSE event type names, JSON payload keys, `status` symbol
values, OTEL span attribute names, tool/capability names.
