# frozen_string_literal: true

# Rackup de PRODUÇÃO (servido pelo Falcon). Monta o app COMPLETO do deployment
# (Deploy::Wiring — DeepSeek/Bia/gateway_token/provisioner/egress/OTEL) com o
# Harness Studio sob /studio.
#
# Diferente do scripts/serve_real.rb (dev), NÃO usa o LocalAdminShim: o /admin
# exige o Bearer REAL (ADMIN_TOKEN) — fail-closed. O /v1/responses e /v1/agents
# usam o gateway_token (OPENCLAW_GATEWAY_TOKEN, cai no ADMIN_TOKEN).
#
# Rode:
#   bundle exec falcon serve --bind http://0.0.0.0:$PORT --count $WEB_CONCURRENCY
#
# Requer DEEPSEEK_API_KEY (o deployment falha-rápido sem a chave). O volume
# durável do SQLite vai em HARNESS_DB (ver Dockerfile/docs/DEPLOY.md).
#
# FOLLOW-UP: o auto-recovery de turnos interrompidos no restart (Server::Boot)
# só existe na wiring mínima; aqui (como no serve_real) o estado é durável no
# SQLite mas turnos EM VOO no shutdown não são retomados automaticamente.

require_relative "config/deployment"
require "rack/urlmap"
require_relative "server/app"
require_relative "server/a2a/app" # federação inbound (opt-in)
require_relative "studio/app"     # UI de gestão (Roda), sob /studio

W = Deploy::Wiring

# Commands de controle do /admin (o deployment base registra só o essencial de
# turno; pause/approve entram aqui, como no serve_real).
W::BUS.register(:pause_task, Harness::Commands::PauseTask.new(task_store: W::TASK_STORE, executor: W::EXECUTOR))
W::BUS.register(:approve_action, Harness::Commands::ApproveAction.new(
                  pending_action_store: W::PENDING_ACTION_STORE, executor: W::EXECUTOR, event_stream: W::EVENT_STREAM
                ))

# fail-closed: sem ADMIN_TOKEN o /admin e o /studio negam. O gateway cai no
# ADMIN_TOKEN quando OPENCLAW_GATEWAY_TOKEN não é setado (paridade do serve_real).
ADMIN_TOKEN     = ENV["ADMIN_TOKEN"].to_s
GATEWAY_TOKEN   = ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN)
ALLOWED_ORIGINS = ENV.fetch("HARNESS_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)

# A2A inbound OPT-IN por HARNESS_A2A_AGENT (gateado pelo ProfileSource dinâmico).
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
  a2a: A2A_APP, # nil sem opt-in -> rotas A2A respondem 404
  provisioner: W::PACK_IMPORTER, # POST/DELETE /v1/agents sob o gateway_token
  config: { admin_token: ADMIN_TOKEN, allowed_origins: ALLOWED_ORIGINS, gateway_token: GATEWAY_TOKEN }
)

PERSISTENCE = ENV["HARNESS_DB"].to_s.empty? ? "efêmero (memória)" : "durável (sqlite)"
Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE
)

# Modo serving: turnos nascem filhos de um supervisor de vida-longa (criado lazy
# no reactor do worker no 1º turno) e sobrevivem ao disconnect do cliente.
W::EXECUTOR.supervised = true

# Telemetry OTEL (opt-in). Só quando ligado (HARNESS_OTEL); desligado -> nil -> no-op.
Harness::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY) if W::TELEMETRY

# /studio -> Studio (Roda, cookie-auth); resto -> Server::App (/admin com Bearer real).
run Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => APP
)
