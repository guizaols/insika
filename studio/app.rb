# frozen_string_literal: true

require "roda"
require "digest"
require "rack/utils"

module Studio
  # Harness Studio — a UI de gestão server-rendered, substituta do
  # agent-studio do OpenClaw. FRAMEWORK NA BORDA: é um app Roda
  # separado, montado sob `/studio`; `lib/harness` e `server/` NÃO ganham
  # dependência de Roda. Fala com o runtime pela MESMA superfície que a API:
  # despacha Commands no CommandBus e LÊ profiles/stores — nunca escreve em store
  # direto (regra constitucional do transporte).
  #
  # Auth por SESSÃO/cookie: login compara o token em tempo constante contra
  # `HARNESS_ADMIN_TOKEN`, seta cookie httpOnly SameSite=Lax e protege `/studio/*`
  # fail-closed (sem token configurado → login nunca valida → studio inacessível).
  # Substitui o `LocalAdminShim`/Bearer manual. CSRF nos POSTs.
  #
  # Assets same-origin: bundle esbuild versionado em `assets/dist/*`, servido
  # por `/studio/assets/dist/*`. CSP estrita `'self'` (sem `unsafe-inline`).
  class App < Roda
    # Cookie de sessão vive N dias. 7 dias = paridade com o padrão OpenClaw.
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

    # CSP estrita: sem `unsafe-inline`. Tudo vem do bundle same-origin em
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
      #
      # Além do trio de sempre (command_bus/profile_source/config), o
      # Studio passa a LER stores de autoria (agent_file/skill/tool/memory/session)
      # para renderizar as páginas. Todos opcionais (default nil): páginas que
      # dependem de um store degradam para um empty-state se ele não foi injetado.
      def configure(command_bus:, profile_source:, event_stream:, config:,
                    agent_file_store: nil, skill_store: nil, skill_catalog: nil,
                    tool_catalog: nil, tool_store: nil, memory_store: nil, session_store: nil,
                    settings_store: nil, llm_provider_store: nil, mcp_store: nil,
                    system_file_store: nil, tool_trace_store: nil, session_secret: nil)
        @harness = {
          command_bus: command_bus, profile_source: profile_source,
          event_stream: event_stream, config: config,
          agent_file_store: agent_file_store, skill_store: skill_store,
          skill_catalog: skill_catalog, tool_catalog: tool_catalog,
          # tool_store: definições das tools POR DADOS (Fase 5). O catálogo já
          # mostra as data-tools na matriz; o store alimenta a página de autoria.
          tool_store: tool_store,
          memory_store: memory_store, session_store: session_store,
          # config-de-runtime (settings/LLM/MCP) + arquivos de sistema
          # globais + índice de conversas. Todos opcionais (empty-state se nil).
          settings_store: settings_store, llm_provider_store: llm_provider_store,
          mcp_store: mcp_store, system_file_store: system_file_store,
          # trace de tool-calls por sessão (debug): args + resultado + status por
          # turno, renderizado no viewer de sessão (FOLLOWUP §3.1).
          tool_trace_store: tool_trace_store
        }.freeze
        # flag de "restart recomendado" — em memória, POR PROCESSO. Uma
        # mudança de config que o runtime só relê no boot (ex.: instâncias MCP são
        # ligadas na inicialização) acende a flag; reiniciar o processo a apaga
        # naturalmente (processo novo = `configure` roda de novo = flag zerada).
        # Não vai pra sessão de propósito: a sessão sobrevive ao restart (o secret
        # deriva do token) e a flag ficaria presa acesa.
        @restart_needed = false
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

      # --- Restart recomendado — estado por processo -----------------
      def restart_needed? = @restart_needed == true
      def mark_restart_needed! = (@restart_needed = true)
      def clear_restart_needed! = (@restart_needed = false)
    end

    route do |r|
      response["x-content-type-options"] = "nosniff"
      response["referrer-policy"] = "same-origin"

      # Assets versionados: públicos (a UI carrega o bundle ANTES do login).
      r.on "assets", "dist" do
        r.get String do |name|
          serve_asset(name)
        end
      end

      # Login: único caminho sem sessão. GET mostra o form; POST valida o
      # token em tempo constante e, se ok, marca a sessão e redireciona.
      r.is "login" do
        r.get { view("login") }
        r.post do
          check_csrf!
          if authenticate(r.params["token"])
            session["auth"] = true
            r.redirect("/studio/agents")
          else
            @error = "Invalid token, or the studio is disabled (set HARNESS_ADMIN_TOKEN)."
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

      # Dispensa o banner de "restart recomendado" sem reiniciar (o operador
      # reconhece e segue). Um restart de verdade zera a flag por conta própria.
      r.post "restart-ack" do
        check_csrf!
        self.class.clear_restart_needed!
        r.redirect(safe_back(r.params["back"]))
      end

      # `/studio` e `/studio/` → lista de agentes.
      r.root { r.redirect("/studio/agents") }

      # --- Agentes: lista + detalhe/autoria --------------------
      r.on "agents" do
        # /studio/agents — grid dos agentes (lê o ProfileSource).
        r.is do
          r.get do
            @agents = harness[:profile_source].all.sort_by(&:id)
            view("agents")
          end

          # POST /studio/agents — cria um agente ("cada um cria
          # sua BIA"). Dispara :create_agent; redireciona pro detalhe do novo.
          r.post do
            check_csrf!
            id = presence(r.params["id"])
            result = with_flash("Agente '#{id}' criado.") do
              dispatch(:create_agent, {
                         id: id, model: presence(r.params["model"]),
                         provider: presence(r.params["provider"]),
                         memory: r.params["memory"] == "1"
                       })
            end
            r.redirect(result ? agent_path(id) : "/studio/agents")
          end
        end

        # /studio/agents/:id — a página de autoria de um agente.
        r.on String do |id|
          id = utf8(id)
          @agent = harness[:profile_source].fetch(id)
          next_404 unless @agent

          # GET /studio/agents/:id — config + prompts + skills + memória + histórico.
          r.is do
            r.get { render_agent_detail }
          end

          # Config/model → :update_agent (merge de patch).
          r.post "config" do
            check_csrf!
            with_flash("Configuração salva.") do
              dispatch(:update_agent, config_patch(r))
            end
            r.redirect(agent_path(id))
          end

          # Prompts store-backed. Escrever também garante que o arquivo
          # entre em `prompt_files` — senão o Prompt provider não o carregaria.
          # prompt_files é sincronizado pelos próprios Commands (write/delete
          # registram/removem o arquivo) — o Studio só despacha a operação.
          r.on "prompts" do
            r.post "delete" do
              check_csrf!
              with_flash("Prompt removido.") do
                dispatch(:delete_agent_file, { agent_id: id, file: presence(r.params["file"]) })
              end
              r.redirect(agent_path(id))
            end

            r.post "restore" do
              check_csrf!
              with_flash("Versão restaurada.") do
                dispatch(:restore_agent_file, {
                           agent_id: id, file: presence(r.params["file"]),
                           version: r.params["version"]
                         })
              end
              r.redirect(agent_path(id))
            end

            r.post do
              check_csrf!
              with_flash("Prompt salvo.") do
                dispatch(:write_agent_file, {
                           agent_id: id, file: presence(r.params["file"]), content: r.params["content"].to_s
                         })
              end
              r.redirect(agent_path(id))
            end
          end

          # Skills do agente → :update_agent com a allowlist `skills`.
          # "todas" = nil; senão o subconjunto marcado (possivelmente []).
          r.post "skills" do
            check_csrf!
            skills = r.params["all_skills"] == "1" ? nil : Array(r.params["skills"]).map(&:to_s)
            with_flash("Skills atualizadas.") do
              dispatch(:update_agent, { id: id, skills: skills })
            end
            r.redirect(agent_path(id))
          end

          # Memória do agente. Escopada por tenant = id do agente — o
          # MESMO tenant que o playground usa ao conversar, então o que se edita
          # aqui é o que a BIA lê no turno. Cada agente, sua memória.
          r.on "memory" do
            r.post "fact" do
              check_csrf!
              with_flash("Fato salvo.") do
                dispatch(:memory_put_fact, {
                           tenant: id, key: presence(r.params["key"]), value: r.params["value"].to_s
                         })
              end
              r.redirect(agent_path(id, "memory"))
            end
            r.post "forget" do
              check_csrf!
              with_flash("Fato esquecido.") do
                dispatch(:memory_forget_fact, { tenant: id, key: presence(r.params["key"]) })
              end
              r.redirect(agent_path(id, "memory"))
            end
            r.post "note" do
              check_csrf!
              with_flash("Nota adicionada.") do
                dispatch(:memory_add_note, { tenant: id, text: r.params["text"].to_s })
              end
              r.redirect(agent_path(id, "memory"))
            end
          end
        end
      end

      # --- Skills: catálogo + matriz de agentes + editor -----------
      r.on "skills" do
        r.is do
          r.get { render_skills_index }
          # POST /studio/skills → grava a skill (SKILL.md completo) e recarrega
          # o catálogo (hot). Cobre "nova skill" e "salvar edição".
          r.post do
            check_csrf!
            name = presence(r.params["name"])
            with_flash("Skill salva.") do
              dispatch(:write_skill, { name: name, content: r.params["content"].to_s })
            end
            r.redirect(name ? "/studio/skills/#{Rack::Utils.escape(name)}" : "/studio/skills")
          end
        end

        # Editor de skill nova (antes do matcher genérico String).
        r.get "new" do
          @skill_name = ""
          @skill_content = new_skill_template
          view("skill_edit")
        end

        r.on String do |name|
          name = utf8(name)
          # GET /studio/skills/:name — editor (island code-editor).
          r.is do
            r.get do
              @skill_name = name
              @skill_content = skill_source(name)
              view("skill_edit")
            end
          end
          # Habilita/desabilita a skill em N agentes de uma vez.
          r.post "agents" do
            check_csrf!
            agent_ids = Array(r.params["agent_ids"]).map(&:to_s)
            result = with_flash("Agentes da skill atualizados.") do
              dispatch(:set_skill_agents, { name: name, agent_ids: agent_ids })
            end
            skipped = Array(result && result[:skipped_all])
            if skipped.any?
              flash["notice"] = "#{flash['notice']} — #{skipped.size} agente(s) com 'todas' as skills ficaram intactos."
            end
            r.redirect("/studio/skills")
          end
        end
      end

      # --- Tools: matriz tool × agente + autoria de tools POR DADOS ------------
      r.on "tools" do
        # Autoria de tool por dados (Fase 5). Sob /tools/def/* — ANTES do matcher
        # genérico `r.post String` (que é a matriz allow/deny por :id de agente).
        r.on "def" do
          # /studio/tools/def/new — editor vazio.
          r.get "new" do
            render_tool_edit(name: "", tool: nil)
          end

          # POST /studio/tools/def — cria (create_only: recusa sobrescrever).
          r.is do
            r.post do
              check_csrf!
              name = presence(r.params["name"])
              result = with_flash("Tool '#{name}' criada.") do
                dispatch(:write_data_tool, tool_patch(r).merge(create_only: true))
              end
              r.redirect(result ? tool_def_path(name) : "/studio/tools")
            end
          end

          r.on String do |name|
            name = utf8(name)
            # GET /studio/tools/def/:name — editor carregado (segredo mascarado).
            r.is do
              r.get do
                tool = harness[:tool_store]&.get(name)
                next_404 unless tool
                render_tool_edit(name: name, tool: tool)
              end
              # POST /studio/tools/def/:name — atualiza (upsert).
              r.post do
                check_csrf!
                with_flash("Tool '#{name}' salva.") { dispatch(:write_data_tool, tool_patch(r)) }
                r.redirect(tool_def_path(name))
              end
            end
            r.post "delete" do
              check_csrf!
              with_flash("Tool '#{name}' removida.") { dispatch(:delete_data_tool, { name: name }) }
              r.redirect("/studio/tools")
            end
            r.post "restore" do
              check_csrf!
              with_flash("Versão restaurada.") do
                dispatch(:restore_data_tool, { name: name, index: r.params["index"] })
              end
              r.redirect(tool_def_path(name))
            end
          end
        end

        r.is { r.get { render_tools_matrix } }

        # POST /studio/tools/:id — grava a allowlist de tools de um agente.
        # "todas" = nil; senão o subconjunto marcado. `deny` é preservado.
        r.post String do |id|
          check_csrf!
          id = utf8(id)
          profile = harness[:profile_source].fetch(id)
          next_404 unless profile
          allow = r.params["all_tools"] == "1" ? nil : Array(r.params["tools"]).map(&:to_s)
          with_flash("Tools do agente '#{id}' atualizadas.") do
            dispatch(:set_agent_tools, { id: id, allow: allow, deny: Array(profile.tools_deny) })
          end
          r.redirect("/studio/tools")
        end
      end

      # --- Settings gerais + providers de LLM ----------------------
      r.on "settings" do
        r.is do
          r.get { render_settings }
          # Settings gerais (streaming/timeouts/compaction) → :update_settings.
          r.post do
            check_csrf!
            with_flash("Settings salvos.") do
              dispatch(:update_settings, { patch: settings_patch(r) })
            end
            r.redirect("/studio/settings")
          end
        end

        # Providers de LLM (sub-recurso): CRUD com api_key mascarada (sentinel).
        r.on "providers" do
          r.post "delete" do
            check_csrf!
            with_flash("Provider removido.") do
              dispatch(:delete_llm_provider, { api: presence(r.params["api"]) })
            end
            r.redirect("/studio/settings#llm")
          end
          r.post do
            check_csrf!
            with_flash("Provider salvo.") do
              dispatch(:upsert_llm_provider, provider_patch(r))
            end
            r.redirect("/studio/settings#llm")
          end
        end
      end

      # --- MCP: instâncias com credenciais mascaradas --------------
      r.on "mcp" do
        r.is do
          r.get { render_mcp }
          r.post do
            check_csrf!
            with_flash("Instância MCP salva.") do
              dispatch(:upsert_mcp, mcp_patch(r))
              # Os servidores MCP são ligados no boot do runtime; a instância nova
              # só entra em vigor após reiniciar. Acende o banner de "restart".
              self.class.mark_restart_needed!
            end
            r.redirect("/studio/mcp")
          end
        end
        r.post "delete" do
          check_csrf!
          with_flash("Instância MCP removida.") do
            dispatch(:delete_mcp, { name: presence(r.params["name"]) })
            self.class.mark_restart_needed!
          end
          r.redirect("/studio/mcp")
        end
      end

      # --- Arquivos de sistema globais -----------------------------
      # Valem para TODOS os agentes (o Prompt provider injeta antes da
      # identidade individual). Editor code-editor + versões, como os prompts.
      r.on "system-files" do
        r.is do
          r.get { render_system_files }
          r.post do
            check_csrf!
            with_flash("Arquivo de sistema salvo.") do
              dispatch(:write_system_file, {
                         file: presence(r.params["file"]), content: r.params["content"].to_s
                       })
            end
            r.redirect("/studio/system-files")
          end
        end
        r.post "delete" do
          check_csrf!
          with_flash("Arquivo removido.") do
            dispatch(:delete_system_file, { file: presence(r.params["file"]) })
          end
          r.redirect("/studio/system-files")
        end
        r.post "restore" do
          check_csrf!
          with_flash("Versão restaurada.") do
            dispatch(:restore_system_file, {
                       file: presence(r.params["file"]), version: r.params["version"]
                     })
          end
          r.redirect("/studio/system-files")
        end
      end

      # --- Chats: índice de conversas ------------------------------
      # Read-only: lista sessões e linka pro viewer existente (/sessions/:id).
      r.on "chats" do
        r.is { r.get { render_chats } }
      end

      # --- Histórico: viewer read-only de uma sessão ---------------
      r.on "sessions" do
        r.on String do |sid|
          sid = utf8(sid)
          r.get do
            @session = harness[:session_store]&.find(sid)
            next_404 unless @session

            # Trace de tool-calls da sessão (debug): agrupado por turno na view.
            @tool_traces = (harness[:tool_trace_store]&.for_session(sid) || [])
                           .group_by { |t| t["turn"] }
            view("session")
          end
        end
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

    # Navegação da sidebar, agrupada por intenção do operador (build / runtime /
    # operate). Cada item: [label, href, icon-key]. A view marca o item ativo
    # comparando o path e renderiza o ícone via `nav_icon`.
    def nav_sections
      [
        ["build", [
          ["Agents", "/studio/agents", :agents],
          ["Skills", "/studio/skills", :skills],
          ["Tools", "/studio/tools", :tools],
          ["System files", "/studio/system-files", :system]
        ]],
        ["runtime", [
          ["MCP", "/studio/mcp", :mcp],
          ["Settings", "/studio/settings", :settings]
        ]],
        ["operate", [
          ["Chats", "/studio/chats", :chats],
          ["Playground", "/studio/playground", :playground]
        ]]
      ]
    end

    # Ícone SVG inline (stroke, currentColor) por chave de nav. Inline SVG é
    # permitido pela CSP (é elemento no HTML, não um recurso externo). 20×20,
    # herda a cor do link. Fonte: conjunto de ícones de linha estilo Lucide.
    NAV_ICONS = {
      agents: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
      skills: '<path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3z"/>',
      tools: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
      system: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M8 13h8"/><path d="M8 17h8"/>',
      mcp: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/>',
      settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
      chats: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
      playground: '<polygon points="6 3 20 12 6 21 6 3"/>'
    }.freeze

    def nav_icon(key)
      %(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ) +
        %(stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{NAV_ICONS[key]}</svg>)
    end

    def authenticated? = session["auth"] == true

    # --- Polish: tema, health chip, banner de restart --------------

    def restart_needed? = self.class.restart_needed?

    # Preferência de tema lida do cookie (aplicada server-side em <html> → sem
    # flash). Allowlist estrita: valor inesperado cai em "auto".
    THEMES = %w[auto light dark].freeze
    def theme_pref
      value = request.cookies["harness.theme"].to_s
      THEMES.include?(value) ? value : "auto"
    end

    # Structured counts for the sidebar health card: [label, value]. Only what
    # the Studio already reads — no new ping. Persistence (durable/ephemeral)
    # comes from config, if boot supplied it (serve_real does; specs don't need).
    def health_parts
      parts = [["agents", harness[:profile_source].all.size]]
      parts << ["LLM providers", harness[:llm_provider_store].all.size] if harness[:llm_provider_store]
      parts << ["MCP servers", harness[:mcp_store].all.size] if harness[:mcp_store]
      persistence = harness[:config][:persistence]
      parts << ["persistence", persistence.to_s] if persistence && !persistence.to_s.empty?
      parts
    end

    # Só redireciona para um caminho LOCAL (evita open-redirect via `back`):
    # começa com "/", mas não "//" (protocol-relative) nem contém esquema.
    def safe_back(path)
      p = presence(path)
      return "/studio/agents" unless p&.start_with?("/")
      return "/studio/agents" if p.start_with?("//") || p.include?("://") || p.include?("\\")

      p
    end

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

    # 404 amigável a partir de qualquer ponto do roteamento (agente/sessão
    # inexistente). `throw :halt` com a resposta já montada (padrão Roda).
    def next_404
      response.status = 404
      response.write(view("not_found"))
      request.halt
    end

    # Roda captura segmentos de path com encoding ASCII-8BIT (binário). Os keys
    # do Store foram gravados em UTF-8; um `get` com string binária NÃO casa no
    # backend SQLite (bind como BLOB) e ainda gravaria uma chave-duplicata se
    # entrasse num payload de escrita. Normaliza no ÚNICO ponto onde o binário
    # nasce — a borda Roda — para que o core (agnóstico de framework) só veja
    # strings UTF-8. Os bytes vêm da URL já decodificada (UTF-8), então
    # force_encoding é correto, não uma reinterpretação.
    def utf8(str) = str.to_s.dup.force_encoding(Encoding::UTF_8)

    # Despacha um Command pelo bus (mesma superfície da API) e retorna o
    # resultado. `tenant` só é usado pela memória.
    def dispatch(type, payload, tenant: nil)
      harness[:command_bus].dispatch(
        Harness::Command.build(type, payload, transport: :studio, tenant: tenant)
      )
    end

    # Envolve um dispatch de escrita com flash de sucesso/erro e devolve o
    # resultado (ou nil em erro). Erros de domínio (Validation/NotFound) viram
    # flash vermelho — nunca 500 na cara do usuário.
    def with_flash(success)
      result = yield
      flash["notice"] = success
      result
    rescue Harness::ValidationError, Harness::NotFoundError => e
      flash["error"] = e.message
      nil
    end

    # --- Leitura de detalhe de agente ----------------------------------------

    def render_agent_detail
      id = @agent.id
      store = harness[:agent_file_store]
      @prompt_files = Array(@agent.prompt_files).map do |name|
        {
          name: name.to_s,
          content: store&.read(id, name).to_s,
          versions: store ? store.versions(id, name) : []
        }
      end
      @all_skills = harness[:skill_catalog]&.all || []
      @agent_skills = @agent.skills.nil? ? nil : Array(@agent.skills).map(&:to_s)
      mem = harness[:memory_store]
      @facts = mem ? mem.facts(tenant: id) : []
      @notes = mem ? mem.notes(tenant: id, limit: 20) : []
      @recent_sessions = recent_sessions
      view("agent_detail")
    end

    # Patch de config a partir do form (tipos nativos: memory bool, limits int).
    # Preserva os limits existentes, sobrescrevendo só os campos do form.
    def config_patch(r)
      limits = @agent.limits.dup
      { "turn_timeout" => "turn_timeout", "tool_timeout" => "tool_timeout" }.each_key do |field|
        v = presence(r.params[field])
        limits[field.to_sym] = Integer(v) if v
      end
      {
        id: @agent.id,
        model: presence(r.params["model"]) || @agent.model,
        provider: r.params["provider"].to_s,
        memory: r.params["memory"] == "1",
        limits: limits
      }
    end

    # --- Skills index --------------------------------------------------------

    def render_skills_index
      @skills = (harness[:skill_catalog]&.all || []).sort_by(&:name)
      @stored = harness[:skill_store] ? harness[:skill_store].names : []
      @agents = harness[:profile_source].all.sort_by(&:id)
      view("skills")
    end

    # Conteúdo bruto para o editor: preferir o store (SKILL.md real), senão
    # reconstruir a partir do que o catálogo parseou (edição de uma skill de
    # disco cria um override no store — Store vence).
    def skill_source(name)
      raw = harness[:skill_store]&.get(name)
      return raw if raw

      skill = harness[:skill_catalog]&.find(name)
      return new_skill_template(name) unless skill

      "---\nname: #{skill.name}\ndescription: #{skill.description}\n---\n\n#{skill.body}\n"
    end

    def new_skill_template(name = "my-skill")
      "---\nname: #{name}\ndescription: one sentence about when to use this skill\n---\n\n" \
        "# #{name}\n\nFull instructions, loaded on demand by the `load_skill` tool.\n"
    end

    # Uma skill está ativa para um agente se ele tem `skills` = nil (todas) ou a
    # lista inclui o nome. Usado para pré-marcar os checkboxes da matriz.
    def skill_enabled_for?(profile, skill_name)
      profile.skills.nil? || Array(profile.skills).map(&:to_s).include?(skill_name.to_s)
    end

    # --- Tools matrix --------------------------------------------------------

    def render_tools_matrix
      @tools = (harness[:tool_catalog]&.all || []).sort_by(&:name)
      # Nomes das tools POR DADOS (editáveis pela UI). O resto do catálogo são
      # tools de código (só allow/deny). Usado p/ marcar e linkar o editor.
      @data_tool_names = harness[:tool_store] ? harness[:tool_store].names : []
      @agents = harness[:profile_source].all.sort_by(&:id)
      view("tools")
    end

    # nil = todas; senão a lista. Pré-marca os checkboxes por agente.
    def tool_allowed_for?(profile, tool_name)
      profile.tools_allow.nil? || Array(profile.tools_allow).map(&:to_s).include?(tool_name.to_s)
    end

    # --- Autoria de tool por dados (Fase 5) ----------------------------------

    def render_tool_edit(name:, tool:)
      @tool_name = name
      @form = tool_form(tool)
      @versions = tool && harness[:tool_store] ? harness[:tool_store].versions(name) : []
      view("tool_edit")
    end

    # Definição (mascarada) -> Hash de campos-texto prontos pro form. tool=nil
    # (nova) -> defaults. Espelha env_lines/param_lines pra headers/query/params.
    def tool_form(tool)
      t = tool || {}
      req = t["request"] || {}
      resp = t["response"] || {}
      {
        name: t["name"].to_s, description: t["description"].to_s,
        method: req["method"] || "GET", url: req["url"].to_s,
        parameters: param_lines(t["parameters"]),
        query: env_lines(req["query"]), headers: env_lines(req["headers"]),
        secret_headers: Array(t["secret_headers"]).join(", "),
        body: req["body"].to_s,
        extract: resp["extract"] || "body_raw", path: resp["path"].to_s,
        timeout: t["timeout"]
      }
    end

    # Payload de :write_data_tool a partir do form. request/response aninhados;
    # headers/query como "chave=valor" por linha (mesmo idioma do env do MCP —
    # segredo mascarado volta como sentinel e é reconciliado no store).
    def tool_patch(r)
      {
        name: presence(r.params["name"]),
        description: r.params["description"].to_s,
        parameters: parse_param_lines(r.params["parameters"]),
        request: {
          method: presence(r.params["method"]) || "GET",
          url: r.params["url"].to_s,
          headers: parse_kv_lines(r.params["headers"]),
          query: parse_kv_lines(r.params["query"]),
          body: presence(r.params["body"])
        },
        response: {
          extract: presence(r.params["extract"]) || "body_raw",
          path: presence(r.params["path"])
        },
        secret_headers: split_list(r.params["secret_headers"]),
        timeout: presence(r.params["timeout"])
      }
    end

    # Parâmetros: uma linha por param, pipe-delimitada (CSP proíbe JS de
    # linhas dinâmicas; textarea é o caminho honesto, como o env do MCP):
    #   nome | tipo | required|optional | descrição
    def parse_param_lines(text)
      text.to_s.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        name, type, req, desc = line.split("|", 4).map(&:strip)
        next if name.to_s.empty?

        { "name" => name, "type" => (presence(type) || "string"),
          "required" => req.to_s.downcase != "optional", "description" => desc.to_s }
      end
    end

    # Inverso: params (do store) -> texto pro textarea. Aceita o array plano legado
    # E o JSON Schema (Fase 7): renderiza a visão de TOPO (aninhamento não cabe no
    # textarea plano — tools aninhadas são autoradas por manifesto, Etapa B).
    def param_lines(params)
      flat_params(params).map do |p|
        req = p["required"] == false ? "optional" : "required"
        "#{p['name']} | #{p['type']} | #{req} | #{p['description']}"
      end.join("\n")
    end

    # JSON Schema (Hash) OU array plano -> [{name,type,required,description}] de topo.
    def flat_params(params)
      if params.is_a?(Hash)
        props = params["properties"] || {}
        required = Array(params["required"]).map(&:to_s)
        props.map do |name, schema|
          schema ||= {}
          { "name" => name.to_s, "type" => (schema["type"] || "string").to_s,
            "required" => required.include?(name.to_s), "description" => schema["description"].to_s }
        end
      else
        Array(params)
      end
    end

    def tool_def_path(name) = "/studio/tools/def/#{Rack::Utils.escape(name.to_s)}"

    # --- Histórico -----------------------------------------------------------

    # Conversas recentes (todos os agentes — a Session não carimba o agente que
    # a produziu). Mais recentes primeiro, capadas.
    def recent_sessions(limit: 8)
      store = harness[:session_store]
      return [] unless store

      store.each_id.filter_map { |sid| store.find(sid) }
           .sort_by { |s| s.updated_at.to_s }.reverse.first(limit)
    end

    def session_preview(session)
      last = Array(session.messages).reverse.find { |m| %w[user assistant].include?(m["role"]) }
      last && last["content"].to_s
    end

    # --- Settings + LLM providers ----------------------------------

    def render_settings
      store = harness[:settings_store]
      @settings = store ? store.get : Harness::SettingsStore::DEFAULTS
      @providers = harness[:llm_provider_store] ? harness[:llm_provider_store].all : []
      view("settings")
    end

    # Patch de settings a partir do form. streaming/compaction são bool
    # (checkbox); os timeouts são inteiros; compaction.keep_last inteiro. Só o que
    # veio no form entra no patch (o resto e os defaults são preservados no store).
    def settings_patch(r)
      patch = {
        "streaming" => r.params["streaming"] == "1",
        "compaction" => {
          "enabled" => r.params["compaction_enabled"] == "1"
        }
      }
      { "request_timeout" => "request_timeout", "max_retries" => "max_retries",
        "turn_timeout" => "turn_timeout", "tool_timeout" => "tool_timeout" }.each_key do |f|
        v = presence(r.params[f])
        patch[f] = Integer(v) if v
      end
      kl = presence(r.params["keep_last"])
      patch["compaction"]["keep_last"] = Integer(kl) if kl
      patch
    end

    # Provider de LLM a partir do form. api_key é sentinel-aware: o form
    # pré-preenche com o sentinel quando já existe uma chave, então reenviar
    # sem tocar preserva; string nova substitui; "" limpa. models = CSV.
    def provider_patch(r)
      {
        api: presence(r.params["api"]),
        base_url: r.params["base_url"].to_s,
        auth_header: r.params["auth_header"].to_s,
        api_key: r.params["api_key"].to_s,
        models: split_list(r.params["models"])
      }
    end

    # --- MCP -------------------------------------------------------

    def render_mcp
      @instances = harness[:mcp_store] ? harness[:mcp_store].all : []
      view("mcp")
    end

    # Instância MCP a partir do form. `env` vem como linhas "CHAVE=valor" (CSP
    # proíbe JS inline pra add/remove linha; textarea é o caminho simples e
    # honesto). Os valores mascarados voltam como sentinel — mantê-los preserva
    # o segredo; trocar substitui; apagar a linha limpa.
    def mcp_patch(r)
      {
        name: presence(r.params["name"]),
        transport: presence(r.params["transport"]) || "stdio",
        command: r.params["command"].to_s,
        url: r.params["url"].to_s,
        description: r.params["description"].to_s,
        enabled: r.params["enabled"] == "1",
        env: parse_kv_lines(r.params["env"])
      }
    end

    # --- System-files ----------------------------------------------

    def render_system_files
      store = harness[:system_file_store]
      names = store ? store.list : []
      @system_files = names.map do |name|
        { name: name, content: store.read(name).to_s, versions: store.versions(name) }
      end
      view("system_files")
    end

    # --- Chats -----------------------------------------------------

    def render_chats
      @sessions = recent_sessions(limit: 100)
      view("chats")
    end

    # "CHAVE=valor" por linha -> Hash. Ignora linhas em branco e comentários (#).
    def parse_kv_lines(text)
      text.to_s.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        k, v = line.split("=", 2)
        k = k.to_s.strip
        next if k.empty?

        [k, v.to_s.strip]
      end.to_h
    end

    # CSV/whitespace -> [String] sem vazios.
    def split_list(str)
      str.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)
    end

    # --- Playground ----------------------------------------------------------

    # Despacha o send_message pelo MESMO bus da API (nada de escrita direta em
    # store). tenant = agente → a memória do turno é a do agente (paridade com a
    # página de memória). A UI observa o turno via SSE.
    def dispatch_send_message(agent:, session_id:, message:)
      dispatch(:send_message, { agent: agent, session_id: session_id, message: message }, tenant: agent)
    end

    # Cria uma sessão nova pelo bus (create_session gera o id) e devolve o id.
    def create_session
      dispatch(:create_session, { vars: { "canal" => "studio" } }).id
    end

    def playground_path(agent, session_id)
      query = "agent=#{Rack::Utils.escape(agent)}"
      query += "&session_id=#{Rack::Utils.escape(session_id)}" if session_id
      "/studio/playground?#{query}"
    end

    def agent_path(id, anchor = nil)
      base = "/studio/agents/#{Rack::Utils.escape(id)}"
      anchor ? "#{base}##{anchor}" : base
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

    # Sentinel de segredo mascarado (para pré-preencher campos de credencial nos
    # forms: reenviar sem tocar preserva o segredo real no store).
    def secret_sentinel = Harness::SecretMasking::SENTINEL

    # Env de uma instância MCP (já MASCARADO) -> texto "CHAVE=valor" por linha,
    # para o textarea. Ordena por chave (estável entre renders).
    def env_lines(env)
      (env || {}).sort.map { |k, v| "#{k}=#{v}" }.join("\n")
    end
  end
end
