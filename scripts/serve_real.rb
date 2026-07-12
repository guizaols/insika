# frozen_string_literal: true

# SERVIR DE VERDADE: sobe o servidor HTTP real (single-process, como o smoke
# E2E) servindo /admin e /v1/* contra o deployment da Bia (DeepSeek). Abra
# http://localhost:9292/admin/chat no navegador e converse — cada mensagem
# dispara o MESMO send_message da API, com tools/skills/memória reais.
#
# Single-process (Async::HTTP::Server, não `falcon serve`): kill -9 mata tudo e
# libera a porta (o pai do falcon não mata os workers). supervised = true DEPOIS
# do wiring: os turnos nascem filhos de um supervisor de vida-longa e sobrevivem
# ao disconnect da request (L4) — é o que faz a sessão multi-turn funcionar.
#
# Uso: DEEPSEEK_API_KEY=... ruby scripts/serve_real.rb   (BIND opcional)

$stdout.sync = true
require_relative "../config/deployment"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require File.join(Dir.pwd, "server", "app")

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

APP = Harness::Server::App.new(
  command_bus: W::BUS, event_stream: W::EVENT_STREAM,
  session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  checkpoint_store: W::CHECKPOINT_STORE, pending_action_store: W::PENDING_ACTION_STORE,
  catalogs: { skills: W::CATALOG, prompts: W::PROMPT_CATALOG },
  registries: { tools: W::REGISTRY, workflows: W::WORKFLOW_REGISTRY, policies: W::POLICY_REGISTRY },
  config: { admin_token: ADMIN_TOKEN, allowed_origins: [] }
)

BIND = ENV.fetch("BIND", "http://localhost:9292")
endpoint = Async::HTTP::Endpoint.parse(BIND)
middleware = Protocol::Rack::Adapter.new(LocalAdminShim.new(APP, ADMIN_TOKEN))

puts "\e[1mHarness — servindo de verdade (Bia · DeepSeek #{Deploy::MODEL})\e[0m"
puts "  #{BIND}/admin/chat   → converse com a Bia (agente: bia · session_id: web)"
puts "  #{BIND}/admin/events → tool-cards ao vivo (filtre por session_id: web)"
puts "  #{BIND}/admin        → console"
puts "  Ctrl-C para parar."

Async do
  W::EXECUTOR.supervised = true # modo serving (L4): turnos sobrevivem ao disconnect
  Async::HTTP::Server.new(middleware, endpoint).run
end
