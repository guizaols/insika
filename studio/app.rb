# frozen_string_literal: true

require "roda"
require "digest"
require "rack/utils"

module Studio
  # Harness Studio (Fase 4, Etapa E) — a UI de gestão server-rendered, substituta
  # do agent-studio do OpenClaw. FRAMEWORK NA BORDA (00-overview D1): é um app
  # Roda separado, montado sob `/studio`; `lib/harness` e `server/` NÃO ganham
  # dependência de Roda. Fala com o runtime pela MESMA superfície que a API:
  # despacha Commands no CommandBus e lê profiles/stores — nunca escreve em store
  # direto (regra constitucional do transporte).
  #
  # Auth por SESSÃO/cookie (D7): login compara o token em tempo constante contra
  # `HARNESS_ADMIN_TOKEN`, seta cookie httpOnly SameSite=Lax e protege `/studio/*`
  # fail-closed (sem token configurado → login nunca valida → studio inacessível).
  # Substitui o `LocalAdminShim`/Bearer manual do #25. CSRF nos POSTs.
  #
  # Assets same-origin (D8): bundle esbuild versionado em `assets/dist/*`, servido
  # por `/studio/assets/dist/*`. CSP estrita `'self'` (sem `unsafe-inline`).
  class App < Roda
    # Cookie de sessão vive N dias (D7). 7 dias = paridade com o padrão OpenClaw.
    SESSION_MAX_AGE = 7 * 24 * 3600
    ASSETS_DIR = File.expand_path("assets/dist", __dir__)

    CONTENT_TYPES = {
      ".js" => "text/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".map" => "application/json; charset=utf-8",
      ".woff2" => "font/woff2", ".svg" => "image/svg+xml"
    }.freeze

    # Plugins que NÃO dependem do secret (carregados na definição da classe).
    plugin :render, views: File.expand_path("views", __dir__), engine: "erb",
                    layout: "layout", escape: true
    plugin :hash_branches
    plugin :h

    # CSP estrita (D8): sem `unsafe-inline`. Tudo vem do bundle same-origin em
    # /studio/assets/dist. `connect-src 'self'` cobre o EventSource do playground
    # (SSE de /v1/events, mesma origem). `img-src data:` cobre inline SVG/ícones.
    plugin :content_security_policy do |csp|
      csp.default_src :none
      csp.script_src :self
      csp.style_src :self
      csp.img_src :self, "data:"
      csp.font_src :self
      csp.connect_src :self
      csp.form_action :self
      csp.base_uri :none
      csp.frame_ancestors :none
    end

    class << self
      # Dependências do runtime injetadas no boot (mesma superfície do Server::App).
      attr_reader :harness

      # Wiring do Studio (chamado pelo boot: serve_real / config.ru). Carrega os
      # plugins que dependem do secret (sessions/csrf/flash) e guarda as deps.
      # `session_secret` explícito é para os specs; em produção deriva do token de
      # admin (estável entre restarts, sem exigir mais uma env var).
      def configure(command_bus:, profile_source:, event_stream:, config:, session_secret: nil)
        @harness = {
          command_bus: command_bus, profile_source: profile_source,
          event_stream: event_stream, config: config
        }.freeze
        secret = session_secret || derive_secret(config[:admin_token])
        plugin :sessions, key: "harness.studio", secret: secret,
                          max_seconds: SESSION_MAX_AGE, same_site: :lax
        # Token de CSRF ligado à SESSÃO (não ao par método+path). O binding por
        # path do route_csrf usa `request.path` = PATH_INFO PÓS-MOUNT ("/login",
        # não "/studio/login"), o que confundiria form-action × token sob o
        # URLMap. Session-bound é seguro para o alvo single-tenant.
        plugin :route_csrf, require_request_specific_tokens: false, csrf_failure: :empty_403
        plugin :flash
        self
      end

      # Segredo de sessão determinístico por deploy (>=64 bytes exigidos pelo Roda
      # sessions). Deriva do token de admin → estável entre restarts (a sessão
      # sobrevive) sem uma env var nova; troca o token e todas as sessões caem.
      def derive_secret(admin_token)
        Digest::SHA512.hexdigest("harness-studio-session-v1:#{admin_token}")
      end
    end

    route do |r|
      response["x-content-type-options"] = "nosniff"
      response["referrer-policy"] = "same-origin"

      # Assets versionados (D8): públicos (a UI carrega o bundle ANTES do login).
      r.on "assets", "dist" do
        r.get String do |name|
          serve_asset(name)
        end
      end

      # Login (D7): único caminho sem sessão. GET mostra o form; POST valida o
      # token em tempo constante e, se ok, marca a sessão e redireciona.
      r.is "login" do
        r.get { view("login") }
        r.post do
          check_csrf!
          if authenticate(r.params["token"])
            session["auth"] = true
            r.redirect("/studio/agents")
          else
            @error = "Token inválido ou studio desabilitado (defina HARNESS_ADMIN_TOKEN)."
            response.status = 401
            view("login")
          end
        end
      end

      # --- FAIL-CLOSED: daqui pra baixo exige sessão autenticada -------------
      r.redirect("/studio/login") unless authenticated?

      r.post "logout" do
        check_csrf!
        clear_session
        r.redirect("/studio/login")
      end

      # `/studio` e `/studio/` → lista de agentes.
      r.root { r.redirect("/studio/agents") }

      # Agentes (lista) — lê do ProfileSource (mesma fonte do dispatch de turno).
      r.get "agents" do
        @agents = harness[:profile_source].all.sort_by(&:id)
        view("agents")
      end

      # Playground: envia `send_message` (o MESMO Command da API) e streama a
      # resposta ao vivo pelo island `live-transcript` (SSE de /v1/events).
      r.on "playground" do
        r.get do
          @agent = presence(r.params["agent"]) || default_agent
          @session_id = presence(r.params["session_id"])
          @agents = harness[:profile_source].ids.sort
          view("playground")
        end
        r.post do
          check_csrf!
          agent = presence(r.params["agent"]) || default_agent
          typed_session = presence(r.params["session_id"])
          message = r.params["message"].to_s
          # Sessão em branco = nova conversa: cria via Command (create_session
          # gera o id — o Studio não escreve no store direto). Um id digitado
          # continua uma conversa existente (send_message exige que exista).
          session_id = typed_session || create_session
          dispatch_send_message(agent: agent, session_id: session_id, message: message)
          r.redirect(playground_path(agent, session_id))
        rescue Harness::ValidationError, Harness::NotFoundError => e
          flash["error"] = e.message
          r.redirect(playground_path(agent, typed_session))
        end
      end

      # Rota autenticada desconhecida → 404 amigável (não o corpo vazio do Roda).
      response.status = 404
      view("not_found")
    end

    private

    # --- Helpers (escopo de instância; disponíveis nas views) ----------------

    def harness = self.class.harness

    # Navegação da app-bar. Etapa E entrega agentes + playground; as demais
    # páginas (skills/tools/mcp/settings/chats) chegam nas Etapas F/G.
    def nav_links
      { "agentes" => "/studio/agents", "playground" => "/studio/playground" }
    end

    def authenticated? = session["auth"] == true

    # Fail-closed POR CONSTRUÇÃO (paridade AdminAuth): sem token configurado, o
    # compare nunca passa → studio inacessível. Comparação em tempo constante.
    def authenticate(provided)
      configured = harness[:config][:admin_token].to_s
      provided = provided.to_s
      return false if configured.empty? || provided.empty?

      Rack::Utils.secure_compare(configured, provided)
    end

    def default_agent
      ids = harness[:profile_source].ids
      ids.include?("bia") ? "bia" : (ids.first || "bia")
    end

    # Despacha o send_message pelo MESMO bus da API (nada de escrita direta em
    # store). Retorna o resultado (Hash com task_id) — a UI observa o turno via SSE.
    def dispatch_send_message(agent:, session_id:, message:)
      command = Harness::Command.build(
        :send_message, { agent: agent, session_id: session_id, message: message },
        transport: :studio
      )
      harness[:command_bus].dispatch(command)
    end

    # Cria uma sessão nova pelo bus (create_session gera o id) e devolve o id.
    def create_session
      result = harness[:command_bus].dispatch(
        Harness::Command.build(:create_session, { vars: { "canal" => "studio" } }, transport: :studio)
      )
      result.id
    end

    def playground_path(agent, session_id)
      query = "agent=#{Rack::Utils.escape(agent)}"
      query += "&session_id=#{Rack::Utils.escape(session_id)}" if session_id
      "/studio/playground?#{query}"
    end

    # Serve um asset versionado do dist. `File.basename` mata path traversal; só
    # arquivos existentes no dir de dist são servidos.
    def serve_asset(name)
      base = File.basename(name)
      path = File.join(ASSETS_DIR, base)
      unless File.file?(path) && File.fnmatch(File.join(ASSETS_DIR, "*"), path)
        response.status = 404
        return "not found"
      end

      response["content-type"] = CONTENT_TYPES.fetch(File.extname(base), "application/octet-stream")
      response["cache-control"] = "public, max-age=300"
      File.read(path)
    end

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end
  end
end
