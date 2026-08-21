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
# Recovery: each worker boots through Server::Boot, which sweeps
# orphaned turns, undelivered delegations and channel replies BEFORE the listen.
# The task sweep runs once per boot generation (INSIKA_BOOT_ID) — see
# docs/DEPLOY.md "The process model".

require_relative "config/deployment"
require "rack/urlmap"
require_relative "lib/insika/server/boot"
require_relative "lib/insika/server/app"
require_relative "lib/insika/server/a2a/app" # inbound federation (opt-in)
require_relative "lib/insika/studio/app"     # management UI (Roda), under /studio

W = Deploy::Wiring

# pause_task/approve_action come from the shared graph core (Insika::Wiring::Graph,
# — no longer patched in here.

# fail-closed: without ADMIN_TOKEN, /studio denies login. The gateway falls back to
# ADMIN_TOKEN when OPENCLAW_GATEWAY_TOKEN is not set (serve_real parity).
ADMIN_TOKEN   = ENV["ADMIN_TOKEN"].to_s
GATEWAY_TOKEN = ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN)

# WS1: "single_tenant" (default) keeps the gateway token as the only
# credential; "multi_tenant" resolves per-tenant + operator tokens from the
# store (INSIKA_TENANCY).
TENANCY       = ENV.fetch("INSIKA_TENANCY", "single_tenant")

# Inbound A2A OPT-IN via INSIKA_A2A_AGENT (gated by the dynamic ProfileSource).
A2A_APP =
  if (a2a_agent = ENV["INSIKA_A2A_AGENT"]) && W::PROFILE_SOURCE.fetch(a2a_agent)
    Insika::Server::A2A::App.new(
      command_bus: W::BUS, task_store: W::TASK_STORE, session_store: W::SESSION_STORE,
      profiles: W::PROFILE_SOURCE, skill_catalog: W::CATALOG,
      config: { a2a_agent: a2a_agent, base_url: ENV["INSIKA_PUBLIC_URL"] || "http://localhost:9292" }
    )
  end

# Onboarding surface — OPT-IN in production via INSIKA_ONBOARDING.
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
  profiles: W::PROFILE_SOURCE, # GET /v1/agents/:id — read-only capability view (evals)
  onboarding: ONBOARDING, # nil unless INSIKA_ONBOARDING -> onboarding routes 404
  channels: W::CHANNEL_REGISTRY, # /channels/:id/events (empty registry -> 404)
  config: { gateway_token: GATEWAY_TOKEN, public_url: ENV["INSIKA_PUBLIC_URL"],
            tenancy: TENANCY },
  # WS1: only multi_tenant hands the token store to the edge.
  token_store: (W::SPINE.token_store if TENANCY == "multi_tenant"),
  # GET /v1/vitals: in-flight count + SQLite bytes.
  executor: W::EXECUTOR, db_path: Insika::EnvSchema.read("INSIKA_DB")
)

PERSISTENCE = Insika::EnvSchema.read("INSIKA_DB").to_s.empty? ? "ephemeral (memory)" : "durable (sqlite)"
Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE,
  tool_trace_store: W::TOOL_TRACE_STORE, # tool-call trace in the session viewer
  context_trace_store: W::CONTEXT_TRACE_STORE, # context breakdown card
  cache_series_store: W::CACHE_SERIES_STORE, # per-agent cache-hit series
  # tasks/approvals pages (controls dispatch pause/resume/cancel/approve).
  task_store: W::TASK_STORE, checkpoint_store: W::CHECKPOINT_STORE,
  pending_action_store: W::PENDING_ACTION_STORE,
  # the Refinement page reads the runs; the button dispatches
  # :run_refinement on the bus (the Studio never writes a store directly).
  refinement_store: W::REFINEMENT_STORE,
  # eval cases: the rubric is authored here (writes go through :write_golden).
  golden_store: W::GOLDEN_STORE,
  # WS7: the scorecard card reads the outcomes store (state + series). The
  # outcome/funnel/follow-up stores are NOT promoted on Deploy::Wiring — they
  # read from the shared GRAPH (the same spine instances).
  outcome_store: W::GRAPH.outcome_store,
  # the outcome-funnel page reads the fold's cells and baselines.
  funnel_store: W::GRAPH.funnel_store,
  # the Follow-ups page reads the stores directly; its only
  # mutations (cancel, force-revoke) dispatch bus commands.
  followup_store: W::GRAPH.followup_store,
  contact_store: W::GRAPH.contact_store,
  # the Harvest page reads the harvest store + the two
  # pre-registered artifacts (criterion, negative list) directly; its
  # mutations dispatch :run_harvest / :gate_harvest / :promote_harvest /
  # :reject_harvest / :rollback_harvest on the bus.
  harvest_store: W::GRAPH.harvest_store,
  harvest_criterion: W::HARVEST_CRITERION,
  negative_list: W::HARVEST_NEGATIVE
)

# OTEL Telemetry (opt-in). Only when enabled (INSIKA_OTEL); off -> nil -> no-op.
# Attached BEFORE Boot so the turns recovery resumes are observed too.
Insika::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY) if W::TELEMETRY

# /studio -> Studio (Roda, cookie-auth); rest -> Server::App (transport: /v1, /a2a).
RACK_APP = Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => APP
)

# recovery BEFORE the listen, per worker. Boot's Sync only returns
# after the resumed turns finish, and Falcon only listens after `run`. Order
# matters: the executor is still non-supervised here, so recovery replays
# sequentially in Boot's transient reactor — `supervised = true` only after,
# so the long-lived turn supervisor binds to Falcon's serving reactor.
BOOTED_APP = Insika::Server::Boot.new(W, app: RACK_APP).call

# Serving mode: turns are born as children of a long-lived supervisor and survive
# the client disconnect. start_supervisor! forces it up now (Falcon already runs
# config.ru inside the worker's live reactor, confirmed empirically — the task
# below `supervised = true` is the same one requests later descend from) instead
# of waiting for the first served turn: a deployment whose only agents are
# scheduled (no live chat) would otherwise never tick until unrelated traffic
# happened to arrive first.
W::EXECUTOR.supervised = true
W::EXECUTOR.start_supervisor!

# shutdown is a drain, not a kill. This replaces async-container's
# SIGINT/SIGTERM trap in THIS worker (config.ru loads per worker): the intake
# closes, in-flight turns get up to INSIKA_DRAIN_TIMEOUT (default 20s), and only
# then the ordinary Falcon teardown proceeds. entrypoint.sh sizes Falcon's
# --graceful-stop above this deadline so the controller does not cut it short.
Insika::Shutdown.install(executor: W::EXECUTOR)

run BOOTED_APP
