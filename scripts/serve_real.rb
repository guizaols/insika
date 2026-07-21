# frozen_string_literal: true

# SERVE FOR REAL: boots the real HTTP server (single-process, like the E2E
# smoke) serving /admin and /v1/* against Bia's deployment (DeepSeek). Open
# http://localhost:9292/admin/chat in the browser and chat — each message
# fires the SAME send_message as the API, with real tools/skills/memory.
#
# Single-process (Async::HTTP::Server, not `falcon serve`): kill -9 kills everything and
# frees the port (falcon's parent doesn't kill the workers). supervised = true AFTER
# the wiring: turns are born as children of a long-lived supervisor and survive
# the request disconnect — that's what makes the multi-turn session work.
#
# Usage: DEEPSEEK_API_KEY=... ruby scripts/serve_real.rb   (BIND optional)

$stdout.sync = true
require_relative "../config/deployment"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require "rack/urlmap"
require File.join(Dir.pwd, "server", "app")
require File.join(Dir.pwd, "server", "a2a", "app") # inbound federation (opt-in)
require_relative "../studio/app" # management UI (Roda), under /studio

W = Deploy::Wiring

# /admin is fail-closed (503 without a token) and the browser doesn't send Authorization
# when navigating. For the LOCAL demo, a fixed token + a shim that injects the Bearer on the
# /admin routes — leaves /admin open ONLY in this local process (localhost bind).
# The auth core (AdminAuth) stays intact; this is a convenience of the demo script.
ADMIN_TOKEN = ENV.fetch("ADMIN_TOKEN", "local-demo")

class LocalAdminShim
  def initialize(app, token) = (@app = app; @token = token)

  def call(env)
    if env["PATH_INFO"].to_s.start_with?("/admin")
      env["HTTP_AUTHORIZATION"] ||= "Bearer #{@token}"
    end
    @app.call(env)
  end
end

# pause_task/approve_action come from the shared graph core (Harness::Wiring::Graph,
# §12 G4) — no longer patched in here.

# Session ready for multi-turn in the browser: type session_id "web" in /admin/chat
# (and agent "bia") so Bia REMEMBERS the previous turns.
W::SESSION_STORE.create(id: "web", vars: { "canal" => "navegador" }) unless W::SESSION_STORE.find("web")

# Inbound A2A (§9.6): OPT-IN via HARNESS_A2A_AGENT, gated by PROFILE_SOURCE —
# reads the SAME dynamic ProfileSource as the deployment, so the AgentCard/inbound
# see agents created in the Studio (no longer a static PROFILES). Without the env /
# a missing agent -> nil -> Server::App does not expose the A2A routes.
A2A_APP =
  if (a2a_agent = ENV["HARNESS_A2A_AGENT"]) && W::PROFILE_SOURCE.fetch(a2a_agent)
    Harness::Server::A2A::App.new(
      command_bus: W::BUS, task_store: W::TASK_STORE, session_store: W::SESSION_STORE,
      profiles: W::PROFILE_SOURCE, skill_catalog: W::CATALOG,
      config: { a2a_agent: a2a_agent,
                base_url: ENV["HARNESS_PUBLIC_URL"] || ENV.fetch("BIND", "http://localhost:9292") }
    )
  end

APP = Harness::Server::App.new(
  command_bus: W::BUS, event_stream: W::EVENT_STREAM,
  session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  checkpoint_store: W::CHECKPOINT_STORE, pending_action_store: W::PENDING_ACTION_STORE,
  catalogs: { skills: W::CATALOG, prompts: W::PROMPT_CATALOG },
  # tools = overlay (code + data-defined), so /admin lists the data-tools too.
  registries: { tools: W::TOOL_REGISTRY, workflows: W::WORKFLOW_REGISTRY, policies: W::POLICY_REGISTRY },
  a2a: A2A_APP, # nil without opt-in -> A2A routes respond 404
  # provisioner: pack importer (Phase 6/D4) under the SAME Bearer as
  # /v1/responses — the GatewayClient provisions stores at runtime via POST/DELETE
  # /v1/agents. Always exposed in serve real (the gateway needs it).
  provisioner: W::PACK_IMPORTER,
  # gateway_token: Bearer for /v1/responses + /v1/agents (drop-in for the OpenClaw
  # gateway). The consumer sends OPENCLAW_GATEWAY_TOKEN; in the demo it falls back to ADMIN_TOKEN.
  config: { admin_token: ADMIN_TOKEN, allowed_origins: [],
            gateway_token: ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN) }
)

# Harness Studio: Roda app mounted under /studio, with cookie
# login — the browser sends the session cookie, so it does NOT need the Bearer
# shim that /admin uses. The session secret derives from ADMIN_TOKEN. Log in at
# /studio/login with the ADMIN_TOKEN below.
# persistence hint for the health chip (durable in SQLite when
# HARNESS_DB is set; ephemeral in memory otherwise).
PERSISTENCE = (ENV["HARNESS_DB"].to_s.empty? ? "ephemeral (memory)" : "durable (sqlite)")

Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  # READ stores for the authoring pages (agents-detail/skills/
  # tools/history). Writes still go only through the BUS Commands.
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  # settings/LLM/MCP + global system files.
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE,
  # §12 G5: tasks/approvals pages (controls dispatch pause/resume/cancel/approve).
  task_store: W::TASK_STORE, checkpoint_store: W::CHECKPOINT_STORE,
  pending_action_store: W::PENDING_ACTION_STORE
)

# URLMap routes /studio -> Studio (Roda, cookie-auth) and the rest -> Server::App
# (with the Bearer shim only on the /admin routes). One process, one endpoint.
DISPATCH = Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => LocalAdminShim.new(APP, ADMIN_TOKEN)
)

BIND = ENV.fetch("BIND", "http://localhost:9292")
endpoint = Async::HTTP::Endpoint.parse(BIND)
middleware = Protocol::Rack::Adapter.new(DISPATCH)

puts "\e[1mHarness — serving for real (Bia · DeepSeek #{Deploy::MODEL})\e[0m"
puts "  #{BIND}/studio       → Harness Studio (login: token \"#{ADMIN_TOKEN}\")"
puts "  #{BIND}/admin/chat   → chat with Bia (agent: bia · session_id: web)"
puts "  #{BIND}/admin/events → live tool-cards (filter by session_id: web)"
puts "  #{BIND}/admin        → console"
puts "  Ctrl-C to stop."

puts "  OTEL          → #{W::TELEMETRY ? "on (spans to OTLP)" : "off (HARNESS_OTEL to enable)"}"

Async do
  W::EXECUTOR.supervised = true # serving mode: turns survive the disconnect
  # OTEL Telemetry (opt-in): connects the Recorder to the Event Stream INSIDE the reactor.
  # No-op when TELEMETRY is nil (off).
  Harness::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY)
  Async::HTTP::Server.new(middleware, endpoint).run
end
