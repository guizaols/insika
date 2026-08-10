# frozen_string_literal: true

require "roda"
require "digest"
require "securerandom"
require "rack/utils"
require "json"
require "time"
require "date"
require "yaml"
require_relative "forms"
require_relative "nav_icons"
# The live transcript's SSE body. Shared with the server on purpose: one wire format
# (Event#to_h) for the same EventStream, whichever door the client came through.
require_relative "../server/sse_body"

module Studio
  # Insika Studio — the server-rendered management UI, replacing
  # OpenClaw's agent-studio. FRAMEWORK AT THE EDGE: it's a separate
  # Roda app, mounted under `/studio`; `lib/insika` and `server/` do NOT gain
  # a Roda dependency. It talks to the runtime through the SAME surface as the API:
  # dispatches Commands on the CommandBus and READS profiles/stores — never writes to a store
  # directly (the transport's constitutional rule).
  #
  # SESSION/cookie auth: login compares the token in constant time against
  # `ADMIN_TOKEN`, sets an httpOnly SameSite=Lax cookie and protects `/studio/*`
  # fail-closed (no token configured → login never validates → studio inaccessible).
  # Replaces the manual `LocalAdminShim`/Bearer. CSRF on the POSTs.
  #
  # Same-origin assets: versioned esbuild bundle in `assets/dist/*`, served
  # by `/studio/assets/dist/*`. Strict `'self'` CSP (no `unsafe-inline`).
  class App < Roda
    include Forms     # form -> command-payload parsing (§11 B6)
    include NavIcons  # nav SVG helper (§11 B6)

    # The session cookie lives N days. 7 days = parity with the OpenClaw default.
    SESSION_MAX_AGE = 7 * 24 * 3600
    ASSETS_DIR = File.expand_path("assets/dist", __dir__)

    CONTENT_TYPES = {
      ".js" => "text/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".map" => "application/json; charset=utf-8",
      ".woff2" => "font/woff2", ".svg" => "image/svg+xml"
    }.freeze

    # Plugins that do NOT depend on the secret (loaded at class definition).
    plugin :render, views: File.expand_path("views", __dir__), engine: "erb",
                    layout: "layout", escape: true
    plugin :hash_branches
    plugin :h

    # Strict CSP: no `unsafe-inline`. Everything comes from the same-origin bundle in
    # /studio/assets/dist. `connect-src 'self'` covers the playground's EventSource
    # (SSE from /studio/events, same origin). `img-src data:` covers inline SVG/icons.
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
      # Runtime dependencies injected at boot (same surface as Server::App).
      attr_reader :insika

      # Studio wiring (called by the boot: serve_real / config.ru). Loads the
      # plugins that depend on the secret (sessions/csrf/flash) and stores the deps.
      # An explicit `session_secret` is for the specs; in production it derives from the
      # admin token (stable across restarts, without requiring one more env var).
      #
      # Besides the usual trio (command_bus/profile_source/config), the
      # Studio now READS authoring stores (agent_file/skill/tool/memory/session)
      # to render the pages. All optional (default nil): pages that
      # depend on a store degrade to an empty-state if it was not injected.
      def configure(command_bus:, profile_source:, event_stream:, config:,
                    agent_file_store: nil, skill_store: nil, skill_catalog: nil,
                    tool_catalog: nil, tool_store: nil, memory_store: nil, session_store: nil,
                    settings_store: nil, llm_provider_store: nil, mcp_store: nil,
                    system_file_store: nil, tool_trace_store: nil,
                    task_store: nil, checkpoint_store: nil, pending_action_store: nil,
                    refinement_store: nil, golden_store: nil, session_secret: nil)
        @insika = {
          command_bus: command_bus, profile_source: profile_source,
          event_stream: event_stream, config: config,
          agent_file_store: agent_file_store, skill_store: skill_store,
          skill_catalog: skill_catalog, tool_catalog: tool_catalog,
          # tool_store: DATA-DEFINED tool definitions (Phase 5). The catalog already
          # shows the data-tools in the matrix; the store feeds the authoring page.
          tool_store: tool_store,
          memory_store: memory_store, session_store: session_store,
          # runtime config (settings/LLM/MCP) + global system
          # files + conversations index. All optional (empty-state if nil).
          settings_store: settings_store, llm_provider_store: llm_provider_store,
          mcp_store: mcp_store, system_file_store: system_file_store,
          # per-session tool-call trace (debug): args + result + status per
          # turn, rendered in the session viewer (FOLLOWUP §3.1).
          tool_trace_store: tool_trace_store,
          # operate: tasks + human-in-the-loop approvals (§12 G5). Reads the
          # task/checkpoint/pending stores to render; controls (pause/resume/
          # cancel/approve) dispatch on the bus — parity with server/admin.
          task_store: task_store, checkpoint_store: checkpoint_store,
          pending_action_store: pending_action_store,
          # refinement runs (RFC-0013 phase A): the ranked failure report per agent.
          # Read-only here; the "Run" button dispatches :run_refinement on the bus.
          refinement_store: refinement_store,
          # eval cases (RFC-0008 §3.1): read to render; writes go through :write_golden.
          golden_store: golden_store
        }.freeze
        # "restart recommended" flag — in memory, PER PROCESS. A
        # config change that the runtime only re-reads at boot (e.g.: MCP instances are
        # wired at startup) lights the flag; restarting the process clears it
        # naturally (new process = `configure` runs again = flag reset).
        # Deliberately not put in the session: the session survives the restart (the secret
        # derives from the token) and the flag would stay stuck on.
        @restart_needed = false
        secret = session_secret || derive_secret(config[:admin_token])
        plugin :sessions, key: "insika.studio", secret: secret,
                          max_seconds: SESSION_MAX_AGE, same_site: :lax
        # CSRF token bound to the SESSION (not the method+path pair). route_csrf's
        # per-path binding uses `request.path` = POST-MOUNT PATH_INFO ("/login",
        # not "/studio/login"), which would confuse form-action × token under the
        # URLMap. Session-bound is safe for the single-tenant target.
        plugin :route_csrf, require_request_specific_tokens: false, csrf_failure: :empty_403
        plugin :flash
        self
      end

      # Deterministic per-deploy session secret (>=64 bytes required by Roda
      # sessions). Derives from the admin token → stable across restarts (the session
      # survives) without a new env var; change the token and all sessions drop.
      def derive_secret(admin_token)
        Digest::SHA512.hexdigest("insika-studio-session-v1:#{admin_token}")
      end

      # --- Restart recommended — per-process state -------------------
      def restart_needed? = @restart_needed == true
      def mark_restart_needed! = (@restart_needed = true)
      def clear_restart_needed! = (@restart_needed = false)
    end

    route do |r|
      response["x-content-type-options"] = "nosniff"
      response["referrer-policy"] = "same-origin"

      # Per-request CSP nonce. `style-src 'self'` alone blocks inline <style>, and
      # both CodeMirror (style-mod injects a <style> for its base theme + syntax
      # highlight) and Turbo (the progress-bar <style>) rely on one. Whitelisting a
      # per-response nonce lets exactly those styles load WITHOUT opening the policy to
      # 'unsafe-inline'. The editor passes the same nonce to CodeMirror via
      # EditorView.cspNonce, and Turbo reads it from <meta name="csp-nonce"> — both
      # sourced from the `csp_nonce` helper, so header and markup always agree.
      response.content_security_policy&.add_style_src([:nonce, csp_nonce])

      # Versioned assets: public (the UI loads the bundle BEFORE login).
      r.on "assets", "dist" do
        r.get String do |name|
          serve_asset(name)
        end
      end

      # Login: the only path without a session. GET shows the form; POST validates the
      # token in constant time and, if ok, marks the session and redirects.
      r.is "login" do
        r.get { view("login") }
        r.post do
          check_csrf!
          if authenticate(r.params["token"])
            session["auth"] = true
            r.redirect("/studio/agents")
          else
            @error = "Invalid token, or the studio is disabled (set ADMIN_TOKEN)."
            response.status = 401
            view("login")
          end
        end
      end

      # --- FAIL-CLOSED: from here down requires an authenticated session ----
      r.redirect("/studio/login") unless authenticated?

      r.post "logout" do
        check_csrf!
        clear_session
        r.redirect("/studio/login")
      end

      # Dismisses the "restart recommended" banner without restarting (the operator
      # acknowledges and moves on). A real restart clears the flag on its own.
      r.post "restart-ack" do
        check_csrf!
        self.class.clear_restart_needed!
        r.redirect(safe_back(r.params["back"]))
      end

      # GET /studio/events — the live transcript's SSE, on the STUDIO's own auth.
      # `EventSource` cannot send an Authorization header, so the browser used to read
      # the server's `/v1/events` directly — which is why that route had to stay open to
      # the world, streaming assistant text for any session to anyone who knew the URL.
      # Now the browser talks to the Studio (session cookie, already required above) and
      # `/v1` is machine-only, behind its Bearer. Same process, same EventStream, same
      # wire — only the door changed.
      r.get "events" do
        next_404 unless insika[:event_stream] # no stream wired: the feature is not there
        subscription = insika[:event_stream].subscribe(
          task_id: presence(r.params["task_id"]), session_id: presence(r.params["session_id"])
        )
        r.halt([200,
                { "content-type" => "text/event-stream", "cache-control" => "no-cache",
                  "x-accel-buffering" => "no" },
                Insika::Server::SSEBody.new(subscription: subscription)])
      end

      # `/studio` and `/studio/` → overview home.
      r.root { r.redirect("/studio/home") }

      # --- Overview: at-a-glance dashboard ---------------------
      r.on "home" do
        r.is { r.get { render_home } }
      end

      # --- Agents: list + detail/authoring ---------------------
      r.on "agents" do
        # /studio/agents — agents grid (reads the ProfileSource).
        r.is do
          r.get do
            @agents = insika[:profile_source].all.sort_by(&:id)
            view("agents")
          end

          # POST /studio/agents — creates an agent ("everyone creates
          # their own BIA"). Fires :create_agent; redirects to the new one's detail.
          r.post do
            check_csrf!
            id = presence(r.params["id"])
            result = with_flash("Agent '#{id}' created.") do
              dispatch(:create_agent, {
                         id: id, model: presence(r.params["model"]),
                         provider: presence(r.params["provider"]),
                         memory: r.params["memory"] == "1"
                       })
            end
            r.redirect(result ? agent_path(id) : "/studio/agents")
          end
        end

        # /studio/agents/:id — an agent's authoring page.
        r.on String do |id|
          id = utf8(id)
          @agent = insika[:profile_source].fetch(id)
          next_404 unless @agent

          # GET /studio/agents/:id — config + prompts + skills + memory + history.
          r.is do
            r.get { render_agent_detail }
          end

          # Config/model → :update_agent (patch merge).
          r.post "config" do
            check_csrf!
            with_flash("Configuration saved.") do
              dispatch(:update_agent, config_patch(r))
            end
            r.redirect(agent_path(id))
          end

          # Store-backed prompts. Writing also ensures the file
          # enters `prompt_files` — otherwise the Prompt provider wouldn't load it.
          # prompt_files is synced by the Commands themselves (write/delete
          # register/remove the file) — the Studio just dispatches the operation.
          r.on "prompts" do
            r.post "delete" do
              check_csrf!
              with_flash("Prompt removed.") do
                dispatch(:delete_agent_file, { agent_id: id, file: presence(r.params["file"]) })
              end
              r.redirect(agent_path(id))
            end

            r.post "restore" do
              check_csrf!
              with_flash("Version restored.") do
                dispatch(:restore_agent_file, {
                           agent_id: id, file: presence(r.params["file"]),
                           version: r.params["version"]
                         })
              end
              r.redirect(agent_path(id))
            end

            r.post do
              check_csrf!
              with_flash("Prompt saved.") do
                dispatch(:write_agent_file, {
                           agent_id: id, file: presence(r.params["file"]), content: r.params["content"].to_s
                         })
              end
              r.redirect(agent_path(id))
            end
          end

          # Agent skills → :update_agent with the `skills` allowlist.
          # "all" = nil; otherwise the checked subset (possibly []).
          r.post "skills" do
            check_csrf!
            skills = r.params["all_skills"] == "1" ? nil : Array(r.params["skills"]).map(&:to_s)
            with_flash("Skills updated.") do
              dispatch(:update_agent, { id: id, skills: skills })
            end
            r.redirect(agent_path(id))
          end

          # Agent memory. Scoped by tenant = agent id — the
          # SAME tenant the playground uses when chatting, so what is edited
          # here is what the BIA reads on the turn. Each agent, its own memory.
          r.on "memory" do
            r.post "fact" do
              check_csrf!
              with_flash("Fact saved.") do
                dispatch(:memory_put_fact, {
                           tenant: id, key: presence(r.params["key"]), value: r.params["value"].to_s
                         })
              end
              r.redirect(agent_path(id, "memory"))
            end
            r.post "forget" do
              check_csrf!
              with_flash("Fact forgotten.") do
                dispatch(:memory_forget_fact, { tenant: id, key: presence(r.params["key"]) })
              end
              r.redirect(agent_path(id, "memory"))
            end
            r.post "note" do
              check_csrf!
              with_flash("Note added.") do
                dispatch(:memory_add_note, { tenant: id, text: r.params["text"].to_s })
              end
              r.redirect(agent_path(id, "memory"))
            end
          end
        end
      end

      # --- Skills: catalog + agents matrix + editor ----------------
      r.on "skills" do
        r.is do
          r.get { render_skills_index }
          # POST /studio/skills → writes the skill (full SKILL.md) and reloads
          # the catalog (hot). Covers "new skill" and "save edit".
          r.post do
            check_csrf!
            name = presence(r.params["name"])
            with_flash("Skill saved.") do
              dispatch(:write_skill, { name: name, content: r.params["content"].to_s })
            end
            r.redirect(name ? "/studio/skills/#{Rack::Utils.escape(name)}" : "/studio/skills")
          end
        end

        # New skill editor (before the generic String matcher).
        r.get "new" do
          load_skills_master
          @selected = ""
          @skill_content = new_skill_template
          view("skills")
        end

        r.on String do |name|
          name = utf8(name)
          # GET /studio/skills/:name — drill with this skill open in the detail.
          r.is do
            r.get do
              load_skills_master
              @selected = name
              @skill_content = skill_source(name)
              view("skills")
            end
          end
          # Enables/disables the skill on N agents at once.
          r.post "agents" do
            check_csrf!
            agent_ids = Array(r.params["agent_ids"]).map(&:to_s)
            result = with_flash("Skill's agents updated.") do
              dispatch(:set_skill_agents, { name: name, agent_ids: agent_ids })
            end
            skipped = Array(result && result[:skipped_all])
            if skipped.any?
              flash["notice"] = "#{flash['notice']} — #{skipped.size} agent(s) with 'all' skills were left intact."
            end
            r.redirect("/studio/skills")
          end
        end
      end

      # --- Tools: tool × agent matrix + DATA-DEFINED tool authoring -----------
      r.on "tools" do
        # Data-defined tool authoring (Phase 5). Under /tools/def/* — BEFORE the
        # generic `r.post String` matcher (which is the allow/deny matrix per agent :id).
        r.on "def" do
          # /studio/tools/def/new — empty editor.
          r.get "new" do
            render_tool_edit(name: "", tool: nil)
          end

          # POST /studio/tools/def — creates (create_only: refuses to overwrite).
          r.is do
            r.post do
              check_csrf!
              name = presence(r.params["name"])
              result = with_flash("Tool '#{name}' created.") do
                dispatch(:write_data_tool, tool_patch(r).merge(create_only: true))
              end
              r.redirect(result ? tool_def_path(name) : "/studio/tools")
            end
          end

          r.on String do |name|
            name = utf8(name)
            # GET /studio/tools/def/:name — loaded editor (secret masked).
            r.is do
              r.get do
                tool = insika[:tool_store]&.get(name)
                next_404 unless tool
                render_tool_edit(name: name, tool: tool)
              end
              # POST /studio/tools/def/:name — updates (upsert).
              r.post do
                check_csrf!
                # The stored definition rides along so the fields this form does not
                # render (group/tags/halt_when) survive the save — see UNEDITED_TOOL_FIELDS.
                stored = insika[:tool_store]&.get(name)
                with_flash("Tool '#{name}' saved.") { dispatch(:write_data_tool, tool_patch(r, stored)) }
                r.redirect(tool_def_path(name))
              end
            end
            r.post "delete" do
              check_csrf!
              with_flash("Tool '#{name}' removed.") { dispatch(:delete_data_tool, { name: name }) }
              r.redirect("/studio/tools")
            end
            r.post "restore" do
              check_csrf!
              with_flash("Version restored.") do
                dispatch(:restore_data_tool, { name: name, index: r.params["index"] })
              end
              r.redirect(tool_def_path(name))
            end
          end
        end

        r.is { r.get { render_tools_matrix } }

        # POST /studio/tools/:id — writes an agent's tools allowlist.
        # "all" = nil; otherwise the checked subset. `deny` is preserved.
        r.post String do |id|
          check_csrf!
          id = utf8(id)
          profile = insika[:profile_source].fetch(id)
          next_404 unless profile
          allow = r.params["all_tools"] == "1" ? nil : Array(r.params["tools"]).map(&:to_s)
          with_flash("Agent '#{id}' tools updated.") do
            dispatch(:set_agent_tools, { id: id, allow: allow, deny: Array(profile.tools_deny) })
          end
          r.redirect("/studio/tools?a=#{Rack::Utils.escape(id)}")
        end
      end

      # --- General settings + LLM providers ------------------------
      r.on "settings" do
        r.is do
          r.get { render_settings }
          # General settings (streaming/timeouts/compaction) → :update_settings.
          r.post do
            check_csrf!
            with_flash("Settings saved.") do
              dispatch(:update_settings, { patch: settings_patch(r) })
            end
            r.redirect("/studio/settings")
          end
        end

        # Platform model defaults (sub-resource, v2 §10): its own form/route so a
        # general-settings save never clobbers the model layer.
        r.post "models" do
          check_csrf!
          with_flash("Model defaults saved.") do
            dispatch(:update_settings, { patch: model_defaults_patch(r) })
          end
          r.redirect("/studio/settings?s=models")
        end

        # Per-model reasoning defaults (§10, the per-model layer): its own form so a
        # model-defaults save never clobbers the per-model map, and vice-versa.
        r.post "model-params" do
          check_csrf!
          with_flash("Per-model params saved.") do
            dispatch(:update_settings, { patch: model_params_patch(r) })
          end
          r.redirect("/studio/settings?s=models")
        end

        # Edge limits (item 33 / §12 G7): the platform rate-limit/cost layer.
        # Its own form for the same reason as models — saves never cross-clobber.
        r.post "edge" do
          check_csrf!
          with_flash("Edge limits saved.") do
            dispatch(:update_settings, { patch: edge_patch(r) })
          end
          r.redirect("/studio/settings?s=edge")
        end

        # Evals (RFC-0008 / RFC-0013 §3.9): the judge PANEL and how it agrees. Its own
        # form, like models and edge — a save here must not clobber those.
        r.post "evals" do
          check_csrf!
          with_flash("Evals settings saved.") do
            dispatch(:update_settings, { patch: evals_patch(r) })
          end
          r.redirect("/studio/settings?s=evals")
        end

        # LLM providers (sub-resource): CRUD with masked api_key (sentinel).
        r.on "providers" do
          r.post "delete" do
            check_csrf!
            with_flash("Provider removed.") do
              dispatch(:delete_llm_provider, { api: presence(r.params["api"]) })
            end
            r.redirect("/studio/settings?s=llm")
          end
          r.post do
            check_csrf!
            with_flash("Provider saved.") do
              dispatch(:upsert_llm_provider, provider_patch(r))
            end
            r.redirect("/studio/settings?s=llm")
          end
        end
      end

      # --- MCP: instances with masked credentials ------------------
      r.on "mcp" do
        r.is do
          r.get { render_mcp }
          r.post do
            check_csrf!
            with_flash("MCP instance saved.") do
              dispatch(:upsert_mcp, mcp_patch(r))
              # MCP servers are wired at runtime boot; the new instance
              # only takes effect after a restart. Lights the "restart" banner.
              self.class.mark_restart_needed!
            end
            r.redirect("/studio/mcp")
          end
        end
        r.post "delete" do
          check_csrf!
          with_flash("MCP instance removed.") do
            dispatch(:delete_mcp, { name: presence(r.params["name"]) })
            self.class.mark_restart_needed!
          end
          r.redirect("/studio/mcp")
        end
      end

      # --- Global system files -------------------------------------
      # Apply to ALL agents (the Prompt provider injects them before the
      # individual identity). Code-editor + versions, like the prompts.
      r.on "system-files" do
        r.is do
          r.get { render_system_files }
          r.post do
            check_csrf!
            with_flash("System file saved.") do
              dispatch(:write_system_file, {
                         file: presence(r.params["file"]), content: r.params["content"].to_s
                       })
            end
            r.redirect("/studio/system-files")
          end
        end
        r.post "delete" do
          check_csrf!
          with_flash("File removed.") do
            dispatch(:delete_system_file, { file: presence(r.params["file"]) })
          end
          r.redirect("/studio/system-files")
        end
        r.post "restore" do
          check_csrf!
          with_flash("Version restored.") do
            dispatch(:restore_system_file, {
                       file: presence(r.params["file"]), version: r.params["version"]
                     })
          end
          r.redirect("/studio/system-files")
        end
      end

      # --- Chats: conversations index ------------------------------
      # Read-only: lists sessions and links to the existing viewer (/sessions/:id).
      r.on "chats" do
        r.is { r.get { render_chats } }
      end

      # --- History: read-only viewer of a session ------------------
      r.on "sessions" do
        r.on String do |sid|
          sid = utf8(sid)
          r.get do
            @session = insika[:session_store]&.find(sid)
            next_404 unless @session

            # Session's tool-call trace (debug): grouped by turn in the view.
            @tool_traces = (insika[:tool_trace_store]&.for_session(sid) || [])
                           .group_by { |t| t["turn"] }
            view("session")
          end
        end
      end

      # --- Tasks: list + detail + operator controls (§12 G5) -------
      # Parity with server/admin: READS the task/checkpoint/pending stores to
      # render; pause/resume/cancel dispatch Commands on the bus (never a direct
      # store write). Every control audits the ATTEMPT to the EventStream first.
      r.on "tasks" do
        r.is { r.get { render_tasks } }

        r.on String do |id|
          id = utf8(id)
          r.get do
            @task = insika[:task_store]&.find(id)
            next_404 unless @task

            render_task_detail(id)
          end

          r.post "pause" do
            check_csrf!
            control_action(:pause_task, { task_id: id }, ok: "Task paused.")
            r.redirect(task_path(id))
          end
          r.post "resume" do
            check_csrf!
            control_action(:resume_task, { task_id: id }, ok: "Task resumed.")
            r.redirect(task_path(id))
          end
          r.post "cancel" do
            check_csrf!
            control_action(:cancel_task, { task_id: id }, ok: "Task cancelled.")
            r.redirect(task_path(id))
          end
        end
      end

      # --- Approvals: human-in-the-loop inbox (§12 G5) -------------
      # Lists every :pending action across tasks; resolving one dispatches
      # :approve_action, which resolves the store AND wakes the suspended turn.
      r.on "approvals" do
        r.is { r.get { render_approvals } }

        r.on String do |pid|
          pid = utf8(pid)
          r.post do
            check_csrf!
            decision = r.params["decision"] == "rejected" ? "rejected" : "approved"
            control_action(:approve_action,
                           { pending_id: pid, decision: decision, operator: operator_label },
                           ok: "Approval #{decision}.")
            r.redirect(safe_back(r.params["back"], default: "/studio/approvals"))
          end
        end
      end

