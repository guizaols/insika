# frozen_string_literal: true

require "erb"
require "cgi"

module Harness
  module Server
    module Admin
      # Esqueleto read-only do Control UI (RFC-0007, doc 07 §1-§2). Fase 1: só
      # LEITURA de stores/catálogos/registries já injetados no Server::App — não
      # despacha Command nem escreve em store (regra constitucional doc 07 §4).
      # Render com ERB da stdlib (L3): zero deps, zero asset pipeline.
      #
      # A auth (AdminAuth) e o CORS são aplicados ANTES pelo Server::App; este
      # app só roteia GETs e renderiza.
      class App
        VIEWS_DIR = File.expand_path("views", __dir__)

        # Defense-in-depth (o painel renderiza transcripts de usuário/LLM; `h()`
        # é a 1ª barreira, isto é a 2ª). CSP bloqueia carga/exfil para origens
        # externas — `connect-src 'self'` restringe o EventSource de events.erb à
        # mesma origem; `'unsafe-inline'` cobre o <style>/<script> inline (L3,
        # zero asset pipeline). `nosniff` evita content-type sniffing.
        HTML_HEADERS = {
          "content-type" => "text/html; charset=utf-8",
          "x-content-type-options" => "nosniff",
          "content-security-policy" =>
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; " \
            "connect-src 'self'; base-uri 'none'; form-action 'self'"
        }.freeze

        def initialize(session_store:, task_store:, checkpoint_store:,
                       catalogs:, registries:, event_stream:)
          @session_store = session_store
          @task_store = task_store
          @checkpoint_store = checkpoint_store
          @catalogs = catalogs
          @registries = registries
          @event_stream = event_stream
        end

        # req: Rack::Request (path já validado como /admin* pelo Server::App).
        # Read-only: qualquer método != GET -> 404 (doc 07 §2).
        def call(req)
          return not_found unless req.get?

          case req.path_info.split("/").reject(&:empty?)
          in ["admin"]                    then render("index")
          in ["admin", "sessions"]        then render("sessions", sessions: sessions_list)
          in ["admin", "sessions", id]    then show_session(id)
          in ["admin", "tasks"]           then render("tasks", tasks: tasks_list)
          in ["admin", "tasks", id]       then show_task(id)
          in ["admin", "events"]          then render("events")
          in ["admin", "skills"]          then render("skills", skills: @catalogs[:skills].all)
          in ["admin", "plugins"]         then render("plugins", groups: plugin_groups)
          else not_found
          end
        end

        private

        def sessions_list
          @session_store.each_id.filter_map do |id|
            session = @session_store.find(id)
            next unless session

            { id: id, count: session.messages.size, updated_at: session.updated_at }
          end
        end

        def show_session(id)
          session = @session_store.find(id)
          return not_found unless session

          render("session", id: id, session: session)
        end

        def tasks_list
          @task_store.each_id.filter_map { |id| @task_store.find(id) }
        end

        def show_task(id)
          task = @task_store.find(id)
          return not_found unless task

          render("task", task: task, checkpoint: @checkpoint_store.latest(id))
        end

        # Plugins carregados = agrupamento das Entry#plugin dos registries
        # (doc 06 §2; nil = registrado direto no wiring/sistema). Evita um canal
        # novo wiring->App (Notes da task).
        def plugin_groups
          tools = @registries[:tools].entries.group_by(&:plugin)
          workflows = @registries[:workflows].entries.group_by(&:plugin)
          (tools.keys | workflows.keys).map do |plugin|
            { plugin: plugin, tools: tools[plugin] || [], workflows: workflows[plugin] || [] }
          end
        end

        def render(view, locals = {})
          template = File.read(File.join(VIEWS_DIR, "#{view}.erb"))
          html = ERB.new(template, trim_mode: "-").result(ViewContext.new(locals).get_binding)
          [200, HTML_HEADERS.dup, [html]]
        end

        def not_found
          html = ERB.new(File.read(File.join(VIEWS_DIR, "not_found.erb")))
                    .result(ViewContext.new({}).get_binding)
          [404, HTML_HEADERS.dup, [html]]
        end

        # Contexto de render das views. `h` (CGI.escapeHTML) escapa TODO valor
        # dinâmico — transcripts/payloads carregam conteúdo de usuário/LLM que
        # encontra o browser do operador aqui (edge case XSS #1). `style`/`nav`
        # são parciais compartilhadas sem asset externo.
        class ViewContext
          def initialize(locals)
            locals.each { |k, v| instance_variable_set("@#{k}", v) }
          end

          def h(value) = CGI.escapeHTML(value.to_s)

          def style
            <<~CSS
              <style>
                body { font-family: system-ui, sans-serif; margin: 2rem; color: #222; }
                a { color: #0a58ca; }
                table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
                th, td { border: 1px solid #ccc; padding: .35rem .6rem; text-align: left; vertical-align: top; }
                th { background: #f4f4f4; }
                pre { background: #f7f7f7; padding: .6rem; overflow-x: auto; white-space: pre-wrap; }
                nav a { margin-right: 1rem; }
                .muted { color: #777; }
              </style>
            CSS
          end

          def nav
            links = { "índice" => "/admin", "sessions" => "/admin/sessions",
                      "tasks" => "/admin/tasks", "events" => "/admin/events",
                      "skills" => "/admin/skills", "plugins" => "/admin/plugins" }
            "<nav>#{links.map { |label, href| "<a href=\"#{href}\">#{label}</a>" }.join}</nav>"
          end

          def get_binding = binding
        end
        private_constant :ViewContext
      end
    end
  end
end
