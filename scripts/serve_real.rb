# frozen_string_literal: true

# SERVIR DE VERDADE: sobe o servidor HTTP real (single-process, como o smoke
# E2E) servindo /admin e /v1/* contra o deployment da Bia (DeepSeek). Abra
# http://localhost:9292/admin/chat no navegador e converse — cada mensagem
# dispara o MESMO send_message da API, com tools/skills/memória reais.
#
# Single-process (Async::HTTP::Server, não `falcon serve`): kill -9 mata tudo e
# libera a porta (o pai do falcon não mata os workers). supervised = true DEPOIS
# do wiring: os turnos nascem filhos de um supervisor de vida-longa e sobrevivem
# ao disconnect da request — é o que faz a sessão multi-turn funcionar.
#
# Uso: DEEPSEEK_API_KEY=... ruby scripts/serve_real.rb   (BIND opcional)

$stdout.sync = true
require_relative "../config/deployment"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require "rack/urlmap"
require File.join(Dir.pwd, "server", "app")
require File.join(Dir.pwd, "server", "a2a", "app") # federação inbound (opt-in)
require_relative "../studio/app" # UI de gestão (Roda), sob /studio

W = Deploy::Wiring

# O /admin é fail-closed (503 sem token) e o navegador não manda Authorization
# ao navegar. Para o demo LOCAL, um token fixo + um shim que injeta o Bearer nas
# rotas /admin — deixa o /admin aberto SÓ neste processo local (bind localhost).
# O core de auth (AdminAuth) fica intacto; isto é conveniência do script de demo.
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

# Completa o BUS com os Commands de controle do /admin (pause/approve) — o
# deployment base registra só o essencial de turno.
W::BUS.register(:pause_task, Harness::Commands::PauseTask.new(task_store: W::TASK_STORE, executor: W::EXECUTOR))
W::BUS.register(:approve_action, Harness::Commands::ApproveAction.new(
                  pending_action_store: W::PENDING_ACTION_STORE, executor: W::EXECUTOR, event_stream: W::EVENT_STREAM
                ))

# Sessão pronta p/ multi-turn no navegador: digite session_id "web" no /admin/chat
# (e agente "bia") para a Bia LEMBRAR dos turnos anteriores.
W::SESSION_STORE.create(id: "web", vars: { "canal" => "navegador" }) unless W::SESSION_STORE.find("web")

# A2A inbound (§9.6): OPT-IN por HARNESS_A2A_AGENT, gateado pelo PROFILE_SOURCE —
# lê o MESMO ProfileSource dinâmico do deployment, então o AgentCard/inbound
# enxergam agentes criados no Studio (não mais um PROFILES estático). Sem a env /
# agente inexistente -> nil -> Server::App não expõe as rotas A2A.
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
  # tools = overlay (código + por-dados), então /admin lista as data-tools também.
  registries: { tools: W::TOOL_REGISTRY, workflows: W::WORKFLOW_REGISTRY, policies: W::POLICY_REGISTRY },
  a2a: A2A_APP, # nil sem opt-in -> rotas A2A respondem 404
  # provisioner: importador de pack (Fase 6/D4) sob o MESMO Bearer do
  # /v1/responses — o GatewayClient provisiona lojas em runtime via POST/DELETE
  # /v1/agents. Sempre exposto no serve real (o gateway precisa dele).
  provisioner: W::PACK_IMPORTER,
  # gateway_token: Bearer do /v1/responses + /v1/agents (drop-in do gateway
  # OpenClaw). O consumidor manda OPENCLAW_GATEWAY_TOKEN; no demo cai no ADMIN_TOKEN.
  config: { admin_token: ADMIN_TOKEN, allowed_origins: [],
            gateway_token: ENV.fetch("OPENCLAW_GATEWAY_TOKEN", ADMIN_TOKEN) }
)

# Harness Studio: app Roda montado sob /studio, com login por
# cookie — o navegador manda o cookie de sessão, então NÃO precisa do shim
# de Bearer que o /admin usa. O secret de sessão deriva do ADMIN_TOKEN. Login em
# /studio/login com o ADMIN_TOKEN abaixo.
# dica de persistência para o health chip (durável em SQLite quando
# HARNESS_DB está setado; efêmero em memória caso contrário).
PERSISTENCE = (ENV["HARNESS_DB"].to_s.empty? ? "efêmero (memória)" : "durável (sqlite)")

Studio::App.configure(
  command_bus: W::BUS, profile_source: W::PROFILE_SOURCE,
  event_stream: W::EVENT_STREAM, config: { admin_token: ADMIN_TOKEN, persistence: PERSISTENCE },
  # stores de LEITURA para as páginas de autoria (agents-detail/skills/
  # tools/histórico). Escrita continua só pelos Commands do BUS.
  agent_file_store: W::AGENT_FILE_STORE, skill_store: W::SKILL_STORE,
  skill_catalog: W::CATALOG, tool_catalog: W::TOOL_CATALOG, tool_store: W::TOOL_STORE,
  memory_store: W::MEMORY_STORE, session_store: W::SESSION_STORE,
  # settings/LLM/MCP + arquivos de sistema globais.
  settings_store: W::SETTINGS_STORE, llm_provider_store: W::LLM_PROVIDER_STORE,
  mcp_store: W::MCP_STORE, system_file_store: W::SYSTEM_FILE_STORE
)

# URLMap roteia /studio -> Studio (Roda, cookie-auth) e o resto -> Server::App
# (com o shim de Bearer só nas rotas /admin). Um processo, um endpoint.
DISPATCH = Rack::URLMap.new(
  "/studio" => Studio::App,
  "/" => LocalAdminShim.new(APP, ADMIN_TOKEN)
)

BIND = ENV.fetch("BIND", "http://localhost:9292")
endpoint = Async::HTTP::Endpoint.parse(BIND)
middleware = Protocol::Rack::Adapter.new(DISPATCH)

puts "\e[1mHarness — servindo de verdade (Bia · DeepSeek #{Deploy::MODEL})\e[0m"
puts "  #{BIND}/studio       → Harness Studio (login: token \"#{ADMIN_TOKEN}\")"
puts "  #{BIND}/admin/chat   → converse com a Bia (agente: bia · session_id: web)"
puts "  #{BIND}/admin/events → tool-cards ao vivo (filtre por session_id: web)"
puts "  #{BIND}/admin        → console"
puts "  Ctrl-C para parar."

puts "  OTEL          → #{W::TELEMETRY ? "ligado (spans no OTLP)" : "desligado (HARNESS_OTEL p/ ligar)"}"

Async do
  W::EXECUTOR.supervised = true # modo serving: turnos sobrevivem ao disconnect
  # Telemetry OTEL (opt-in): liga o Recorder ao Event Stream DENTRO do reactor.
  # No-op quando TELEMETRY nil (desligado).
  Harness::Telemetry.attach(event_stream: W::EVENT_STREAM, recorder: W::TELEMETRY)
  Async::HTTP::Server.new(middleware, endpoint).run
end
