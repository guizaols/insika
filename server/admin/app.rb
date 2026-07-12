# frozen_string_literal: true

require "erb"
require "cgi"
require "rack"
require "time"

module Harness
  module Server
    module Admin
      # Esqueleto read-only do Control UI: só
      # LEITURA de stores/catálogos/registries já injetados no Server::App — não
      # despacha Command nem escreve em store (regra constitucional).
      # Render com ERB da stdlib: zero deps, zero asset pipeline.
      #
      # A auth (AdminAuth) e o CORS são aplicados ANTES pelo Server::App; este
      # app só roteia GETs e renderiza.
      class App
        VIEWS_DIR = File.expand_path("views", __dir__)

        # Defense-in-depth (o painel renderiza transcripts de usuário/LLM; `h()`
        # é a 1ª barreira, isto é a 2ª). CSP bloqueia carga/exfil para origens
        # externas — `connect-src 'self'` restringe o EventSource de events.erb à
        # mesma origem; `'unsafe-inline'` cobre o <style>/<script> inline (zero
        # asset pipeline). `nosniff` evita content-type sniffing.
        # `script-src 'self'`: permite o Turbo/Stimulus vendored em
        # /admin/assets/*; `'unsafe-inline'` cobre o <style> inline. `connect-src
        # 'self'` casa com o EventSource same-origin.
        HTML_HEADERS = {
          "content-type" => "text/html; charset=utf-8",
          "x-content-type-options" => "nosniff",
          "content-security-policy" =>
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; " \
            "connect-src 'self'; base-uri 'none'; form-action 'self'"
        }.freeze

        def initialize(command_bus:, session_store:, task_store:, checkpoint_store:,
                       pending_action_store:, catalogs:, registries:, event_stream:)
          @command_bus = command_bus
          @session_store = session_store
          @task_store = task_store
          @checkpoint_store = checkpoint_store
          @pending_action_store = pending_action_store
          @catalogs = catalogs
          @registries = registries
          @event_stream = event_stream
        end

        # req: Rack::Request (path já validado como /admin*; auth/CORS no Server::App).
        # GET = leitura; POST = ação de escrita. Outros métodos -> 404.
        def call(req)
          segments = req.path_info.split("/").reject(&:empty?)
          return write(req, segments) if req.post?
          return not_found unless req.get?

          case segments
          in ["admin"]                    then render("index")
          in ["admin", "sessions"]        then render("sessions", sessions: sessions_list)
          in ["admin", "sessions", id]    then show_session(id)
          in ["admin", "tasks"]           then render("tasks", tasks: tasks_list)
          in ["admin", "tasks", id]       then show_task(id)
          in ["admin", "events"]          then render("events")
          in ["admin", "skills"]          then render("skills", skills: @catalogs[:skills].all)
          in ["admin", "plugins"]         then render("plugins", groups: plugin_groups)
          in ["admin", "chat"]            then render("chat")
          in ["admin", "assets", name]    then asset(name)
          else not_found
          end
        end

        private

        # --- Escrita: traduz a ação da UI em Command, audita e responde
        # Turbo Stream (se o cliente aceita) ou 303 redirect (degradação sem JS).
        def write(req, segments)
          case segments
          in ["admin", "tasks", id, "pause"]  then act(req, :pause_task, { task_id: id })
          in ["admin", "tasks", id, "resume"] then act(req, :resume_task, { task_id: id })
          in ["admin", "tasks", id, "cancel"] then act(req, :cancel_task, { task_id: id })
          in ["admin", "approvals", pid]      then act(req, :approve_action, approval_payload(req, pid))
          in ["admin", "chat"]                then act(req, :send_message, chat_payload(req))
          else not_found
          end
        end

        # Auditoria SEMPRE antes do dispatch: mesmo que o Command falhe, a
        # tentativa do operador fica registrada no Event Stream. Erro do Command
        # (Validation/NotFound) vira turbo_stream/HTML de erro (não status HTTP —
        # o /admin é HTML).
        def act(req, type, payload)
          @event_stream.emit(Harness::Event.new(
                               type: :operator_action,
                               # target RESUMIDO: nunca `message`/`args` — o audit
                               # vai ao EventStream compartilhado (que /v1/events
                               # expõe sem auth), então não vaza conteúdo de
                               # usuário. Só metadados de accountability.
                               data: { action: type.to_s, target: audit_target(payload),
                                       operator: operator_of(req) },
                               meta: { task_id: payload[:task_id], session_id: payload[:session_id],
                                       at: Time.now.utc.iso8601 }
                             ))
          @command_bus.dispatch(Harness::Command.build(type, payload, transport: :admin))
          respond_write(req, ok: true, action: type)
        rescue Harness::ValidationError, Harness::NotFoundError => e
          respond_write(req, ok: false, action: type, error: e.message)
        end

        def operator_of(req) = req.get_header("HTTP_X_OPERATOR") || "operator"

        # Só metadados (task/pending/session/agent/decision) — NUNCA o conteúdo
        # (message/args), que vazaria a consumidores de /v1/events.
        def audit_target(payload)
          payload.slice(:task_id, :pending_id, :session_id, :agent, :decision)
        end

        def respond_write(req, ok:, action:, error: nil)
          if turbo?(req)
            flash = ok ? "#{action}: ok" : "#{action}: #{error}"
            body = %(<turbo-stream action="update" target="flash"><template>) +
                   %(<div id="flash">#{CGI.escapeHTML(flash)}</div></template></turbo-stream>)
            [ok ? 200 : 422, { "content-type" => "text/vnd.turbo-stream.html; charset=utf-8" }.merge(security_headers), [body]]
          else
            # sem Turbo: redireciona de volta (degradação graciosa — form normal).
            # Volta ao referer (a página de origem) quando presente.
            back = req.get_header("HTTP_REFERER")
            back = "/admin/tasks" if back.nil? || back.empty?
            [303, { "location" => back }.merge(security_headers), []]
          end
        end

        def turbo?(req) = req.get_header("HTTP_ACCEPT").to_s.include?("text/vnd.turbo-stream.html")
        def security_headers = { "x-content-type-options" => "nosniff" }

        def approval_payload(req, pending_id)
          form = Rack::Utils.parse_query(req.body&.read.to_s)
          # mesmo operador do audit: resolved_by no store bate com o :operator_action.
          { pending_id: pending_id, decision: form["decision"] || "approved",
            operator: operator_of(req) }
        end

        def chat_payload(req)
          form = Rack::Utils.parse_query(req.body&.read.to_s)
          { agent: form["agent"], message: form["message"], session_id: form["session_id"] }.compact
        end

        # Assets vendored: Turbo/Stimulus servidos localmente (sem CDN
        # p/ respeitar a CSP, sem build). content-type js + cache curto.
        def asset(name)
          path = File.join(VIEWS_DIR, "..", "assets", File.basename(name))
          return not_found unless File.file?(path)

          [200, { "content-type" => "text/javascript; charset=utf-8", "cache-control" => "max-age=300" },
           [File.read(path)]]
        end

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

          pending = @pending_action_store ? @pending_action_store.open_for(id) : []
          render("task", task: task, checkpoint: @checkpoint_store.latest(id), pending: pending)
        end

        # Plugins carregados = agrupamento das Entry#plugin dos registries
        # (nil = registrado direto no wiring/sistema). Evita um canal
        # novo wiring->App.
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
        # encontra o browser do operador aqui (edge case XSS). `style`/`nav`
        # são parciais compartilhadas sem asset externo.
        class ViewContext
          def initialize(locals)
            locals.each { |k, v| instance_variable_set("@#{k}", v) }
          end

          def h(value) = CGI.escapeHTML(value.to_s)

          # Design system do console. Tudo inline (CSP: 'unsafe-inline'
          # cobre <style>/<script>; nenhum asset externo — CSP bloqueia mesmo).
          # Tema-aware: tokens em :root, redefinidos sob prefers-color-scheme:dark.
          def style
            <<~CSS
              <style>
                :root {
                  --bg:#f6f7f9; --surface:#fff; --surface-2:#f0f2f5; --border:#e4e7ec;
                  --text:#1a1d26; --muted:#6b7280; --accent:#6366f1; --accent-weak:#eef0fe;
                  --ok:#16a34a; --warn:#d97706; --err:#dc2626; --run:#2563eb; --info:#0891b2;
                  --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
                  --radius:10px; --shadow:0 1px 2px rgba(16,20,40,.06),0 1px 3px rgba(16,20,40,.04);
                }
                @media (prefers-color-scheme: dark) {
                  :root {
                    --bg:#0e0f13; --surface:#171923; --surface-2:#1e212c; --border:#2a2e3a;
                    --text:#e6e8ee; --muted:#98a0ad; --accent:#818cf8; --accent-weak:#20233a;
                    --ok:#4ade80; --warn:#fbbf24; --err:#f87171; --run:#60a5fa; --info:#22d3ee;
                    --shadow:0 1px 2px rgba(0,0,0,.4);
                  }
                }
                * { box-sizing: border-box; }
                body {
                  font-family: system-ui,-apple-system,"Segoe UI",sans-serif; margin: 0;
                  color: var(--text); background: var(--bg); line-height: 1.5;
                  -webkit-font-smoothing: antialiased;
                }
                .appbar {
                  display:flex; align-items:center; gap:1.25rem; padding:.7rem 1.25rem;
                  background:var(--surface); border-bottom:1px solid var(--border);
                  position:sticky; top:0; z-index:10; flex-wrap:wrap;
                }
                .appbar .brand { display:flex; align-items:center; gap:.5rem; font-weight:650; letter-spacing:-.01em; }
                .appbar .brand .dot { width:.6rem; height:.6rem; border-radius:50%; background:var(--accent); box-shadow:0 0 0 3px var(--accent-weak); }
                .appbar .brand small { color:var(--muted); font-weight:500; }
                .appbar .links { display:flex; gap:.15rem; flex-wrap:wrap; margin-left:auto; }
                .appbar .links a {
                  color:var(--muted); text-decoration:none; font-size:.9rem; font-weight:500;
                  padding:.35rem .6rem; border-radius:7px;
                }
                .appbar .links a:hover { color:var(--text); background:var(--surface-2); }
                .appbar .links a[aria-current="page"] { color:var(--accent); background:var(--accent-weak); }
                .page { max-width: 1000px; margin: 0 auto; padding: 1.5rem 1.25rem 4rem; }
                h1 { font-size:1.5rem; letter-spacing:-.02em; margin:.2rem 0 .1rem; text-wrap:balance; }
                h1 .sub { display:block; font-size:.85rem; font-weight:400; color:var(--muted); letter-spacing:0; margin-top:.15rem; }
                h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:2rem 0 .6rem; }
                a { color:var(--accent); }
                .muted { color: var(--muted); }
                .card {
                  background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
                  padding:1rem 1.15rem; box-shadow:var(--shadow); margin:.6rem 0;
                }
                .grid { display:grid; gap:.75rem; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); }
                .grid .card { margin:0; }
                .grid .card .k { font-size:.72rem; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); }
                .grid .card .v { font-size:1.35rem; font-weight:600; margin-top:.15rem; }
                table { border-collapse:collapse; width:100%; margin:.5rem 0; font-size:.9rem; }
                th,td { border-bottom:1px solid var(--border); padding:.5rem .65rem; text-align:left; vertical-align:top; }
                th { color:var(--muted); font-weight:600; font-size:.75rem; text-transform:uppercase; letter-spacing:.04em; }
                tr:last-child td { border-bottom:0; }
                code, .mono { font-family:var(--mono); font-size:.86em; }
                pre {
                  background:var(--surface-2); border:1px solid var(--border); border-radius:8px;
                  padding:.7rem .8rem; overflow-x:auto; white-space:pre-wrap; word-break:break-word;
                  font-family:var(--mono); font-size:.82rem; margin:.4rem 0;
                }
                .pill {
                  display:inline-flex; align-items:center; gap:.35rem; font-size:.75rem; font-weight:600;
                  padding:.15rem .55rem; border-radius:999px; border:1px solid transparent; text-transform:lowercase;
                }
                .pill::before { content:""; width:.45rem; height:.45rem; border-radius:50%; background:currentColor; }
                .pill.ok{color:var(--ok);background:color-mix(in srgb,var(--ok) 12%,transparent);}
                .pill.warn{color:var(--warn);background:color-mix(in srgb,var(--warn) 14%,transparent);}
                .pill.err{color:var(--err);background:color-mix(in srgb,var(--err) 12%,transparent);}
                .pill.run{color:var(--run);background:color-mix(in srgb,var(--run) 12%,transparent);}
                .pill.info{color:var(--info);background:color-mix(in srgb,var(--info) 12%,transparent);}
                button {
                  font:inherit; font-size:.85rem; font-weight:550; cursor:pointer; color:var(--text);
                  background:var(--surface); border:1px solid var(--border); border-radius:8px;
                  padding:.4rem .8rem; box-shadow:var(--shadow);
                }
                button:hover { border-color:var(--accent); color:var(--accent); }
                button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
                button.primary:hover { filter:brightness(1.08); color:#fff; }
                button.danger:hover { border-color:var(--err); color:var(--err); }
                input[type=text] {
                  font:inherit; padding:.4rem .55rem; border:1px solid var(--border); border-radius:8px;
                  background:var(--surface); color:var(--text);
                }
                .toolbar { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }
                /* chat bubbles */
                .thread { display:flex; flex-direction:column; gap:.85rem; }
                .msg { display:flex; gap:.6rem; max-width:82%; }
                .msg .who { flex:0 0 1.9rem; height:1.9rem; border-radius:50%; display:grid; place-items:center;
                  font-size:.8rem; font-weight:700; color:#fff; }
                .msg .bubble { border:1px solid var(--border); border-radius:12px; padding:.6rem .8rem; background:var(--surface); box-shadow:var(--shadow); }
                .msg .bubble .content { white-space:pre-wrap; word-break:break-word; }
                .msg .meta { font-size:.7rem; color:var(--muted); margin-top:.3rem; }
                .msg.user { align-self:flex-end; flex-direction:row-reverse; }
                .msg.user .who { background:var(--accent); }
                .msg.user .bubble { background:var(--accent-weak); border-color:transparent; }
                .msg.assistant .who { background:#0f766e; }
                .msg.tool .who { background:var(--warn); }
                /* tool-card */
                .toolcard { border:1px solid var(--border); border-left:3px solid var(--warn); border-radius:8px;
                  background:var(--surface); padding:.55rem .75rem; margin:.4rem 0; box-shadow:var(--shadow); }
                .toolcard.result { border-left-color:var(--ok); }
                .toolcard.skill { border-left-color:var(--accent); }
                .toolcard .h { display:flex; align-items:center; gap:.5rem; font-family:var(--mono); font-size:.82rem; }
                .toolcard .h .arrow { color:var(--muted); }
                .toolcard pre { margin:.4rem 0 0; background:var(--surface-2); }
                .empty { color:var(--muted); padding:1.5rem; text-align:center; border:1px dashed var(--border); border-radius:var(--radius); }
              </style>
            CSS
          end

          NAV_LINKS = { "índice" => "/admin", "chat" => "/admin/chat",
                        "sessions" => "/admin/sessions", "tasks" => "/admin/tasks",
                        "events" => "/admin/events", "skills" => "/admin/skills",
                        "plugins" => "/admin/plugins" }.freeze

          # App-bar (marca + navegação). O link ativo é marcado no cliente por
          # location.pathname — evita threadar o path do request até a view.
          def nav
            links = NAV_LINKS.map { |label, href| "<a href=\"#{href}\">#{h(label)}</a>" }.join
            <<~HTML
              <header class="appbar">
                <span class="brand"><span class="dot"></span>Harness <small>Control UI</small></span>
                <nav class="links">#{links}</nav>
              </header>
              <script>
                (function(){var p=location.pathname;var best="";document.querySelectorAll(".appbar .links a").forEach(function(a){var h=a.getAttribute("href");if(p===h||(h!=="/admin"&&p.indexOf(h)===0)){if(h.length>best.length)best=h;}});document.querySelectorAll(".appbar .links a").forEach(function(a){if(a.getAttribute("href")===best)a.setAttribute("aria-current","page");});})();
              </script>
            HTML
          end

          # Cabeçalho de página: app-bar + título (com subtítulo opcional). Views
          # chamam <%= header("Título", "sub") %> e abrem <div class="page">.
          def header(title, sub = nil)
            subhtml = sub ? "<span class=\"sub\">#{h(sub)}</span>" : ""
            "#{nav}<div class=\"page\"><h1>#{h(title)}#{subhtml}</h1>"
          end

          # Pill de status semântica (completed=ok, running=run, waiting/queued=warn,
          # failed/cancelled=err). Reusada em tasks/sessions.
          def status_pill(status)
            s = status.to_s
            cls = case s
                  when "completed" then "ok"
                  when "running" then "run"
                  when "waiting", "queued", "paused" then "warn"
                  when "failed", "cancelled" then "err"
                  else "info"
                  end
            "<span class=\"pill #{cls}\">#{h(s)}</span>"
          end

          def get_binding = binding
        end
        private_constant :ViewContext
      end
    end
  end
end
