# frozen_string_literal: true

# PRODUCTION rackup (served by Falcon). Assembles the deployment's FULL app
# (Deploy::Wiring — DeepSeek/Bia/gateway_token/provisioner/egress/OTEL) with the
# Insika Studio under /studio.
#
# The operator control UI lives in the Studio (cookie-auth, under /studio). The
# server surface is transport-only: /v1/responses and /v1/agents use the
# gateway_token (OPENCLAW_GATEWAY_TOKEN, falls back to ADMIN_TOKEN).
#
# Run:
#   bundle exec falcon serve --bind http://0.0.0.0:$PORT --count $WEB_CONCURRENCY
#
# Requires DEEPSEEK_API_KEY (the deployment fails fast without the key). The durable
# SQLite volume goes in INSIKA_DB (see Dockerfile/docs/DEPLOY.md).
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

# pause_task/approve_action come from the shared graph core (Insika::Wiring::Graph,
# §12 G4) — no longer patched in here.

# fail-closed: without ADMIN_TOKEN, /studio denies login. The gateway falls back to
# ADMIN_TOKEN when OPENCLAW_GATEWAY_TOKEN is not set (serve_real parity).
ADMIN_TOKEN   = ENV["ADMIN_TOKEN"].to_s
GATEWAY_TOKEN = ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN)

# Inbound A2A OPT-IN via INSIKA_A2A_AGENT (gated by the dynamic ProfileSource).
A2A_APP =
  if (a2a_agent = ENV["INSIKA_A2A_AGENT"]) && W::PROFILE_SOURCE.fetch(a2a_agent)
    Insika::Server::A2A::App.new(
      command_bus: W::BUS, task_store: W::TASK_STORE, session_store: W::SESSION_STORE,
      profiles: W::PROFILE_SOURCE, skill_catalog: W::CATALOG,
      config: { a2a_agent: a2a_agent, base_url: ENV["INSIKA_PUBLIC_URL"] || "http://localhost:9292" }
    )
  end

# Onboarding surface (item 20 / §5.6) — OPT-IN in production via INSIKA_ONBOARDING.
# Off by default: this deployment serves a private tenant, and start.md/docs/models
# are OSS DX aimed at self-hosters. When enabled it reports the platform models
# (masked — slugs + model ids only, no keys/urls), NOT the tenant's agent ids.
ONBOARDING =
  if Insika::EnvSchema.truthy?(ENV["INSIKA_ONBOARDING"])
    Insika::Onboarding.standard(root: __dir__, settings_store: W::SETTINGS_STORE,
                                 provider_store: W::LLM_PROVIDER_STORE)
  end

APP = Insika::Server::App.new(
  command_bus: W::BUS, event_stream: W::EVENT_STREAM,
  session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  pending_action_store: W::PENDING_ACTION_STORE, # read for GET /v1/tasks/:id
  a2a: A2A_APP, # nil without opt-in -> A2A routes respond 404
  provisioner: W::PACK_IMPORTER, # POST/DELETE /v1/agents under the gateway_token
  onboarding: ONBOARDING, # nil unless INSIKA_ONBOARDING -> onboarding routes 404
  config: { gateway_token: GATEWAY_TOKEN, public_url: ENV["INSIKA_PUBLIC_URL"] }
)

PERSISTENCE = ENV["INSIKA_DB"].to_s.empty? ? "ephemeral (memory)" : "durable (sqlite)"
Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE,
  tool_trace_store: W::TOOL_TRACE_STORE, # tool-call trace in the session viewer
  # §12 G5: tasks/approvals pages (controls dispatch pause/resume/cancel/approve).
  task_store: W::TASK_STORE, checkpoint_store: W::CHECKPOINT_STORE,
  pending_action_store: W::PENDING_ACTION_STORE,
  # RFC-0013 phase A: the Refinement page reads the runs; the button dispatches
  # :run_refinement on the bus (the Studio never writes a store directly).
  refinement_store: W::REFINEMENT_STORE
)

# Serving mode: turns are born as children of a long-lived supervisor (created lazily
# on the worker's reactor at the 1st turn) and survive the client disconnect.
W::EXECUTOR.supervised = true

# OTEL Telemetry (opt-in). Only when enabled (INSIKA_OTEL); off -> nil -> no-op.
Insika::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY) if W::TELEMETRY

# /studio -> Studio (Roda, cookie-auth); rest -> Server::App (transport: /v1, /a2a).
run Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => APP
)
