# frozen_string_literal: true

# SERVE FOR REAL: boots the real HTTP server (single-process, like the E2E
# smoke) serving /studio and /v1/* against Bia's deployment (DeepSeek). Open
# http://localhost:9292/studio in the browser and chat — each message
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
require File.join(Dir.pwd, "server", "boot")
require File.join(Dir.pwd, "server", "a2a", "app") # inbound federation (opt-in)
require_relative "../studio/app" # management UI (Roda), under /studio

W = Deploy::Wiring

# Fixed token for the LOCAL demo: logs into the Studio (cookie-auth) and, as the
# fallback, gates /v1/responses + /v1/agents (gateway_token). Never a real secret.
ADMIN_TOKEN = ENV.fetch("ADMIN_TOKEN", "local-demo")

# pause_task/approve_action come from the shared graph core (Insika::Wiring::Graph,
# §12 G4) — no longer patched in here.

# Session ready for multi-turn in the browser: pick session_id "web" (agent "bia")
# in the Studio chat so Bia REMEMBERS the previous turns.
W::SESSION_STORE.create(id: "web", vars: { "canal" => "navegador" }) unless W::SESSION_STORE.find("web")

# Inbound A2A (§9.6): OPT-IN via INSIKA_A2A_AGENT, gated by PROFILE_SOURCE —
# reads the SAME dynamic ProfileSource as the deployment, so the AgentCard/inbound
# see agents created in the Studio (no longer a static PROFILES). Without the env /
# a missing agent -> nil -> Server::App does not expose the A2A routes.
A2A_APP =
  if (a2a_agent = ENV["INSIKA_A2A_AGENT"]) && W::PROFILE_SOURCE.fetch(a2a_agent)
    Insika::Server::A2A::App.new(
      command_bus: W::BUS, task_store: W::TASK_STORE, session_store: W::SESSION_STORE,
      profiles: W::PROFILE_SOURCE, skill_catalog: W::CATALOG,
      config: { a2a_agent: a2a_agent,
                base_url: ENV["INSIKA_PUBLIC_URL"] || ENV.fetch("BIND", "http://localhost:9292") }
    )
  end

APP = Insika::Server::App.new(
  command_bus: W::BUS, event_stream: W::EVENT_STREAM,
  session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  pending_action_store: W::PENDING_ACTION_STORE,
  a2a: A2A_APP, # nil without opt-in -> A2A routes respond 404
  # provisioner: pack importer (Phase 6/D4) under the SAME Bearer as
  # /v1/responses — the GatewayClient provisions stores at runtime via POST/DELETE
  # /v1/agents. Always exposed in serve real (the gateway needs it).
  provisioner: W::PACK_IMPORTER,
  profiles: W::PROFILE_SOURCE, # GET /v1/agents/:id — read-only capability view (evals)
  # Onboarding surface (item 20 / §5.6): start.md + models.json + docs. Always on in
  # the full local demo — it's the "build my first agent" front door. Reports the
  # platform models AND the demo's served agents (their ids ARE the /v1/responses
  # `model`), all from masked/read-only sources.
  onboarding: Insika::Onboarding.standard(
    root: File.expand_path("..", __dir__),
    settings_store: W::SETTINGS_STORE, provider_store: W::LLM_PROVIDER_STORE,
    agents: -> { W::PROFILE_SOURCE.all.map { |p| { id: p.id, model: p.model, provider: p.provider } } }
  ),
  # gateway_token: Bearer for /v1/responses + /v1/agents (drop-in for the OpenClaw
  # gateway). The consumer sends OPENCLAW_GATEWAY_TOKEN; in the demo it falls back to ADMIN_TOKEN.
  config: { gateway_token: ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN),
            public_url: ENV["INSIKA_PUBLIC_URL"] }
)

# Insika Studio: Roda app mounted under /studio, with cookie login — the
# browser sends the session cookie (no Bearer needed). The session secret derives
# from ADMIN_TOKEN. Log in at /studio/login with the ADMIN_TOKEN below.
# persistence hint for the health chip (durable in SQLite when
# INSIKA_DB is set; ephemeral in memory otherwise).
PERSISTENCE = (ENV["INSIKA_DB"].to_s.empty? ? "ephemeral (memory)" : "durable (sqlite)")

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
  pending_action_store: W::PENDING_ACTION_STORE,
  # RFC-0013 phase A: the Refinement page reads the runs; the button dispatches
  # :run_refinement on the bus (the Studio never writes a store directly).
  refinement_store: W::REFINEMENT_STORE,
  # eval cases: the rubric is authored here (writes go through :write_golden).
  golden_store: W::GOLDEN_STORE
)

# URLMap routes /studio -> Studio (Roda, cookie-auth) and the rest -> Server::App
# (transport: /v1, /a2a). One process, one endpoint.
DISPATCH = Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => APP
)

# RFC-0016 A2: recovery BEFORE the listen, same as config.ru. Runs while the
# executor is still non-supervised (sequential replay inside Boot's Sync).
BOOTED_APP = Insika::Server::Boot.new(W, app: DISPATCH).call

BIND = ENV.fetch("BIND", "http://localhost:9292")
endpoint = Async::HTTP::Endpoint.parse(BIND)
middleware = Protocol::Rack::Adapter.new(BOOTED_APP)

puts "\e[1mInsika — serving for real (Bia · DeepSeek #{Deploy::MODEL})\e[0m"
puts "  #{BIND}/studio        → Insika Studio (login: token \"#{ADMIN_TOKEN}\")"
puts "  #{BIND}/studio/chats  → chat with Bia (agent: bia · session_id: web)"
puts "  #{BIND}/studio/tasks  → tasks / approvals console"
puts "  Ctrl-C to stop (drains in-flight turns; press twice to skip the wait)."

puts "  OTEL          → #{W::TELEMETRY ? "on (#{Insika::Telemetry.metrics? ? "traces + metrics" : "traces"} to OTLP)" : "off (INSIKA_OTEL to enable)"}"

# RFC-0016 A3: first Ctrl-C/SIGTERM closes the intake and drains in-flight turns
# (INSIKA_DRAIN_TIMEOUT, default 20s) before the reactor comes down; a second
# signal skips the wait.
Insika::Shutdown.install(executor: W::EXECUTOR)

Async do
  W::EXECUTOR.supervised = true # serving mode: turns survive the disconnect
  # OTEL Telemetry (opt-in): connects the Recorder to the Event Stream INSIDE the reactor.
  # No-op when TELEMETRY is nil (off).
  Insika::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY)
  Async::HTTP::Server.new(middleware, endpoint).run
end
