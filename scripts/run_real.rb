# frozen_string_literal: true

# RODAR DE VERDADE (sem mock): conversa REAL e MULTI-TURN com a Bia (DeepSeek),
# serializada pelo SessionActor. Cada turno vai na fila FIFO da sessão;
# o turno 2 enxerga o transcript do turno 1 (memória de sessão via o Session
# provider — o seam :vars reconciliado). Streama a resposta, mostra
# tools/skills/retornos, e renderiza o /admin contra os MESMOS stores.
#
# Operação (o que destravou o multi-turn): arma executor.supervised = true
# (SessionActor + supervisor de vida-longa), e no fim FAZ O TEARDOWN
# (stop_session_actors + supervisor.stop) — senão o bloco Sync nunca retorna
# (os fibers de vida-longa ficam pendurados em dequeue).
#
# Uso: DEEPSEEK_API_KEY=... ruby scripts/run_real.rb

$stdout.sync = true
require_relative "../config/deployment"
require "async"
require "rack"
require File.join(Dir.pwd, "server", "app")

W = Deploy::Wiring
SESSION = "demo-bia"
W::SESSION_STORE.create(id: SESSION, vars: { "canal" => "web", "cliente" => "Ana" })

TURNS = ARGV.empty? ? ["Boa noite! Vocês estão abertos agora? Meu nome é Ana.",
                       "Perfeito. Quanto fica 2 pizzas margherita + 1 suco natural? Quero fechar o pedido."] : ARGV
TERMINAL = %w[completed failed cancelled].freeze

def stream_events(parent)
  sub = W::EVENT_STREAM.subscribe
  reader = parent.async do
    sub.each do |ev|
      case ev.type
      when :content         then print(ev.data[:delta])
      when :tool_call       then puts("\n  \e[36m→ #{ev.data[:name]}(#{ev.data[:arguments].inspect})\e[0m")
      when :tool_result     then puts("  \e[36m← #{ev.data[:name]}: #{ev.data[:result].to_s[0, 220]}\e[0m")
      when :skill_activated  then puts("\n  \e[35m↑ load_skill(#{ev.data[:name]})\e[0m")
      end
    end
  end
  [sub, reader]
end

@last_task = nil
Sync do |parent|
  W::EXECUTOR.supervised = true # arma o modo serving: SessionActor serializa a sessão
  sub, reader = stream_events(parent)

  TURNS.each_with_index do |msg, i|
    puts "\n\e[1m═══ TURNO #{i + 1} · Bia (DeepSeek #{Deploy::MODEL}) · sessão #{SESSION} ═══\e[0m"
    puts "\e[33mAna>\e[0m #{msg}\n\e[32mbia>\e[0m "

    # turno DE SESSÃO (session_id): entra na fila FIFO do SessionActor; o turno 2
    # já enxerga o turno 1 no transcript (memória real, sem mock).
    res = W::BUS.dispatch(Harness::Command.build(:send_message,
                                                 { agent: "bia", message: msg, session_id: SESSION },
                                                 transport: :cli))
    tid = res[:task_id]
    900.times do
      t = W::TASK_STORE.find(tid)
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.1)
    end
    @last_task = W::TASK_STORE.find(tid)
    puts "\n  \e[2m[status: #{@last_task&.status} · turnos na sessão: #{W::SESSION_STORE.find(SESSION).messages.size}]\e[0m"
  end

  # TEARDOWN (destrava o Sync): encerra os loops de vida-longa da sessão + o
  # supervisor. Sem isto o bloco fica pendurado esperando os fibers ociosos.
  sub.close
  reader.wait
  W::EXECUTOR.stop_session_actors
  W::EXECUTOR.instance_variable_get(:@supervisor)&.stop
end

msgs = W::SESSION_STORE.find(SESSION).messages
puts "\n\e[1m═══ RESUMO ═══\e[0m"
puts "transcript persistido na sessão (#{msgs.size} msgs): #{msgs.map { |m| m['role'] }.join(' → ')}"

# --- visualização: renderiza o /admin contra os MESMOS stores ---
OUT = ENV.fetch("OUT", "/tmp/admin-real")
require "fileutils"
FileUtils.mkdir_p(OUT)
fake = Object.new.tap { |o| def o.dispatch(*) = nil; def o.emit(*) = nil }
admin = Harness::Server::Admin::App.new(
  command_bus: fake, session_store: W::SESSION_STORE, task_store: W::TASK_STORE,
  checkpoint_store: W::CHECKPOINT_STORE, pending_action_store: W::PENDING_ACTION_STORE,
  catalogs: { skills: W::CATALOG, prompts: W::PROMPT_CATALOG },
  registries: { tools: W::REGISTRY, workflows: W::WORKFLOW_REGISTRY }, event_stream: fake
)
last = @last_task
routes = {
  "01-index" => "/admin", "02-sessions" => "/admin/sessions",
  "03-session" => "/admin/sessions/#{SESSION}", "04-tasks" => "/admin/tasks",
  "05-task" => "/admin/tasks/#{last&.id}", "08-chat" => "/admin/chat",
  "09-events" => "/admin/events", "10-skills" => "/admin/skills", "11-plugins" => "/admin/plugins"
}
routes.each do |name, path|
  _s, _h, body = admin.call(Rack::Request.new(Rack::MockRequest.env_for(path)))
  File.write(File.join(OUT, "#{name}.html"), body.join)
end
puts "admin (REAL) renderizado em #{OUT}"