# --- Evals: the cases that grade an agent (RFC-0008 §3.1) -------
# A case is DATA in the same YAML shape the corpus files use, so what an operator
# edits here is what a pull request would review. The one loader validates it, on
# the way in — a malformed case is a red flash, never a silently skipped test.
r.on "evals" do
  r.is do
    r.get { render_evals }
    r.post do
      check_csrf!
      with_flash("Case saved.") { dispatch(:write_golden, golden_patch(r)) }
      r.redirect("/studio/evals?id=#{Rack::Utils.escape(presence(r.params['id']).to_s)}")
    end
  end

  r.on String do |id|
    id = utf8(id)
    r.post "delete" do
      check_csrf!
      with_flash("Case removed.") { dispatch(:delete_golden, { id: id }) }
      r.redirect("/studio/evals")
    end
  end
end

      # --- Refinement: what broke in real traffic, and what to do about it --
      # `POST /refinement` runs the report (RFC-0013 phase A). `POST
      # /refinement/propose` is phase C: the configured model writes a candidate from
      # the findings and the gate scores it by replaying the golden set. `POST
      # /refinement/resolve` is a human approving or rejecting what the gate passed.
      # All three go through the bus like every other Studio write — this page reads
      # stores and dispatches Commands, nothing else.
      #
      # There is still no form to hand-AUTHOR a candidate: a JSON textarea would be a
      # worse way to say what the API already says, and the button below is what an
      # operator actually wants standing there.
      r.on "refinement" do
        r.is do
          r.get { render_refinement }
          r.post do
            check_csrf!
            agent = presence(r.params["agent"])
            payload = { agent: agent, full: r.params["full"] == "1" }
            control_action(:run_refinement, payload, ok: "Refinement run finished.")
            r.redirect("/studio/refinement?agent=#{Rack::Utils.escape(agent.to_s)}")
          end
        end

        # Propose + gate in one press, because they are one decision for the operator
        # ("try to fix this") and splitting them would park a run holding an unscored
        # candidate — a state nobody can act on. Slow on purpose: the gate replays the
        # golden set, so this returns when the answer is real.
        r.post "propose" do
          check_csrf!
          agent = presence(r.params["agent"])
          payload = { run_id: presence(r.params["run_id"]), propose: true }
          control_action(:gate_refinement, payload, ok: "Proposal gated — see the result below.")
          r.redirect("/studio/refinement?agent=#{Rack::Utils.escape(agent.to_s)}")
        end

        r.post "resolve" do
          check_csrf!
          agent = presence(r.params["agent"])
          decision = presence(r.params["decision"])
          payload = { run_id: presence(r.params["run_id"]), decision: decision,
                      operator: "studio", note: presence(r.params["note"]) }.compact
          ok = decision == "approved" ? "Applied — the agent's files were updated." : "Proposal rejected."
          control_action(:resolve_refinement, payload, ok: ok)
          r.redirect("/studio/refinement?agent=#{Rack::Utils.escape(agent.to_s)}")
        end
      end

      # Playground: sends `send_message` (the SAME Command as the API) and streams the
      # response live through the `live-transcript` island (SSE from /studio/events).
      r.on "playground" do
        r.get do
          @agent = presence(r.params["agent"]) || default_agent
          @session_id = presence(r.params["session_id"])
          @agents = insika[:profile_source].ids.sort
          # Server-side echo + continuity (§11 A1): render the session's persisted
          # transcript as bubbles. The user's message is only persisted at the END
          # of the turn, so the just-sent message rides a one-shot flash bubble
          # (@sent_message) until it lands in history — an optimistic JS echo can't
          # work here (POST→redirect wipes the DOM).
          @history = @session_id ? Array(insika[:session_store]&.find(@session_id)&.messages) : []
          @sent_message = flash["sent_message"]
          view("playground")
        end
        r.post do
          check_csrf!
          agent = presence(r.params["agent"]) || default_agent
          typed_session = presence(r.params["session_id"])
          message = r.params["message"].to_s
          # Blank session = new conversation: created via Command (create_session
          # generates the id — the Studio doesn't write to the store directly). A typed id
          # continues an existing conversation (send_message requires it to exist).
          # The per-chat model pin (v2, §10) is set at creation and rides the whole
          # conversation, so it only applies to a NEW session — an existing one keeps
          # whatever it was pinned to.
          session_id = typed_session ||
                       create_session(model: presence(r.params["model"]),
                                      provider: presence(r.params["provider"]),
                                      thinking: presence(r.params["thinking"]))
          dispatch_send_message(agent: agent, session_id: session_id, message: message)
          # Optimistic echo of the just-sent message (§11 A1): survives the redirect
          # as a one-shot flash, rendered as a user bubble on the next GET.
          flash["sent_message"] = message unless message.empty?
          r.redirect(playground_path(agent, session_id))
        rescue Insika::ValidationError, Insika::NotFoundError => e
          flash["error"] = e.message
          r.redirect(playground_path(agent, typed_session))
        end
      end

      # Unknown authenticated route → friendly 404 (not Roda's empty body).
      response.status = 404
      view("not_found")
    end

    private

    # --- Helpers (instance scope; available inside the views) ----------------

    def insika = self.class.insika

    # Sidebar navigation, grouped by operator intent (build / runtime /
    # operate). Each item: [label, href, icon-key]. The view marks the active item
    # by comparing the path and renders the icon via `nav_icon`.
    def nav_sections
      [
        ["", [
          ["Home", "/studio/home", :home]
        ]],
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
          ["Playground", "/studio/playground", :playground],
          ["Tasks", "/studio/tasks", :tasks],
          ["Approvals", "/studio/approvals", :approvals],
          ["Refinement", "/studio/refinement", :refinement],
          ["Evals", "/studio/evals", :evals]
        ]]
      ]
    end

    # NAV_ICONS + nav_icon moved to Studio::NavIcons (§11 B6).

    def authenticated? = session["auth"] == true

    # Is the given nav href the current page? Robust to whether request.path
    # carries the "/studio" mount prefix (it does under serve_real/config.ru, it
    # doesn't in specs) — strip it from both sides, then exact- or prefix-match
    # so detail routes (/agents/:id) still light up their section.
    def nav_active?(href)
      target = href.sub(%r{\A/studio}, "")
      path = request.path.sub(%r{\A/studio}, "")
      path == target || path.start_with?("#{target}/")
    end

    # CSP nonce for inline styles (CodeMirror's injected theme). Stable PER SESSION,
    # not per request: the browser enforces the CSP from the initial document load
    # for the whole SPA session, but Turbo Drive fetches later pages carrying their
    # OWN nonce in the <meta>. A per-request nonce would therefore never match what
    # the browser enforces after a Turbo navigation, so CodeMirror's <style> gets
    # blocked and the editor renders unstyled/broken until a full reload. A
    # session-lifetime nonce keeps the meta constant across Turbo visits (matches the
    # enforced value) while still being unguessable and per-user — the standard
    # Turbo+CSP reconciliation. Scripts stay 'self' (no nonce), so this only governs
    # styles. Memoized on the request instance so header and <meta> agree.
    def csp_nonce = (@csp_nonce ||= (session["csp_nonce"] ||= SecureRandom.base64(16)))

    # --- Polish: theme, health chip, restart banner ----------------

    def restart_needed? = self.class.restart_needed?

    # Environment label for the sidebar identity chip — reflects the REAL runtime
    # env (INSIKA_ENV → RACK_ENV → "local") so an operator always knows which box
    # they are looking at. No new state; just reads the process env.
    def env_label = (presence(Insika::EnvSchema.read("INSIKA_ENV")) || presence(ENV["RACK_ENV"]) || "local").to_s

    # Theme preference read from the cookie (applied server-side on <html> → no
    # flash). Strict allowlist: an unexpected value falls back to "auto".
    THEMES = %w[auto light dark].freeze
    def theme_pref
      value = request.cookies["insika.theme"].to_s
      THEMES.include?(value) ? value : "auto"
    end

    # Structured counts for the sidebar health card: [label, value]. Only what
    # the Studio already reads — no new ping. Persistence (durable/ephemeral)
    # comes from config, if boot supplied it (serve_real does; specs don't need).
    def health_parts
      parts = [["agents", insika[:profile_source].all.size]]
      parts << ["LLM providers", insika[:llm_provider_store].all.size] if insika[:llm_provider_store]
      parts << ["MCP servers", insika[:mcp_store].all.size] if insika[:mcp_store]
      persistence = insika[:config][:persistence]
      parts << ["persistence", persistence.to_s] if persistence && !persistence.to_s.empty?
      parts
    end

    # Only redirects to a LOCAL path (avoids open-redirect via `back`):
    # starts with "/", but not "//" (protocol-relative) nor contains a scheme.
    def safe_back(path, default: "/studio/agents")
      p = presence(path)
      return default unless p&.start_with?("/")
      return default if p.start_with?("//") || p.include?("://") || p.include?("\\")

      p
    end

    # Fail-closed BY CONSTRUCTION (AdminAuth parity): with no token configured, the
    # compare never passes → studio inaccessible. Constant-time comparison.
    def authenticate(provided)
      configured = insika[:config][:admin_token].to_s
      provided = provided.to_s
      return false if configured.empty? || provided.empty?

      Rack::Utils.secure_compare(configured, provided)
    end

    def default_agent
      ids = insika[:profile_source].ids
      ids.include?("bia") ? "bia" : (ids.first || "bia")
    end

    # --- Transcript display helpers (playground + session viewer) ------------

    # A stored message's content for display: strings as-is; structured payloads
    # as pretty JSON. NEVER Ruby #inspect (session.erb:45 leaked hashrockets to the
    # operator). §11 A2.
    def message_content(content)
      return content.to_s if content.is_a?(String)

      JSON.pretty_generate(content)
    rescue StandardError
      content.to_s
    end

    # ISO8601 → "HH:MM" for a transcript timestamp; "" when unparseable/absent.
    def short_time(iso)
      Time.parse(iso.to_s).strftime("%H:%M")
    rescue StandardError
      ""
    end

    # Friendly 404 from any point in the routing (missing agent/session).
    # `throw :halt` with the response already assembled (Roda pattern).
    def next_404
      response.status = 404
      response.write(view("not_found"))
      request.halt
    end

    # Roda captures path segments with ASCII-8BIT (binary) encoding. The Store
    # keys were written in UTF-8; a `get` with a binary string does NOT match in the
    # SQLite backend (binds as BLOB) and would even write a duplicate key if it
    # entered a write payload. Normalizes at the ONLY point where the binary
    # is born — the Roda edge — so the core (framework-agnostic) only sees
    # UTF-8 strings. The bytes come from the already-decoded URL (UTF-8), so
    # force_encoding is correct, not a reinterpretation.
    def utf8(str) = Insika::Coercion.utf8(str)

    # Dispatches a Command through the bus (same surface as the API) and returns the
    # result. `tenant` is only used by memory.
    def dispatch(type, payload, tenant: nil)
      insika[:command_bus].dispatch(
        Insika::Command.build(type, payload, transport: :studio, tenant: tenant)
      )
    end

    # Wraps a write dispatch with a success/error flash and returns the
    # result (or nil on error). Domain errors (Validation/NotFound) become a
    # red flash — never a 500 in the user's face.
    def with_flash(success)
      result = yield
      flash["notice"] = success
      result
    rescue Insika::ValidationError, Insika::NotFoundError => e
      flash["error"] = e.message
      nil
    end

    # --- Agent detail read ---------------------------------------------------

    def render_agent_detail
      id = @agent.id
      store = insika[:agent_file_store]
      @prompt_files = Array(@agent.prompt_files).map do |name|
        {
          name: name.to_s,
          content: store&.read(id, name).to_s,
          versions: store ? store.versions(id, name) : []
        }
      end
      @all_skills = insika[:skill_catalog]&.all || []
      @agent_skills = @agent.skills.nil? ? nil : Array(@agent.skills).map(&:to_s)
      # v2 (§10) config surfaces: generation params + model fence. AgentProfile.build
      # string-keys these hashes, so the form helpers read plain string keys.
      @params = @agent.params
      @model_policy_allow = model_policy_allow(@agent)
      # guardrails config (RFC-0009); nil when the agent never configured any.
      @guardrails = @agent.guardrails || {}
      mem = insika[:memory_store]
      @facts = mem ? mem.facts(tenant: id) : []
      @notes = mem ? mem.notes(tenant: id, limit: 20) : []
      @recent_sessions = recent_sessions
      view("agent_detail")
    end

    # A generation param off the profile (string-keyed by AgentProfile.build). Used
    # to pre-fill the config form (empty string when absent).
    def agent_param(params, key)
      return "" unless params.is_a?(Hash)

      params[key.to_s].nil? ? "" : params[key.to_s]
    end

    # Renders the reasoning <select> shared by the agent config, settings and
    # playground (§10, 4-layer). `blank_label` names the empty option — the
    # "inherit the broader layer" / provider-default choice. Values come from a
    # fixed constant (safe to emit); `current` is only compared, never output.
    def thinking_select(name, current, blank_label)
      cur = current.to_s
      options = [["", blank_label]] + Insika::ModelSelection::THINKING_LEVELS.map { |v| [v, v] }
      rows = options.map do |value, label|
        %(<option value="#{value}"#{' selected' if value == cur}>#{label}</option>)
      end.join
      %(<select name="#{name}">#{rows}</select>)
    end

    # Renders the per-model reasoning map ({ "ref" => { "thinking" => v } }) back to
    # the textarea lines "ref | thinking" that model_params_patch parses. Only refs
    # with a set thinking are shown (blank ones are inherit no-ops).
    def model_params_text(map)
      return "" unless map.is_a?(Hash)

      map.filter_map do |ref, cfg|
        t = cfg.is_a?(Hash) ? cfg["thinking"] : nil
        "#{ref} | #{t}" if t
      end.join("\n")
    end

    # A guardrails field off the profile (string-keyed by AgentProfile.build).
    # `default` is returned when the whole config or the key is absent (so a
    # never-configured agent shows the conservative defaults in the form).
    def guardrail_field(gr, key, default)
      return default unless gr.is_a?(Hash)

      gr[key.to_s].nil? ? default : gr[key.to_s]
    end

    # The agent's model fence as newline-joined refs (for the textarea). nil / no
    # allow list -> "" (no fence).
    def model_policy_allow(agent)
      policy = agent.model_policy
      return "" unless policy.is_a?(Hash)

      Array(policy["allow"]).join("\n")
    end

    # Config patch from the form (native types: memory bool, limits int).
    # Preserves the existing limits, overwriting only the form's fields.
    # `model` is OPTIONAL as of v2 (§10): blank clears it, so the agent inherits
    # the platform `default_model` via the ModelResolver — the config form is the
    # place that surfaces that layering. params/model_policy: see the helpers below.
    # config_patch/guardrails_patch/guardrail_responses_patch/params_patch/
    # model_policy_patch/coerce moved to Studio::Forms (§11 B6).

    # --- Skills index --------------------------------------------------------

    # Master data for the Skills drill-down (list + authored badges + agents),
    # shared by every skill route so the master pane always renders. @selected
    # drives the detail pane (nil = none, "" = new, name = edit).
    def load_skills_master
      @skills = (insika[:skill_catalog]&.all || []).sort_by(&:name)
      @stored = insika[:skill_store] ? insika[:skill_store].names : []
      @agents = insika[:profile_source].all.sort_by(&:id)
    end

    def render_skills_index
      load_skills_master
      # Auto-open the first skill (drill-down convention) so the detail pane is
      # useful on landing; the empty state only shows with an empty catalog.
      @selected = @skills.first&.name
      @skill_content = @selected ? skill_source(@selected) : nil
      view("skills")
    end

    # Raw content for the editor: prefer the store (real SKILL.md), otherwise
    # reconstruct from what the catalog parsed (editing a disk skill
    # creates an override in the store — Store wins).
    def skill_source(name)
      raw = insika[:skill_store]&.get(name)
      return raw if raw

      skill = insika[:skill_catalog]&.find(name)
      return new_skill_template(name) unless skill

      "---\nname: #{skill.name}\ndescription: #{skill.description}\n---\n\n#{skill.body}\n"
    end

    def new_skill_template(name = "my-skill")
      "---\nname: #{name}\ndescription: one sentence about when to use this skill\n---\n\n" \
        "# #{name}\n\nFull instructions, loaded on demand by the `load_skill` tool.\n"
    end

    # A skill is active for an agent if it has `skills` = nil (all) or the
    # list includes the name. Used to pre-check the matrix checkboxes.
    def skill_enabled_for?(profile, skill_name)
      profile.skills.nil? || Array(profile.skills).map(&:to_s).include?(skill_name.to_s)
    end

    # --- Tools matrix --------------------------------------------------------

    def render_tools_matrix
      @tools = (insika[:tool_catalog]&.all || []).sort_by(&:name)
      # Names of the DATA-DEFINED tools (editable via the UI). The rest of the catalog are
      # code tools (allow/deny only). Used to mark and link the editor.
      @data_tool_names = insika[:tool_store] ? insika[:tool_store].names : []
      # Stored but NOT in the catalog = the overlay refused the definition and dropped it
      # (only a stderr warn otherwise). The pane still links its editor, so the panel is
      # where you see it and where you fix it. `insika doctor` reports the same set.
      @dropped_tool_names = @data_tool_names - @tools.map(&:name)
      @agents = insika[:profile_source].all.sort_by(&:id)
      # Drill-down: ?a= selects the agent whose allow/deny matrix fills the detail;
      # default to the first agent so the pane is useful on landing.
      sel = request.params["a"]
      @sel_agent = (sel && @agents.find { |a| a.id == sel }) || @agents.first
      view("tools")
    end

    # nil = all; otherwise the list. Pre-checks the checkboxes per agent.
    def tool_allowed_for?(profile, tool_name)
      profile.tools_allow.nil? || Array(profile.tools_allow).map(&:to_s).include?(tool_name.to_s)
    end

    # A tool the agent explicitly denies. Deny ALWAYS wins over allow, so the matrix
    # renders these "locked" (disabled) — you can't grant a denied tool from here.
    def tool_denied_for?(profile, tool_name)
      Array(profile.tools_deny).map(&:to_s).include?(tool_name.to_s)
    end

    # `checked/total on` for an agent's tool group (open allowlist -> total). Feeds
    # the initial server-rendered counter; the toggle-counter island keeps it live.
    def tools_on_count(profile, tools)
      total = tools.size
      return total if profile.tools_allow.nil?

      allow = Array(profile.tools_allow).map(&:to_s)
      tools.count { |t| allow.include?(t.name.to_s) && !tool_denied_for?(profile, t.name) }
    end

    # --- Data-defined tool authoring (Phase 5) -------------------------------

    def render_tool_edit(name:, tool:)
      @tool_name = name
      @form = tool_form(tool)
      @versions = tool && insika[:tool_store] ? insika[:tool_store].versions(name) : []
      view("tool_edit")
    end

    # Definition (masked) -> Hash of text fields ready for the form. tool=nil
    # (new) -> defaults. Mirrors env_lines/param_lines for headers/query/params.
    def tool_form(tool)
      t = tool || {}
      req = t["request"] || {}
      resp = t["response"] || {}
      {
        name: t["name"].to_s, description: t["description"].to_s,
        method: req["method"] || "GET", url: req["url"].to_s,
        parameters: params_text(t["parameters"]),
        query: env_lines(req["query"]), headers: env_lines(req["headers"]),
        secret_headers: Array(t["secret_headers"]).join(", "),
        body: req["body"].to_s,
        extract: resp["extract"] || "body_raw", path: resp["path"].to_s,
        timeout: t["timeout"]
      }
    end

    # tool_patch/parse_parameters moved to Studio::Forms (§11 B6).

    # Inverse of parse_parameters: the stored params -> text for the textarea. A schema
    # the flat sugar can express round-trips as pipe lines (the friendly form); anything
    # NESTED renders as JSON Schema — the same text the form parses back, so opening and
    # saving a nested tool is a no-op instead of a silent flattening.
    def params_text(params)
      return param_lines(params) if flat_sugar?(params)

      JSON.pretty_generate(params)
    end

    def param_lines(params)
      flat_params(params).map do |p|
        req = p["required"] == false ? "optional" : "required"
        "#{p['name']} | #{p['type']} | #{req} | #{p['description']}"
      end.join("\n")
    end

    # JSON Schema (Hash) OR flat array -> top-level [{name,type,required,description}].
    # An array property renders with its item type (`array:string`) — the spelling the
    # sugar accepts back. A legacy record with a bare `array` renders as `array:string`
    # too: that IS what it meant, now written down (see ToolDefinition.flat_property).
    def flat_params(params)
      if params.is_a?(Hash)
        props = params["properties"] || {}
        required = Array(params["required"]).map(&:to_s)
        props.map do |name, schema|
          schema ||= {}
          { "name" => name.to_s, "type" => flat_type(schema),
            "required" => required.include?(name.to_s), "description" => schema["description"].to_s }
        end
      else
        Array(params).map { |p| p.is_a?(Hash) ? p.merge("type" => flat_type_from_legacy(p)) : p }
      end
    end

    # Can the flat textarea express this schema without losing anything? Only if every
    # top-level property is a scalar (or a list of scalars) and carries no keyword the
    # sugar cannot write back (nested properties, enum, minItems…).
    def flat_sugar?(params)
      return true unless params.is_a?(Hash)
      return false unless (params.keys - %w[type properties required]).empty?

      (params["properties"] || {}).all? { |_, schema| flat_sugar_property?(schema) }
    end

    def flat_sugar_property?(schema)
      return false unless schema.is_a?(Hash)
      return false unless (schema.keys - %w[type description items]).empty?

      type = schema["type"].to_s
      return Insika::ToolDefinition::PARAM_TYPES.include?(type) unless type == "array"

      items = schema["items"]
      items.is_a?(Hash) && items.keys == ["type"] &&
        Insika::ToolDefinition::PARAM_TYPES.include?(items["type"].to_s)
    end

    def flat_type(schema)
      type = (schema["type"] || "string").to_s
      return type unless type == "array"

      "array:#{schema.dig('items', 'type') || 'string'}"
    end

    def flat_type_from_legacy(param)
      type = (param["type"] || "string").to_s
      type == "array" ? "array:string" : type
    end

    def tool_def_path(name) = "/studio/tools/def/#{Rack::Utils.escape(name.to_s)}"

    # --- Overview / home ------------------------------------------------------

    # At-a-glance dashboard: counts + activity + recent conversations. All from
    # data the Studio already reads (one scan of the session store); no new
    # metrics pipeline. `active_now` = sessions touched in the last 5 minutes.
    def render_home
      ps = insika[:profile_source]
      sessions = all_sessions
      @counts = {
        "conversations" => sessions.size,
        "messages" => sessions.sum { |s| Array(s.messages).size },
        "agents" => ps ? ps.all.size : 0,
        "skills" => insika[:skill_catalog] ? insika[:skill_catalog].all.size : 0,
        "tools" => insika[:tool_catalog] ? insika[:tool_catalog].all.size : 0,
        "providers" => insika[:llm_provider_store] ? insika[:llm_provider_store].all.size : 0,
        "MCP servers" => insika[:mcp_store] ? insika[:mcp_store].all.size : 0
      }
      now = Time.now
      cutoff = now - (5 * 60)
      @active_now = sessions.count { |s| (t = parse_time(s.updated_at)) && t >= cutoff }
      @recent = sessions.sort_by { |s| s.updated_at.to_s }.reverse.first(8)
      @activity = activity_by_day(sessions, days: 14, now: now)
      @persistence = insika.dig(:config, :persistence)
      view("home")
    end

    def all_sessions
      store = insika[:session_store]
      return [] unless store

      store.each_id.filter_map { |sid| store.find(sid) }
    end

    def parse_time(str)
      s = str.to_s
      return nil if s.empty?

      Time.parse(s)
    rescue ArgumentError
      nil
    end

    # [[Date, count], …] — one bucket per day over the window, most-recent last.
    def activity_by_day(sessions, days:, now:)
      today = now.to_date
      buckets = Hash.new(0)
      sessions.each do |s|
        t = parse_time(s.updated_at) or next
        buckets[t.to_date] += 1
      end
      (0...days).to_a.reverse.map { |i| d = today - i; [d, buckets[d]] }
    end

    # --- History -------------------------------------------------------------

    # Recent conversations (all agents — the Session doesn't stamp the agent that
    # produced it). Most recent first, capped.
    def recent_sessions(limit: 8)
      store = insika[:session_store]
      return [] unless store

      store.each_id.filter_map { |sid| store.find(sid) }
           .sort_by { |s| s.updated_at.to_s }.reverse.first(limit)
    end

    # Compact relative age ("just now", "9min", "3h", "2d") for a timestamp string.
    def time_ago(str)
      t = parse_time(str) or return str.to_s
      secs = (Time.now - t).to_i
      return "just now" if secs < 60

      mins = secs / 60
      return "#{mins}min" if mins < 60

      hrs = mins / 60
      return "#{hrs}h" if hrs < 24

      "#{hrs / 24}d"
    end

    def session_preview(session)
      last = Array(session.messages).reverse.find { |m| %w[user assistant].include?(m["role"]) }
      last && last["content"].to_s
    end

    # --- Settings + LLM providers ----------------------------------

    SETTINGS_SECTIONS = %w[general models edge evals llm].freeze
    def render_settings
      store = insika[:settings_store]
      @settings = store ? store.get : Insika::SettingsStore::DEFAULTS
      @providers = insika[:llm_provider_store] ? insika[:llm_provider_store].all : []
      @section = SETTINGS_SECTIONS.include?(request.params["s"]) ? request.params["s"] : "general"
      view("settings")
    end

    # Settings patch from the form. streaming/compaction are bool
    # (checkbox); the timeouts are integers; compaction.keep_last integer. Only what
    # came in the form enters the patch (the rest and the defaults are preserved in the store).
    # settings_patch/model_defaults_patch/provider_patch moved to Studio::Forms (§11 B6).

    # --- MCP -------------------------------------------------------

    def render_mcp
      @instances = insika[:mcp_store] ? insika[:mcp_store].all : []
      view("mcp")
    end

    # mcp_patch moved to Studio::Forms (§11 B6).

    # --- System-files ----------------------------------------------

    def render_system_files
      store = insika[:system_file_store]
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

    # --- Tasks & Approvals (§12 G5) --------------------------------

    # Task list, most-recently-updated first. Empty-state if no store was injected.
    def render_tasks
      store = insika[:task_store]
      @tasks = store ? store.each_id.filter_map { |id| store.find(id) } : []
      @tasks = @tasks.sort_by { |t| t.updated_at.to_s }.reverse
      view("tasks")
    end

    # Task detail: @task is set by the route. Adds the open approvals for this task
    # and its latest checkpoint (both degrade to empty when the store is absent).
    def render_task_detail(id)
      @pending = insika[:pending_action_store] ? insika[:pending_action_store].open_for(id) : []
      @checkpoint = insika[:checkpoint_store]&.latest(id)
      view("task")
    end

    # Approvals inbox: every :pending action across tasks, each paired with its
    # task (for the status pill + a link into the task detail).
    def render_approvals
      pstore = insika[:pending_action_store]
      tstore = insika[:task_store]
      @approvals = pstore ? pstore.all_open.map { |pa| { pending: pa, task: tstore&.find(pa.task_id) } } : []
      view("approvals")
    end

# --- Evals (RFC-0008 §3.1) -------------------------------------

# The stored cases, grouped by agent, plus the one being edited (?id=). Cases whose
# stored mapping no longer validates are listed separately: a broken case must be
# visible, because a run silently skips it.
def render_evals
  store = insika[:golden_store]
  @cases = store ? store.all : []
  @invalid = store ? store.invalid : []
  @by_agent = @cases.group_by(&:agent).sort.to_h
  wanted = presence(request.params["id"])
  @case = wanted && @cases.find { |g| g.id == wanted }
  @case_yaml = @case ? golden_yaml(@case) : nil
  view("evals")
end

# The case as the YAML an operator edits — the same shape `evals/golden/**` holds,
# so there is one format to learn and a pull request can review what was authored.
def golden_yaml(golden)
  h = { "id" => golden.id, "agent" => golden.agent, "turns" => golden.turns }
  h["requires"] = golden.requires unless golden.requires.empty? # dropping it would un-skip the case
  h["reference"] = golden.reference unless golden.reference.empty? # …and this would un-compare it
  YAML.dump(h.merge("expect" => golden.expect))
end

    # --- Refinement (RFC-0013 phase A) -----------------------------

    # The agent's latest failure report + its run history. Empty-state when no store
    # was injected or the agent has never been run — the page is the invitation to
    # run it, so there is nothing to hide behind a nil.
    def render_refinement
      @agents = insika[:profile_source].ids.sort
      @agent = presence(request.params["agent"]) || @agents.first
      store = insika[:refinement_store]
      @runs = @agent && store ? store.for_agent(@agent, limit: 10) : []
      @run = @runs.find(&:terminal?)
      # The one run that owes this agent a human answer. At most one is possible:
      # gating requires a `completed` run and there is one lifecycle per record.
      @proposal = @runs.find(&:awaiting_approval?)
      view("refinement")
    end

    # A run's window in words. An EMPTY window means "the collector's own default" —
    # resolve it for the operator instead of rendering a blank.
    def refinement_window(window)
      return "since #{window['since']}" if window["since"]

      "last #{window['last_sessions'] || Insika::Refinement::EvidenceCollector::DEFAULT_WINDOW} conversation(s)"
    end

    # An operator control (pause/resume/cancel/approve): audits the ATTEMPT to the
    # shared EventStream BEFORE dispatching — accountability survives a Command
    # failure (parity with server/admin's `act`) — then dispatches via the bus with
    # a success/error flash. The audit carries only metadata, never message/args —
    # an event reaches every subscriber of the stream, so it stays free of content.
    def control_action(type, payload, ok:)
      emit_operator_action(type, payload)
      with_flash(ok) { dispatch(type, payload) }
    end

    def emit_operator_action(type, payload)
      stream = insika[:event_stream]
      return unless stream

      stream.emit(Insika::Event.new(
                    type: :operator_action,
                    data: { action: type.to_s,
                            target: payload.slice(:task_id, :pending_id, :decision, :agent),
                            operator: operator_label },
                    meta: { task_id: payload[:task_id], at: Time.now.utc.iso8601 }
                  ))
    end

    # Operator identity for the audit/approval (single admin token → the Studio
    # is the operator). Mirrors server/admin's operator_of default.
    def operator_label = "studio"

    # Semantic status class for the .pill CSS (completed=ok, running=run,
    # waiting/queued/paused=warn, failed/cancelled=err). Parity with admin's
    # status_pill mapping; used by the tasks/approvals views.
    def status_class(status)
      case status.to_s
      when "completed" then "ok"
      when "running" then "run"
      when "waiting", "queued", "paused" then "warn"
      when "failed", "cancelled" then "err"
      else "info"
      end
    end

    def task_path(id) = "/studio/tasks/#{Rack::Utils.escape(id.to_s)}"

    # parse_kv_lines moved to Studio::Forms (§11 B6).

    # CSV/whitespace -> [String], blanks dropped.
    def split_list(str)
      str.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)
    end

    # --- Playground ----------------------------------------------------------

    # Dispatches the send_message through the SAME bus as the API (no direct writes to a
    # store). tenant = agent → the turn's memory is the agent's (parity with the
    # memory page). The UI observes the turn via SSE.
    def dispatch_send_message(agent:, session_id:, message:)
      dispatch(:send_message, { agent: agent, session_id: session_id, message: message }, tenant: agent)
    end

    # Creates a new session via the bus (create_session generates the id) and returns
    # the id. `model`/`provider` (optional) become the per-chat pin: CreateSession
    # stashes them in the reserved `vars["__llm__"]` slot the ModelResolver reads as
    # the highest-precedence layer (Chat > Agent > platform default). Only non-blank
    # values are sent, so an empty override leaves the session unpinned.
    def create_session(model: nil, provider: nil, thinking: nil)
      payload = { vars: { "canal" => "studio" } }
      payload[:model] = model if model
      payload[:provider] = provider if provider
      payload[:thinking] = thinking if thinking
      dispatch(:create_session, payload).id
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

    # Serves a versioned asset from dist. `File.basename` kills path traversal; only
    # files that exist in the dist dir are served.
    def serve_asset(name)
      base = File.basename(name)
      path = File.join(ASSETS_DIR, base)
      unless File.file?(path) && File.fnmatch(File.join(ASSETS_DIR, "*"), path)
        response.status = 404
        return "not found"
      end

      response["content-type"] = CONTENT_TYPES.fetch(File.extname(base), "application/octet-stream")
      # no-cache (revalidate every load) + the ?v=mtime bust in asset_path: a
      # rebuilt CSS/JS is NEVER served stale, even mid-session across restarts.
      # Assets are tiny and same-origin, so the revalidation cost is negligible —
      # correctness over caching for an actively-edited admin UI.
      response["cache-control"] = "no-cache"
      File.read(path)
    end

    # Cache-busting URL for a dist asset. Dist files are served under a STABLE
    # name with max-age=300, so a rebuilt CSS/JS stays masked by the browser
    # cache for 5 min — even across a server restart (the "restarted and it's
    # still broken" trap). Appending the file mtime as ?v= changes the URL whenever the
    # asset changes, so the browser always refetches the fresh build. The query
    # is ignored by serve_asset (it matches on the path segment).
    def asset_path(file)
      base = File.basename(file)
      path = File.join(ASSETS_DIR, base)
      v = File.file?(path) ? File.mtime(path).to_i : 0
      "/studio/assets/dist/#{base}?v=#{v}"
    end

    def presence(str) = Insika::Coercion.presence(str)

    # Masked-secret sentinel (to pre-fill credential fields in the
    # forms: resubmitting without touching preserves the real secret in the store).
    def secret_sentinel = Insika::SecretMasking::SENTINEL

    # An MCP instance's env (already MASKED) -> "KEY=value" text per line,
    # for the textarea. Sorts by key (stable across renders).
    def env_lines(env)
      (env || {}).sort.map { |k, v| "#{k}=#{v}" }.join("\n")
    end
  end
end
