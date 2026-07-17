# frozen_string_literal: true

# PRODUCTION rackup (served by Falcon). Assembles the deployment's FULL app
# (Deploy::Wiring — DeepSeek/Bia/gateway_token/provisioner/egress/OTEL) with the
# Harness Studio under /studio.
#
# Unlike scripts/serve_real.rb (dev), it does NOT use the LocalAdminShim: /admin
# requires the REAL Bearer (ADMIN_TOKEN) — fail-closed. /v1/responses and /v1/agents
# use the gateway_token (OPENCLAW_GATEWAY_TOKEN, falls back to ADMIN_TOKEN).
#
# Run:
#   bundle exec falcon serve --bind http://0.0.0.0:$PORT --count $WEB_CONCURRENCY
#
# Requires DEEPSEEK_API_KEY (the deployment fails fast without the key). The durable
# SQLite volume goes in HARNESS_DB (see Dockerfile/docs/DEPLOY.md).
#
# FOLLOW-UP: auto-recovery of turns interrupted at restart (Server::Boot)
# only exists in the minimal wiring; here (as in serve_real) state is durable in
# SQLite but IN-FLIGHT turns at shutdown are not resumed automatically.

require_relative "config/deployment"
require "rack/urlmap"
require_relative "server/app"
require_relative "server/a2a/app" # inbound federation (opt-in)
require_relative "studio/app"     # management UI (Roda), under /studio

W = Deploy::Wiring

# /admin control Commands (the base deployment registers only the turn
# essentials; pause/approve enter here, as in serve_real).
W::BUS.register(:pause_task, Harness::Commands::PauseTask.new(task_store: W::TASK_STORE, executor: W::EXECUTOR))
W::BUS.register(:approve_action, Harness::Commands::ApproveAction.new(
                  pending_action_store: W::PENDING_ACTION_STORE, executor: W::EXECUTOR, event_stream: W::EVENT_STREAM
                ))

# fail-closed: without ADMIN_TOKEN, /admin and /studio deny. The gateway falls back to
# ADMIN_TOKEN when OPENCLAW_GATEWAY_TOKEN is not set (serve_real parity).
ADMIN_TOKEN     = ENV["ADMIN_TOKEN"].to_s
GATEWAY_TOKEN   = ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN)
ALLOWED_ORIGINS = ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)

# Inbound A2A OPT-IN via HARNESS_A2A_AGENT (gated by the dynamic ProfileSource).
A2A_APP =
  if (a2a_agent = ENV["HARNESS_A2A_AGENT"]) && W::PROFILE_SOURCE.fetch(a2a_agent)
    Harness::Server::A2A::App.new(
      command_bus: W::BUS, task_store: W::TASK_STORE, session_store: W::SESSION_STORE,
      profiles: W::PROFILE_SOURCE, skill_catalog: W::CATALOG,
      config: { a2a_agent: a2a_agent, base_url: ENV["HARNESS_PUBLIC_URL"] || "http://localhost:9292" }
    )
  end

APP = Harness::Server::App.new(
  command_bus: W::BUS, event_stream: W::EVENT_STREAM,
  session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  checkpoint_store: W::CHECKPOINT_STORE, pending_action_store: W::PENDING_ACTION_STORE,
  catalogs: { skills: W::CATALOG, prompts: W::PROMPT_CATALOG },
  registries: { tools: W::TOOL_REGISTRY, workflows: W::WORKFLOW_REGISTRY, policies: W::POLICY_REGISTRY },
  a2a: A2A_APP, # nil without opt-in -> A2A routes respond 404
  provisioner: W::PACK_IMPORTER, # POST/DELETE /v1/agents under the gateway_token
  config: { admin_token: ADMIN_TOKEN, allowed_origins: ALLOWED_ORIGINS, gateway_token: GATEWAY_TOKEN }
)

PERSISTENCE = ENV["HARNESS_DB"].to_s.empty? ? "ephemeral (memory)" : "durable (sqlite)"
Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE,
  tool_trace_store: W::TOOL_TRACE_STORE # tool-call trace in the session viewer
)

# Serving mode: turns are born as children of a long-lived supervisor (created lazily
# on the worker's reactor at the 1st turn) and survive the client disconnect.
W::EXECUTOR.supervised = true

# OTEL Telemetry (opt-in). Only when enabled (HARNESS_OTEL); off -> nil -> no-op.
Harness::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY) if W::TELEMETRY

# /studio -> Studio (Roda, cookie-auth); rest -> Server::App (/admin with real Bearer).
run Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => APP
)
