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
    include Forms     # form -> command-payload parsing
    include NavIcons  # nav SVG helper

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
    # `frame-src 'self'` (explicit, not left to the `default-src 'none'` fallback):
    # the artifact preview page frames /studio/artifacts/:id/content — same-origin,
    # but frame-src does NOT inherit from default-src, so without this line the
    # browser blocked its own iframe (found live: "Framing '...' violates ...
    # default-src 'none' ... frame-src was not explicitly set").
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
      csp.frame_src :self
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
                    memory_audit_store: nil,
                    settings_store: nil, llm_provider_store: nil, mcp_store: nil,
                    system_file_store: nil, tool_trace_store: nil, context_trace_store: nil,
                    cache_series_store: nil,
                    task_store: nil, checkpoint_store: nil, pending_action_store: nil,
                    refinement_store: nil, golden_store: nil, session_secret: nil,
                    outcome_store: nil, shadow_pair_store: nil, parity_criterion: nil,
                    funnel_store: nil, budget_ledger: nil,
                    followup_store: nil, contact_store: nil,
                    proposal_store: nil,
                    harvest_store: nil, harvest_criterion: nil, negative_list: nil,
                    channel_registry: nil,
                    artifact_store: nil, artifact_signing: nil,
                    knowledge_store: nil)
        @insika = {
          command_bus: command_bus, profile_source: profile_source,
          event_stream: event_stream, config: config,
          agent_file_store: agent_file_store, skill_store: skill_store,
          skill_catalog: skill_catalog, tool_catalog: tool_catalog,
          # tool_store: DATA-DEFINED tool definitions. The catalog already
          # shows the data-tools in the matrix; the store feeds the authoring page.
          tool_store: tool_store,
          memory_store: memory_store, session_store: session_store,
          # the Customers drill renders the audit lines (digests +
          # counts, never content). nil = the audit section renders empty.
          memory_audit_store: memory_audit_store,
          # runtime config (settings/LLM/MCP) + global system
          # files + conversations index. All optional (empty-state if nil).
          settings_store: settings_store, llm_provider_store: llm_provider_store,
          mcp_store: mcp_store, system_file_store: system_file_store,
          # per-session tool-call trace (debug): args + result + status per
          # turn, rendered in the session viewer.
          tool_trace_store: tool_trace_store,
          # per-session context breakdown: tokens by category +
          # budget per turn, on the same viewer. Counts only, no content.
          context_trace_store: context_trace_store,
          # per-AGENT cache-hit series (percentages + counts, no
          # content) — the cache tab on the agent detail. nil = tab renders
          # "No turns recorded.".
          cache_series_store: cache_series_store,
          # operate: tasks + human-in-the-loop approvals. Reads the
          # task/checkpoint/pending stores to render; controls (pause/resume/
          # cancel/approve) dispatch on the bus — parity with server/admin.
          task_store: task_store, checkpoint_store: checkpoint_store,
          pending_action_store: pending_action_store,
          # refinement runs: the ranked failure report per agent.
          # Read-only here; the "Run" button dispatches :run_refinement on the bus.
          refinement_store: refinement_store,
          # eval cases: read to render; writes go through:write_golden.
          golden_store: golden_store,
          # WS7: business outcomes — the agents grid's last-outcome pill; the
          # agent detail shows the per-day series. Reads only; recording goes
          # through POST /v1/outcomes.
          outcome_store: outcome_store,
          # the Funnel page reads the fold's cells and the
          # BudgetLedger's current counters (D6). nil = the page renders its
          # empty state.
          funnel_store: funnel_store, budget_ledger: budget_ledger,
          # the shadow pair store (read to render /studio/parity), the
          # frozen criterion (folded by Verdict), and the channel registry (the
          # nav row only exists when a shadow channel is registered — the page
          # is not an invitation, unlike Refinement's).
          shadow_pair_store: shadow_pair_store, parity_criterion: parity_criterion,
          channel_registry: channel_registry,
          # the Follow-ups page READS the stores directly;
          # its only mutations — cancel a pending record, force-revoke a contact
          # — dispatch :cancel_followup / :revoke_contact on the bus. nil = the
          # page renders its empty state.
          followup_store: followup_store, contact_store: contact_store,
          # the Facts (wiki) page reads the proposal store directly
          # (approvals/rejections dispatch :resolve_proposal on the bus).
          # nil = the page renders its empty state.
          proposal_store: proposal_store,
          # the Harvest page reads the harvest store directly
          # (the pending/awaiting/promoted lists); its mutations — mine, gate,
          # promote, reject, rollback — dispatch bus commands. The criterion
          # (boot-loaded, with its sha) and the negative list render the two
          # pre-registered artifacts. nil = the page renders its empty state.
          harvest_store: harvest_store, harvest_criterion: harvest_criterion,
          negative_list: negative_list,
          # the Artifacts tab reads the report store directly; its
          # only mutation (delete) dispatches :delete_artifact on the bus.
          # artifact_signing is a { key:, ttl:, base_url: } Hash when a signing
          # key is configured (nil = no signed surface). nil stores = the
          # pages render their empty states.
          artifact_store: artifact_store, artifact_signing: artifact_signing,
          # the Knowledge page reads the store directly (list/edit/
          # conflict filter); its mutations (write/delete/restore) dispatch
          # bus commands. nil = the page renders its empty state.
          knowledge_store: knowledge_store
        }.freeze
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

      # The signed artifact link: the ONLY path that serves an artifact without
      # a Studio session (the point of a sharing link). Without a signing key
      # there is NO signed surface — a forged link 404s, never a login redirect
      # (a link that cannot exist must not advertise a door).
      r.on "artifacts", "s" do
        r.on String do |id|
          r.get do
            serve_signed_artifact(utf8(id), r.params["exp"], r.params["sig"])
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
            # WS7 scorecard: the LAST outcome per agent, computed once for the
            # whole grid (a store scan per card would be n scans). Series live
            # on the agent detail — one agent's periods, not n charts here.
            @latest_outcomes = insika[:outcome_store]&.latest_per_agent
            # "New from template" gallery — cheap (frontmatter
            # parse only, no evaluation) so it's safe on every render.
            @templates = Insika::Templates.all
            view("agents")
          end

          # POST /studio/agents — creates an agent ("everyone creates
          # their own agent"). Fires :create_agent; redirects to the new one's detail.
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

        # /studio/agents/from_template/:name — "New from template" gallery.
        # Must be declared BEFORE the generic `r.on String do |id|`
        # below, or Roda would treat "from_template" as an agent id.
        r.on "from_template", String do |name|
          r.post do
            check_csrf!
            result = with_flash("Created from template '#{name}'.") do
              create_agent_from_template(name)
            end
            r.redirect(result ? agent_path(result[:agent_id]) : "/studio/agents")
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
            group = CONFIG_SECTIONS.include?(r.params["cfg"]) ? r.params["cfg"] : "model"
            r.redirect(agent_path(id, "config", "cfg=#{group}"))
          end

          # Automatic-loop triggers, per agent. The loops (distillation,
          # harvest, follow-up firing, funnel fold) already run on their own
          # worker fibers when the agent declares them; these buttons exist so
          # an operator can ask for a pass NOW, without waiting for the
          # window. All three dispatch bus commands — the Studio never runs a
          # loop itself.
          r.post "distill" do
            check_csrf!
            done = 0
            skipped = 0
            begin
              due_distill_sessions(id).each do |sid|
                result = dispatch(:run_distillation, { session_id: sid })
                if result && result[:distilled]
                  done += 1
                else
                  skipped += 1
                end
              end
              flash["notice"] = "Distilled #{done} session(s)" + (skipped.positive? ? " (#{skipped} skipped)." : ".")
            rescue Insika::ValidationError, Insika::NotFoundError => e
              flash["error"] = e.message
            end
            r.redirect(agent_path(id, "loops"))
          end

          r.post "harvest" do
            check_csrf!
            begin
              result = dispatch(:run_harvest, { agent: id })
              if result && result[:mined]
                flash["notice"] = "Harvest run finished — #{result[:candidates]} candidate(s) mined."
              elsif result && result[:skipped]
                flash["notice"] = "Nothing mined — #{result[:skipped]}."
              else
                flash["notice"] = "Harvest run finished."
              end
            rescue Insika::ValidationError, Insika::NotFoundError => e
              flash["error"] = e.message
            end
            r.redirect(agent_path(id, "loops"))
          end

          r.post "refinement" do
            check_csrf!
            with_flash("Refinement run finished — see the Refinement page.") do
              dispatch(:run_refinement, { agent: id })
            end
            r.redirect(agent_path(id, "loops"))
          end

          # Store-backed prompts. Writing also ensures the file
          # enters `prompt_files` — otherwise the Prompt provider wouldn't load it.
          # prompt_files is synced by the Commands themselves (write/delete
          # register/remove the file) — the Studio just dispatches the operation.
          #
          # The prompts section renders as a drill (master file list | editor), so
          # the file under edit rides the URL like skills does: GET .../prompts/:file
          # opens that file, .../prompts/new opens the create form.
          r.on "prompts" do
            r.get "new" do
              @prompt_selected = ""
              render_agent_detail
            end

            r.get String do |file|
              @prompt_selected = utf8(file)
              render_agent_detail
            end

            r.post "delete" do
              check_csrf!
              with_flash("Prompt removed.") do
                dispatch(:delete_agent_file, { agent_id: id, file: presence(r.params["file"]) })
              end
              r.redirect(agent_path(id, "prompts"))
            end

            r.post "restore" do
              check_csrf!
              with_flash("Version restored.") do
                dispatch(:restore_agent_file, {
                           agent_id: id, file: presence(r.params["file"]),
                           version: r.params["version"]
                         })
              end
              r.redirect(prompt_edit_path(id, r.params["file"]))
            end

            r.post do
              check_csrf!
              with_flash("Prompt saved.") do
                dispatch(:write_agent_file, {
                           agent_id: id, file: presence(r.params["file"]), content: r.params["content"].to_s
                         })
              end
              r.redirect(prompt_edit_path(id, r.params["file"]))
            end
          end

          r.on "skills" do
            # POST /studio/agents/:id/skills → :update_agent with the `skills`
            # allowlist. "all" = nil; otherwise the checked subset (possibly []).
            r.is do
              r.post do
                check_csrf!
                skills = r.params["all_skills"] == "1" ? nil : Array(r.params["skills"]).map(&:to_s)
                with_flash("Skills updated.") do
                  dispatch(:update_agent, { id: id, skills: skills })
                end
                r.redirect(agent_path(id))
              end
            end

            # /studio/agents/:id/skills/:name — this agent's OWN version of a skill.
            # TWO path segments, which is exactly why the store takes the agent as a
            # second argument: a composite "agent/name" key would put a `/` inside
            # what this route serves as one segment.
            r.on String do |name|
              name = utf8(name)
              r.is do
                r.get do
                  load_skills_master(agent: id)
                  @selected = name
                  @scope_agent = id
                  @skill_content = skill_source(name, agent: id)
                  view("skills")
                end
                # Saving the specialization: same command, `agent:` set.
                r.post do
                  check_csrf!
                  with_flash("Specialization saved.") do
                    dispatch(:write_skill, { name: name, agent: id, content: r.params["content"].to_s })
                  end
                  r.redirect("#{agent_path(id)}/skills/#{Rack::Utils.escape(name)}")
                end
              end

              # Un-specialize: the shared skill stays, and the agent falls back to it.
              r.post "delete" do
                check_csrf!
                with_flash("Specialization removed — the agent falls back to the shared skill.") do
                  dispatch(:delete_skill, { name: name, agent: id })
                end
                r.redirect("/studio/skills/#{Rack::Utils.escape(name)}")
              end
            end
          end

          # Agent memory. Scoped by tenant = agent id — the
          # SAME tenant the playground uses when chatting, so what is edited
          # here is what the agent reads on the turn. Each agent, its own memory.
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
          # Enables/disables the skill on N agents at once, and marks it always-on for
          # the ones that checked `eager`. Both are per-agent decisions about the same
          # skill, so they are the same form and the same dispatch.
          r.post "agents" do
            check_csrf!
            agent_ids = Array(r.params["agent_ids"]).map(&:to_s)
            eager_ids = Array(r.params["eager_ids"]).map(&:to_s)
            result = with_flash("Skill's agents updated.") do
              dispatch(:set_skill_agents, { name: name, agent_ids: agent_ids, eager_ids: eager_ids })
            end
            note_skipped(result)
            r.redirect("/studio/skills")
          end

          # Seeds a per-agent override from the SHARED body and opens it for editing.
          # Seeded and not blank: specializing means "this, but for me" — starting from
          # an empty editor is how the two versions drift apart on day one.
          r.post "specialize" do
            check_csrf!
            agent_id = presence(r.params["agent_id"])
            with_flash("Specialized for #{agent_id}.") do
              dispatch(:write_skill, { name: name, agent: agent_id, content: skill_source(name) })
            end
            r.redirect("/studio/agents/#{Rack::Utils.escape(agent_id.to_s)}/skills/#{Rack::Utils.escape(name)}")
          end
        end
      end

      # --- Tools: tool × agent matrix + DATA-DEFINED tool authoring -----------
      r.on "tools" do
        # Data-defined tool authoring. Under /tools/def/* — BEFORE the
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
          # General settings (streaming/timeouts) → :update_settings.
          r.post do
            check_csrf!
            with_flash("Settings saved.") do
              dispatch(:update_settings, { patch: settings_patch(r) })
            end
            r.redirect("/studio/settings")
          end
        end

        # Platform model defaults (sub-resource, v2): its own form/route so a
        # general-settings save never clobbers the model layer.
        r.post "models" do
          check_csrf!
          with_flash("Model defaults saved.") do
            dispatch(:update_settings, { patch: model_defaults_patch(r) })
          end
          r.redirect("/studio/settings?s=models")
        end

        # Per-model reasoning defaults (the per-model layer): its own form so a
        # model-defaults save never clobbers the per-model map, and vice-versa.
        r.post "model-params" do
          check_csrf!
          with_flash("Per-model params saved.") do
            dispatch(:update_settings, { patch: model_params_patch(r) })
          end
          r.redirect("/studio/settings?s=models")
        end

        # Edge limits: the platform rate-limit/cost layer.
        # Its own form for the same reason as models — saves never cross-clobber.
        r.post "edge" do
          check_csrf!
          with_flash("Edge limits saved.") do
            dispatch(:update_settings, { patch: edge_patch(r) })
          end
          r.redirect("/studio/settings?s=edge")
        end

        # Evals: the judge PANEL and how it agrees. Its own
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

        # Demo data (OSS onboarding): populates the bundled "demo-store" agent
        # so Funnels/Followups/Refinement/Approvals/Distillation/Evals all show
        # real data at once. Same command the CLI's `insika demo:seed` runs —
        # the Studio never seeds anything itself (constitutional rule).
        r.post "seed-demo-data" do
          check_csrf!
          begin
            result = dispatch(:seed_demo_data, { force: r.params["force"] == "1" })
            flash["notice"] = if result[:seeded]
                                 "Seeded '#{result[:agent]}': " +
                                   result[:counts].map { |k, v| "#{v} #{k}" }.join(", ") + "."
                               else
                                 "Already seeded (#{result[:reason]}) — check 'reseed' to seed again."
                               end
          rescue Insika::ValidationError, Insika::NotFoundError => e
            flash["error"] = e.message
          end
          r.redirect("/studio/settings?s=demo")
        end
      end

      # --- MCP: instances with masked credentials ------------------
      r.on "mcp" do
        r.is do
          r.get { render_mcp }
          r.post do
            check_csrf!
            name = nil
            result = with_flash("MCP instance saved.") do
              payload = mcp_patch(r)
              name = payload[:name]
              dispatch(:upsert_mcp, payload)
            end
            r.redirect(mcp_path(result ? name : presence(r.params["name"])))
          end
        end
        r.post "delete" do
          check_csrf!
          with_flash("MCP instance removed.") do
            dispatch(:delete_mcp, { name: presence(r.params["name"]) })
          end
          r.redirect("/studio/mcp")
        end
        # "Test connection": connects LIVE via the same
        # :refresh_mcp_tools Command the CLI's `insika mcp test`/`refresh` and
        # the /v1/mcp/:name/import route use — writes tools_cache either way,
        # `test` vs `refresh` is purely a CLI naming distinction, moot here
        # since the instance card already displays the cache persistently.
        # Rescues StandardError, not just Insika::Error: a transport failure
        # is the ruby_llm-mcp gem's own error class, and turning it into a
        # clean flash instead of a 500 is this caller's job (same discipline
        # as the CLI's `mcp_run`).
        r.post "test" do
          check_csrf!
          name = presence(r.params["name"])
          begin
            tools = dispatch(:refresh_mcp_tools, { name: name })[:tools]
            flash["notice"] = "MCP instance '#{name}': connected, #{tools.size} tool(s)."
          rescue StandardError => e
            flash["error"] = "MCP instance '#{name}': #{e.message}"
          end
          r.redirect(mcp_path(name))
        end
        # "Import JSON": the same `mcpServers` document CLI's
        # `insika mcp import` and Claude Desktop/Cursor already use. Studio
        # never writes a store directly (constitutional rule) — `import_mcp_json`
        # fans the document out into the SAME :upsert_mcp Command a single
        # instance save would use, one dispatch per entry.
        r.post "import" do
          check_csrf!
          begin
            records = import_mcp_json(r.params["json"].to_s)
            flash["notice"] = "Imported #{records.size} MCP instance(s): #{records.map { |rec| rec["name"] }.join(", ")}."
          rescue JSON::ParserError
            flash["error"] = "Invalid JSON."
          rescue Insika::ValidationError, Insika::NotFoundError => e
            flash["error"] = e.message
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
      # Three zones: conversation list | transcript |
      # metadata margin. The master column is the same recent-sessions list
      # the chats index renders; rows frame-navigate, so a Turbo-Frame request
      # renders the two right zones alone.
      r.on "sessions" do
        r.on String do |sid|
          sid = utf8(sid)
          r.get do
            @session = insika[:session_store]&.find(sid)
            next_404 unless @session

            # master column: recent conversations, current one active
            @sessions = recent_sessions(limit: 60)
            # Session's tool-call trace (debug): grouped by turn in the view.
            @tool_traces = (insika[:tool_trace_store]&.for_session(sid) || [])
                           .group_by { |t| t["turn"] }
            # Context breakdown per turn: chronological entries.
            @context_traces = insika[:context_trace_store]&.for_session(sid) || []
            # the stage history — the session's outcomes folded
            # into the agent's declared stages (unmapped kinds render raw).
            @stage_history = stage_history_for(sid)
            if turbo_frame?("session-detail")
              render("session", locals: { frame_only: true }, layout: false)
            else
              view("session", locals: { frame_only: false })
            end
          end
        end
      end

      # --- Customers: the memory drill  ----------------
      # Derived from the store, not a registry: the index enumerates memory
      # cells and classifies them by shape (D6). Every mutation dispatches a
      # Command on the bus — the transport's constitutional rule (app.rb:21).
      # The cell scope in the URL is parsed back into the (tenant, customer)
      # pair: a "memory:acme:c-1" URL must edit the SAME cell the turn reads
      # (E1 live) — passing the raw scope as `tenant` would double-prefix it.
      r.on "customers" do
        r.is do
          r.get { render_customers }
        end

        r.on String do |raw_scope|
          # Roda captures the segment URL-encoded; a customer cell contains
          # colons (memory:acme:c-1), so decode before parsing.
          scope = Rack::Utils.unescape_path(utf8(raw_scope))
          cell = Insika::MemoryStore.parse_cell(scope)

          r.get { render_customer(scope, cell) }

          # Add/edit a fact inline (upsert) — the operator's stamp + audit.
          r.post "fact" do
            check_csrf!
            with_flash("Fact saved.") do
              dispatch(:memory_put_fact, {
                         tenant: cell[:tenant], customer: cell[:customer],
                         key: presence(r.params["key"]), value: r.params["value"].to_s,
                         expires_at: presence(r.params["expires_at"]), operator: "studio"
                       })
            end
            r.redirect(customer_path(scope))
          end

          r.post "forget-fact" do
            check_csrf!
            with_flash("Fact forgotten.") do
              dispatch(:memory_forget_fact, {
                         tenant: cell[:tenant], customer: cell[:customer],
                         key: presence(r.params["key"]), operator: "studio"
                       })
            end
            r.redirect(customer_path(scope))
          end

          # The LGPD access right: JSON download of the cell's content (D7 —
          # the RETURN value is the download; the event stays counts-only). A
          # cell with no customer (a _default cell, reachable by URL) is a
          # ValidationError -> red flash, never a 500.
          r.post "export" do
            check_csrf!
            result = dispatch(:export_customer_memory, {
                                tenant: cell[:tenant], customer: cell[:customer],
                                operator: "studio"
                              })
            response["content-type"] = "application/json"
            response["content-disposition"] =
              %(attachment; filename="memory-#{Rack::Utils.escape_path(scope.tr(':', '-'))}.json")
            JSON.pretty_generate(result)
          rescue Insika::ValidationError => e
            flash["error"] = e.message
            r.redirect(customer_path(scope))
          end

          # The LGPD forget — purges the cell AND the customer's sessions.
          r.post "forget" do
            check_csrf!
            with_flash("Customer forgotten.") do
              dispatch(:forget_customer, {
                         tenant: cell[:tenant], customer: cell[:customer], operator: "studio"
                       })
            end
            r.redirect("/studio/customers")
          end
        end
      end

      # Tasks: list + detail + operator controls -------
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

      # Approvals: human-in-the-loop inbox -------------
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

# Evals: the cases that grade an agent -------
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
      # `POST /refinement` runs the report. `POST
      # refinement/propose` is: the configured model writes a candidate from
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

      # --- Harvest: the gated skill loop  ----------------------
      # Reads the HarvestStore directly (the Studio's constitutional split);
      # every mutation — mine now, gate, promote, reject, rollback — dispatches
      # a bus command. The gate POST is slow on purpose: it replays the golden
      # set, like Refinement's propose button.
      r.on "harvest" do
        r.is do
          r.get { render_harvest }
          r.post do # mine now (manual trigger, D10)
            check_csrf!
            agent = presence(r.params["agent"])
            payload = { agent: agent, full: r.params["full"] == "1" }
            control_action(:run_harvest, payload, ok: "Harvest run finished.")
            r.redirect("/studio/harvest?agent=#{Rack::Utils.escape(agent.to_s)}")
          end
        end

        r.post "gate" do # the double gate on one candidate (slow — replay)
          check_csrf!
          agent = presence(r.params["agent"])
          payload = { candidate_id: presence(r.params["candidate_id"]) }
          control_action(:gate_harvest, payload, ok: "Gated — see the verdicts below.")
          r.redirect("/studio/harvest?agent=#{Rack::Utils.escape(agent.to_s)}")
        end

        r.post "promote" do
          check_csrf!
          agent = presence(r.params["agent"])
          payload = { candidate_id: presence(r.params["candidate_id"]),
                      operator: "studio", note: presence(r.params["note"]) }.compact
          control_action(:promote_harvest, payload,
                         ok: "Promoted — the skill is live for this store.")
          r.redirect("/studio/harvest?agent=#{Rack::Utils.escape(agent.to_s)}")
        end

        r.post "reject" do
          check_csrf!
          agent = presence(r.params["agent"])
          payload = { candidate_id: presence(r.params["candidate_id"]),
                      operator: "studio", note: presence(r.params["note"]) }.compact
          control_action(:reject_harvest, payload, ok: "Skill rejected.")
          r.redirect("/studio/harvest?agent=#{Rack::Utils.escape(agent.to_s)}")
        end

        r.post "rollback" do
          check_csrf!
          agent = presence(r.params["agent"])
          payload = { snapshot_ref: presence(r.params["snapshot_ref"]),
                      operator: "studio", reason: presence(r.params["reason"]) }.compact
          control_action(:rollback_harvest, payload, ok: "Rolled back to the snapshot.")
          r.redirect("/studio/harvest?agent=#{Rack::Utils.escape(agent.to_s)}")
        end
      end

      # --- Knowledge: concepts learned from finished conversations --
      # Reads the KnowledgeStore directly (the Studio's constitutional split);
      # every mutation — write (including an operator's hand-authored concept
      # or a `provenance: policy` promotion), delete, restore — dispatches a
      # bus command. Single-agent-scoped like Harvest, not shared like Skills:
      # the store is a real per-agent (+ optional tenant) partition.
      r.on "knowledge" do
        r.is do
          r.get { render_knowledge }
          r.post do
            check_csrf!
            agent = presence(r.params["agent"])
            name = presence(r.params["name"])
            tenant = presence(r.params["tenant"])
            with_flash("Concept saved.") do
              dispatch(:write_concept, { agent: agent, name: name, tenant: tenant,
                                        content: r.params["content"].to_s }.compact)
            end
            r.redirect(knowledge_path(agent, name, tenant))
          end
        end

        r.get "new" do
          @agents = insika[:profile_source].ids.sort
          @agent = presence(r.params["agent"]) || @agents.first
          @tenant = presence(r.params["tenant"])
          load_knowledge_master(agent: @agent, tenant: @tenant)
          @selected = ""
          @concept_content = new_concept_template
          view("knowledge")
        end

        r.on String do |name|
          name = utf8(name)
          r.is do
            r.get do
              @agents = insika[:profile_source].ids.sort
              @agent = presence(r.params["agent"]) || @agents.first
              @tenant = presence(r.params["tenant"])
              load_knowledge_master(agent: @agent, tenant: @tenant)
              @selected = name
              @concept_content = concept_source(@agent, name, tenant: @tenant)
              @selected_concept = Insika::Knowledge::Concept.parse(@concept_content)
              @concept_versions = insika[:knowledge_store]&.versions(@agent, name, tenant: @tenant)
              view("knowledge")
            end
          end

          r.post "delete" do
            check_csrf!
            agent = presence(r.params["agent"])
            tenant = presence(r.params["tenant"])
            with_flash("Concept removed.") do
              dispatch(:delete_concept, { agent: agent, name: name, tenant: tenant }.compact)
            end
            r.redirect("/studio/knowledge?agent=#{Rack::Utils.escape(agent.to_s)}")
          end

          r.post "restore" do
            check_csrf!
            agent = presence(r.params["agent"])
            tenant = presence(r.params["tenant"])
            with_flash("Version restored.") do
              dispatch(:restore_concept, { agent: agent, name: name, tenant: tenant,
                                          version: r.params["version"] }.compact)
            end
            r.redirect(knowledge_path(agent, name, tenant))
          end
        end
      end

      # --- Facts: the human gate on distilled proposals  --------
      # Reads ProposalStore directly (the Studio's constitutional split — reads
      # hit the stores, mutations go through the bus); the ONLY mutation — the
      # approve/reject/dismiss answer — dispatches :resolve_proposal.
      r.on "facts" do
        r.get { render_facts }
        r.post "resolve" do
          check_csrf!
          decision = presence(r.params["decision"])
          ok = { "approved" => "Fact saved to memory.", "rejected" => "Proposal rejected.",
                 "dismissed" => "Proposal dismissed — it will not be proposed again." }[decision]
          with_flash(ok || "Proposal resolved.") do
            dispatch(:resolve_proposal, { proposal_id: presence(r.params["proposal_id"]),
                                          decision: decision, note: presence(r.params["note"]),
                                          operator: "studio" })
          end
          filter = presence(r.params["filter"])
          r.redirect("/studio/facts#{filter ? "?store=#{Rack::Utils.escape(filter)}" : ""}")
        end
      end

      # --- Parity: the running shadow verdict  -----------------
      # Reads stores and folds the verdict on demand; the judge button is a slow
      # synchronous POST, exactly like Refinement's gate, for the same reason: it
      # returns when the answer is real. There is deliberately no "freeze the
      # criterion" button — freezing is a git commit, reviewed by a human.
      r.on "parity" do
        r.is do
          r.get { render_parity }
          r.post do
            check_csrf!
            agent = presence(r.params["agent"])
            limit = presence(r.params["limit"]).to_i
            payload = { agent: agent }.compact
            payload[:limit] = limit if limit.positive?
            control_action(:judge_shadow_pairs, payload,
                           ok: "Judged — the verdict below is recomputed.")
            r.redirect("/studio/parity?agent=#{Rack::Utils.escape(agent.to_s)}")
          end
        end
      end

      # --- Funnel: the outcome funnel per store  ----------------
      # Reads the fold's cells + the BudgetLedger's current counters directly
      # (D7 — the scorecard's constitutional split); the ONE mutation — the
      # baseline freeze — dispatches :freeze_funnel_baseline on the bus.
      r.on "funnel" do
        r.get { render_funnel }
        r.on String do |agent_id|
          agent_id = utf8(agent_id)
          r.post "freeze" do
            check_csrf!
            with_flash("Baseline frozen.") do
              dispatch(:freeze_funnel_baseline,
                       { agent: agent_id,
                         from: presence(r.params["from"]),
                         to: presence(r.params["to"]),
                         # the card's hidden tenant field: WITHOUT it, a
                         # multi-tenant deployment freezes the "platform" pair
                         # while the operator believes they froze the store's.
                         tenant: presence(r.params["tenant"]),
                         operator: "studio" })
            end
            r.redirect("/studio/funnel")
          end
        end
      end

      # --- Follow-ups: the schedule records + the A/B readout  --
      # Reads FollowupStore/ContactStore/OutcomeStore directly (D10 — the
      # Studio's constitutional split); the ONLY mutations — cancel a pending
      # record, force-revoke a contact (an opt-out event that never arrived) —
      # dispatch bus commands.
      r.on "followups" do
        r.get { render_followups }
        r.on String do |agent_id|
          agent_id = utf8(agent_id)
          r.post "cancel" do
            check_csrf!
            with_flash("Follow-up cancelled.") do
              dispatch(:cancel_followup, { followup_id: r.params["id"] })
            end
            r.redirect("/studio/followups?agent=#{Rack::Utils.escape(agent_id)}")
          end
          r.post "revoke" do
            check_csrf!
            with_flash("Contact revoked — every pending follow-up cancelled.") do
              dispatch(:revoke_contact,
                       { customer: r.params["customer"], operator: "studio" },
                       tenant: presence(r.params["tenant"]))
            end
            r.redirect("/studio/followups?agent=#{Rack::Utils.escape(agent_id)}")
          end
        end
      end

      # --- Artifacts: the report destination -------------------
      # Reads the ArtifactStore directly (the list, the preview, the content);
      # the ONLY mutation — delete — dispatches :delete_artifact on the bus
      # (the Studio never writes a store directly).
      r.on "artifacts" do
        r.is { r.get { render_artifacts } }
        r.on String do |id|
          id = utf8(id)
          r.get "content" do
            serve_artifact_content(id)
          end
          r.post "delete" do
            check_csrf!
            with_flash("Artifact deleted.") { dispatch(:delete_artifact, { id: id }) }
            r.redirect("/studio/artifacts?agent=#{Rack::Utils.escape(presence(r.params['agent']).to_s)}")
          end
          r.is { r.get { render_artifact(id) } }
        end
      end

      # Playground: sends `send_message` (the SAME Command as the API) and streams the
      # response live through the `live-transcript` island (SSE from /studio/events).
      r.on "playground" do
        r.get do
          @agent = presence(r.params["agent"]) || default_agent
          @session_id = presence(r.params["session_id"])
          @agents = insika[:profile_source].ids.sort
          # Session combobox: recent conversations as <datalist> suggestions for the
          # session field. The open session always appears, even if it fell off the
          # recent list (it is the one being edited).
          @recent = recent_sessions(limit: 8)
          if @session_id && @recent.none? { |s| s.id == @session_id }
            current = insika[:session_store]&.find(@session_id)
            @recent.unshift(current) if current
          end
          # Server-side echo + continuity: render the session's persisted
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
          # The per-chat model pin is set at creation and rides the whole
          # conversation, so it only applies to a NEW session — an existing one keeps
          # whatever it was pinned to.
          session_id = typed_session ||
                       create_session(model: presence(r.params["model"]),
                                      provider: presence(r.params["provider"]),
                                      thinking: presence(r.params["thinking"]))
          dispatch_send_message(agent: agent, session_id: session_id, message: message)
          # Optimistic echo of the just-sent message: survives the redirect
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
          ["Customers", "/studio/customers", :chats],
          ["Playground", "/studio/playground", :playground],
          ["Funnel", "/studio/funnel", :funnel],
          # the Follow-ups page — scheduled, fired, blocked and
          # cancelled records per agent + the per-arm A/B readout card.
          ["Follow-ups", "/studio/followups", :followups],
          # the Artifacts page — the report destination: per-agent
          # list, sandboxed preview, signed sharing link.
          ["Artifacts", "/studio/artifacts", :artifacts],
          # the Facts (wiki) page — the human gate on distilled
          # proposals (approve/reject/dismiss, the latch, the CAS re-present).
          ["Facts", "/studio/facts", :facts],
          # the Harvest page — the human gate on mined skills
          # (gate, promote, reject, rollback; the append-only promotion log).
          ["Harvest", "/studio/harvest", :harvest],
          # the Knowledge page — concepts the engine extracted from
          # finished conversations; edit, delete, resolve a conflict.
          ["Knowledge", "/studio/knowledge", :knowledge],
          ["Tasks", "/studio/tasks", :tasks],
          ["Approvals", "/studio/approvals", :approvals],
          ["Refinement", "/studio/refinement", :refinement],
          ["Evals", "/studio/evals", :evals]
        ] + parity_nav_item
        ]
      ]
    end

    # NAV_ICONS + nav_icon moved to Studio::NavIcons.

    def authenticated? = session["auth"] == true

    # Is this request a Turbo frame navigation targeting `id`? Turbo sends
    # `Turbo-Frame: <id>` on every frame fetch (links with data-turbo-frame,
    # form submits inside a frame — including the GET after a 303 redirect).
    # The miller-column routes render their DETAIL pane alone for such a
    # request and the full two-column shell otherwise — the
    # standard Rails check, spelled for Roda. Non-matching frame ids and plain
    # browser hits both take the full page, so refresh/deep links always render
    # the whole screen.
    def turbo_frame?(id) = request.env["HTTP_TURBO_FRAME"] == id.to_s

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

    # --- Polish: theme, health chip -------------------------------

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
      ids.include?("demo") ? "demo" : (ids.first || "demo")
    end

    # --- Transcript display helpers (playground + session viewer) ------------

    # A stored message's content for display: strings as-is; structured payloads
    # as pretty JSON. NEVER Ruby #inspect (session.erb:45 leaked hashrockets to the
    # operator)..
    def message_content(content)
      return content.to_s if content.is_a?(String)

      JSON.pretty_generate(content)
    rescue StandardError
      content.to_s
    end

    # `save_artifact`'s tool-result content is a plain Hash#to_s (RubyLLM tool
    # results are .to_s'd verbatim into the stored message — see Executor#
    # serialize_chat_message — never JSON-encoded): `{id: "...", url: "/studio/
    # artifacts/..."}`. A regex on purpose, not JSON.parse — it genuinely is
    # not JSON. -> the artifact path, or nil when this tool result isn't one
    # (every other tool's result renders exactly as before, unaffected).
    def artifact_link_in(content)
      return nil unless content.is_a?(String)

      content[%r{url:\s*"(/studio/artifacts/[^"]+)"}, 1]
    end

    # An activation label from the context trace, as the operator reads it:
    # "gift-concierge · trigger:presente". The REASON is the point of the card — a
    # bare list of names answers "was something injected", never "which one did I
    # trigger". A label with no reason (a plugin-supplied body) shows just the name.
    def skill_label(label)
      return label.to_s unless label.is_a?(Hash)

      name = label["name"].to_s
      reason = label["reason"].to_s
      reason.empty? ? name : "#{name} · #{reason}"
    end

    # One word for the whole turn, for the collapsed summary: the shared reason when
    # every body arrived the same way, "mixed" when they did not. A turn CAN mix (the
    # agent's eager set plus what this message triggered), which is exactly why the
    # single per-turn `mode` this replaced was a lie waiting to happen.
    def skill_mode(labels)
      kinds = Array(labels).map { |l| (l.is_a?(Hash) ? l["reason"].to_s : "").split(":").first }.uniq
      return "context" if kinds.empty? || kinds.any?(&:nil?) || kinds.include?("")

      kinds.length == 1 ? kinds.first : "mixed"
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
      # Which subnav tab the frame should land on. Selecting a prompt file or
      # a config group is a real navigation (advances the frame + history),
      # which reconnects the `tabs` Stimulus controller — but Turbo's history
      # push drops the URL fragment (it rewrites the frame's src to the fetch
      # response's URL, which never carries one), so `location.hash` is gone
      # by the time it reconnects. Without this, every such click falls back
      # to the tabs' first tab ("config") instead of staying put.
      @active_tab = if !@prompt_selected.nil?
        "prompts"
      elsif request.params["cfg"]
        "config"
      end
      @config_group = CONFIG_SECTIONS.include?(request.params["cfg"]) ? request.params["cfg"] : "model"
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
      # v2 config surfaces: generation params + model fence. AgentProfile.build
      # string-keys these hashes, so the form helpers read plain string keys.
      @params = @agent.params
      @model_policy_allow = model_policy_allow(@agent)
      # guardrails config; nil when the agent never configured any.
      @guardrails = @agent.guardrails || {}
      mem = insika[:memory_store]
      @facts = mem ? mem.facts(tenant: id) : []
      @notes = mem ? mem.notes(tenant: id, limit: 20) : []
      @recent_sessions = recent_sessions
      # WS7: last outcome + per-day series for THIS agent. The grid already
      # shows the last-outcome pill; the series is the period view.
      outcomes = insika[:outcome_store]
      @latest_outcome = outcomes&.latest_per_agent&.[](id)
      @outcome_series = outcomes ? outcomes.series(agent: id) : {}
      # the per-agent cache-hit series (nil store -> the view's
      # empty state; same guard as the tool trace).
      @cache_series = insika[:cache_series_store]&.for_agent(id) || []
      # the agent's schedule rows (declaration + runtime state) —
      # the card shows next fire and the last run/skip alongside the editor.
      @schedules = insika[:schedule_store]&.for_agent(tenant: Insika::ScheduleEngine.tenant_for(@agent), agent: id) || []
      # the master column: the detail page IS the shell when
      # visited directly; only a frame request renders the pane alone.
      @agents = insika[:profile_source].all.sort_by(&:id)
      @latest_outcomes = insika[:outcome_store]&.latest_per_agent
      if turbo_frame?("agent-detail")
        render("agent_detail", locals: { frame_only: true }, layout: false)
      else
        view("agent_detail", locals: { frame_only: false })
      end
    end

    # A generation param off the profile (string-keyed by AgentProfile.build). Used
    # to pre-fill the config form (empty string when absent).
    def agent_param(params, key)
      return "" unless params.is_a?(Hash)

      params[key.to_s].nil? ? "" : params[key.to_s]
    end

    # A free-form config block (string-keyed by AgentProfile.build) rendered
    # as the JSON textarea the form parses back. Pretty-printed so an operator
    # actually reads the current state; "" when the block is absent.
    def agent_json(config)
      return "" if config.nil? || config.empty?

      JSON.pretty_generate(config)
    rescue StandardError
      config.to_s
    end

    # A list field as comma-joined text for the form's textarea.
    def agent_list(list)
      Array(list).join(", ")
    end

    # A list field as newline-joined lines for the form's textarea.
    def agent_lines(list)
      Array(list).join("\n")
    end

    # The shared "filter by agent" GET form used by every shared screen
    # (home, chats, tasks, approvals, customers, evals, funnel, follow-ups,
    # facts, parity). Same markup everywhere: a select that submits on change.
    def agent_filter_form(path, current)
      ids = insika[:profile_source].ids.sort
      options = [["", "all"]] + ids.map { |id| [id, id] }
      rows = options.map do |value, label|
        %(<option value="#{value}"#{' selected' if value.to_s == current.to_s}>#{label}</option>)
      end.join
      %(<form method="get" action="#{path}" class="actions inline"><label>Agent <select name="agent" data-controller="auto-submit" data-action="change->auto-submit#submit">#{rows}</select></label></form>)
    end

    # The sessions of one agent — the session stamps its agent in
    # `vars["agent"]`, so any list of sessions is filterable by agent.
    def agent_sessions(sessions, agent)
      return sessions if agent.nil? || agent.empty?

      sessions.select { |s| session_agent(s) == agent }
    end

    def session_agent(session)
      vars = session.respond_to?(:vars) ? session.vars : nil
      vars.is_a?(Hash) ? vars["agent"].to_s : ""
    end

    # The distill button's scope (the DistillEngine's own scan, scoped to ONE
    # agent): the agent's sessions that are idle past the pack's window, long
    # enough, and not yet distilled. Oldest first, capped — each entry is a
    # provider call, so one click stays bounded. Reads hit the stores; the
    # writes go through :run_distillation on the bus.
    def due_distill_sessions(agent_id, limit: 5)
      store = insika[:session_store]
      proposals = insika[:proposal_store]
      profile = insika[:profile_source].fetch(agent_id)
      return [] if profile.nil? || store.nil? || proposals.nil?

      config = Insika::Coercion.deep_stringify(profile.distill) || {}
      idle_hours = positive_int(config["idle_hours"]) || 6
      min_messages = positive_int(config["min_messages"]) || 3
      cutoff = Time.now.utc - idle_hours * 3600
      store.each_id.filter_map do |sid|
        session = store.find(sid)
        next unless session
        next unless session.vars.is_a?(Hash) && session.vars["agent"] == agent_id
        next if Insika::Coercion.blank?(session.vars["customer"])
        next unless aged?(session.updated_at, cutoff)
        next if session.messages.size < min_messages
        next if proposals.distilled?(sid)

        [sid, session.updated_at.to_s]
      end.sort_by(&:last).map(&:first).first(limit)
    end

    def positive_int(value)
      v = value.to_i
      v.positive? ? v : nil
    end

    def aged?(updated_at, cutoff)
      return false if Insika::Coercion.blank?(updated_at)

      Time.iso8601(updated_at.to_s) <= cutoff
    rescue ArgumentError
      false
    end

    # Renders the reasoning <select> shared by the agent config, settings and
    # playground (4-layer). `blank_label` names the empty option — the
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
    # `model` is OPTIONAL as of v2: blank clears it, so the agent inherits
    # the platform `default_model` via the ModelResolver — the config form is the
    # place that surfaces that layering. params/model_policy: see the helpers below.
    # config_patch/guardrails_patch/guardrail_responses_patch/params_patch/
    # model_policy_patch/coerce moved to Studio::Forms.

    # --- Skills index --------------------------------------------------------

    # Master data for the Skills drill-down (list + authored badges + agents),
    # shared by every skill route so the master pane always renders. @selected
    # drives the detail pane (nil = none, "" = new, name = edit).
    # `agent` renders the AGENT's view of the catalog: its own version of each shared
    # skill, plus whatever is private to it. Absent = the shared catalog.
    def load_skills_master(agent: nil)
      catalog = insika[:skill_catalog]
      @skills = (catalog ? catalog.all(agent: agent) : []).sort_by(&:name)
      @stored = insika[:skill_store] ? insika[:skill_store].names(agent: agent) : []
      @agents = insika[:profile_source].all.sort_by(&:id)
      # Which agents specialized THIS skill — the availability grid shows it, so an
      # override is discoverable from the shared skill it overrides.
      @specialized = insika[:skill_store] ? specialized_by : {}
    end

    # { skill name => [agent ids] } across every agent scope in the store.
    def specialized_by
      insika[:skill_store].agents.each_with_object({}) do |agent, acc|
        insika[:skill_store].names(agent: agent).each { |name| (acc[name] ||= []) << agent }
      end
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
    def skill_source(name, agent: nil)
      raw = insika[:skill_store]&.get(name, agent: agent)
      return raw if raw

      skill = insika[:skill_catalog]&.find(name, agent: agent)
      return new_skill_template(name) unless skill

      # The WHOLE frontmatter, not just name/description: this text seeds the
      # specialize action and any first edit of a disk skill, and an override that
      # silently drops `triggers:` turns the agent's deterministic activation off.
      fm = ["name: #{skill.name}", "description: #{skill.description}"]
      fm << "triggers: #{skill.triggers.join(', ')}" if Array(skill.triggers).any?
      fm << "companions: #{skill.companions.join(', ')}" if Array(skill.companions).any?
      "---\n#{fm.join("\n")}\n---\n\n#{skill.body}\n"
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

    # Is this skill always-on for this agent? `skills_eager` is nil/false (none), true
    # (blanket) or a list — NOT allowlist semantics, so nil must read as false here.
    def skill_eager_for?(profile, skill_name)
      spec = profile.skills_eager
      return true if Insika::Coercion.truthy?(spec)
      return false if spec.nil? || spec == false

      Array(spec).map(&:to_s).include?(skill_name.to_s)
    end

    # The two "left intact" outcomes of :set_skill_agents: an agent whose allowlist (or
    # eager set) is "all" cannot have ONE name removed from it without materializing an
    # explicit list, which would be a destructive surprise. Say so instead of silently
    # doing nothing.
    def note_skipped(result)
      return unless result

      parts = []
      skipped = Array(result[:skipped_all])
      eager = Array(result[:skipped_eager_all])
      parts << "#{skipped.size} agent(s) with 'all' skills were left intact" if skipped.any?
      parts << "#{eager.size} agent(s) with blanket eager were left intact" if eager.any?
      flash["notice"] = "#{flash['notice']} — #{parts.join(', ')}." if parts.any?
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
      # Miller columns: the master rows frame-navigate (?a=),
      # so a Turbo-Frame request renders just the detail pane.
      if turbo_frame?("tool-detail")
        render("tools", locals: { frame_only: true }, layout: false)
      else
        view("tools", locals: { frame_only: false })
      end
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

    # Data-defined tool authoring -------------------------------

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

    # tool_patch/parse_parameters moved to Studio::Forms.

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
    # `?agent=` narrows every number to one agent (the sessions stamp their
    # author in `vars["agent"]`). The live layer (live_home_controller) only
    # repaints what this renders — it never computes its own baseline.
    def render_home
      ps = insika[:profile_source]
      @agent = presence(request.params["agent"])
      sessions = agent_sessions(all_sessions, @agent)
      @counts = {
        "conversations" => sessions.size,
        "messages" => sessions.sum { |s| Array(s.messages).size },
        "agents" => ps ? ps.all.size : 0,
        "skills" => insika[:skill_catalog] ? insika[:skill_catalog].all.size : 0,
        "tools" => insika[:tool_catalog] ? insika[:tool_catalog].all.size : 0,
        "providers" => insika[:llm_provider_store] ? insika[:llm_provider_store].all.size : 0,
        "MCP servers" => insika[:mcp_store] ? insika[:mcp_store].all.size : 0
      }
      # UTC, deliberately: sessions stamp `updated_at` with `Time.now.utc.iso8601`,
      # and every bucket below is keyed by a calendar part (date, hour) of that
      # stamp. A LOCAL `now` mixes two clocks — on a UTC-3 host, from 21:00 local
      # onward "today" is already tomorrow in UTC, so the day buckets stopped
      # matching and the 24h floor was built three hours in the future, silently
      # emptying both charts. Instant comparisons (`cutoff`) never had the bug;
      # calendar arithmetic did.
      now = Time.now.utc
      cutoff = now - (5 * 60)
      @active_now = sessions.count { |s| (t = parse_time(s.updated_at)) && t >= cutoff }
      @recent = sessions.sort_by { |s| s.updated_at.to_s }.reverse.first(8)
      @activity = activity_by_day(sessions, days: 14, now: now)
      # 24h sparkline: conversations touched per hour, oldest
      # first — the same session scan, bucketed finer.
      @activity_24h = activity_by_hour(sessions, hours: 24, now: now)
      # Trend affordances on the traffic stat cards: today vs yesterday from
      # the 14-day series (config counts — agents/skills/tools/providers —
      # have no daily shape and honestly show no trend).
      # `@activity` is OLDEST FIRST and ends at today, so the last pair reads
      # [yesterday, today]. Destructured the other way round it reported a
      # first-conversation-of-the-day as "−1", every day.
      yesterday, today = @activity.last(2).map(&:last)
      @conv_trend = today.to_i - yesterday.to_i
      @msg_trend = message_delta(sessions, now)
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
    # `now` is UTC (render_home) and so is every `t` — see #utc_time. Both sides
    # of the bucket key must be read off the same clock or the join silently
    # misses.
    def activity_by_day(sessions, days:, now:)
      today = now.to_date
      buckets = Hash.new(0)
      sessions.each do |s|
        t = utc_time(s.updated_at) or next
        buckets[t.to_date] += 1
      end
      (0...days).to_a.reverse.map { |i| d = today - i; [d, buckets[d]] }
    end

    # [[hour_start, count], …] — one bucket per hour over the last `hours`,
    # oldest first, each bucket labeled by its starting hour. Feeds the 24h
    # sparkline; a session counts in the hour it was last
    # touched — the same reading "conversations touched" the daily chart uses.
    def activity_by_hour(sessions, hours:, now:)
      floor = Time.utc(now.year, now.month, now.day, now.hour) - (hours - 1) * 3600
      buckets = Hash.new(0)
      sessions.each do |s|
        t = utc_time(s.updated_at) or next
        h = Time.utc(t.year, t.month, t.day, t.hour)
        buckets[h] += 1 if h >= floor
      end
      (0...hours).map { |i| [floor + i * 3600, buckets[floor + i * 3600]] }
    end

    # Messages in sessions touched today vs yesterday (the delta the messages
    # stat card shows). A conversation's whole message count lands in the day
    # it was last updated — coarse, but it is the same data the card counts.
    def message_delta(sessions, now)
      today = now.to_date
      sum = ->(date) do
        sessions.sum { |s| (t = utc_time(s.updated_at)) && t.to_date == date ? Array(s.messages).size : 0 }
      end
      sum.call(today) - sum.call(today - 1)
    end

    # A stamp read for its CALENDAR parts, always in UTC. `Time.parse` honours
    # whatever offset the string carries — ours are `Z`, but a record written by
    # anything else would otherwise bucket by its own zone. `getutc`, not `utc`:
    # the latter mutates the receiver.
    def utc_time(value)
      t = parse_time(value)
      t&.getutc
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
      # Structured content previews as JSON (message_content), never #inspect —
      # a hashrocket in a filter-text attribute is exactly the leak this guards.
      last && message_content(last["content"])
    end

    # --- Settings + LLM providers ----------------------------------

    # The agent config tab's groups, in sidebar order. The view renders the
    # same keys; a bogus ?cfg= falls back to the first group.
    CONFIG_SECTIONS = %w[model guardrails grounding funnel followups schedules distill harvest refinement budget_rel routing advanced].freeze

    SETTINGS_SECTIONS = %w[general models edge evals llm demo].freeze
    def render_settings
      store = insika[:settings_store]
      @settings = store ? store.get : Insika::SettingsStore::DEFAULTS
      @providers = insika[:llm_provider_store] ? insika[:llm_provider_store].all : []
      @section = SETTINGS_SECTIONS.include?(request.params["s"]) ? request.params["s"] : "general"
      @persistence = insika[:config][:persistence].to_s
      view("settings")
    end

    # Settings patch from the form. streaming is a bool (checkbox); the timeouts
    # are integers. Only what came in the form enters the patch (the rest and
    # the defaults are preserved in the store).
    # settings_patch/model_defaults_patch/provider_patch moved to Studio::Forms.

    # --- MCP -------------------------------------------------------

    def render_mcp
      @instances = insika[:mcp_store] ? insika[:mcp_store].all.sort_by { |m| m["name"].to_s } : []
      # Miller columns: ?i= selects the instance whose editor
      # fills the detail pane. Absent = the first instance (the pane is useful
      # on landing, same convention as the tools matrix); "?i=" (empty) = the
      # empty state, which hosts the new/import forms — the master's "+ new"
      # link points there. A Turbo-Frame request renders the pane alone.
      raw = request.params["i"]
      @selected_mcp = if raw.nil?
                        @instances.first
                      else
                        @instances.find { |m| m["name"] == raw }
                      end
      if turbo_frame?("mcp-detail")
        render("mcp", locals: { frame_only: true }, layout: false)
      else
        view("mcp", locals: { frame_only: false })
      end
    end

    # Where an MCP write redirects back to: the miller shell with the touched
    # instance still selected, so a frame submit lands on the saved editor
    # rather than the empty state. A deleted instance falls back to the shell.
    def mcp_path(name = nil)
      return "/studio/mcp" if Insika::Coercion.blank?(name)

      "/studio/mcp?i=#{Rack::Utils.escape(name)}"
    end

    # mcp_patch moved to Studio::Forms.

    # Bulk `mcpServers` JSON import, routed through the bus:
    # gives Insika::McpJson.import the `#upsert` duck-type it expects while
    # every actual write still goes through :upsert_mcp — the adapter's
    # block closes over `self` (the App instance), so `dispatch` resolves
    # normally regardless of its own visibility. -> [Hash] masked records.
    def import_mcp_json(json)
      dispatcher = method(:dispatch)
      adapter = Object.new
      adapter.define_singleton_method(:upsert) { |attrs| dispatcher.call(:upsert_mcp, attrs) }
      Insika::McpJson.import(json, mcp_store: adapter)
    end

    # Connection/discovery status chip for an ENABLED instance -
    # durable state read from the record, not a live probe: "N
    # tool(s)" means the last refresh cached that many, not that the server
    # is reachable RIGHT NOW (only "Test connection" tells you that; a failed
    # attempt surfaces as a flash, not a chip — McpStore holds no "last
    # error" field to persist). -> [label, pill_css_class].
    def mcp_status(record)
      if record["transport"] == "stdio" && !Insika::EnvSchema.truthy?(Insika::EnvSchema.read("INSIKA_MCP_STDIO"))
        return ["stdio disabled", "err"]
      end

      tools = Array(record["tools_cache"])
      return ["untested", ""] if tools.empty?

      ["#{tools.size} tool(s)", "ok"]
    end

    # Haystack for the /mcp list-filter box: name, transport, on/off, and the
    # same status label the pill shows — so typing "stdio", "off", "err" or
    # "untested" narrows the list, not just a name search.
    def mcp_filter_text(record)
      status_label, = mcp_status(record)
      [record["name"], record["transport"], record["enabled"] ? "on enabled" : "off disabled", status_label].join(" ")
    end

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
      @agent = presence(request.params["agent"])
      @sessions = agent_sessions(recent_sessions(limit: 100), @agent)
      view("chats")
    end

    # --- Customers  ----------------------------------

    # The index: every CUSTOMER memory cell, grouped by tenant. The caller
    # passes `reserved:` (profile ids + _default) so the agent-memory tab's
    # cells and the shared cell stay out of the drill (D6 — the store is
    # policy-free). Fact count per cell via a keys-only list (no payload
    # reads per conversation on every render).
    def render_customers
      mem = insika[:memory_store]
      agent_ids = insika[:profile_source] ? insika[:profile_source].all.map(&:id) : []
      @agent = presence(request.params["agent"])
      @rows = mem ? mem.customer_cells(reserved: Array(agent_ids) + ["_default"]).map do |cell|
        { cell: cell, count: mem.fact_count(tenant: cell[:tenant], customer: cell[:customer]) }
      end : []
      # ?agent= narrows to one tenant — the memory scope is the agent (the
      # agent-memory tab writes under tenant = agent id).
      @rows = @rows.select { |row| row[:cell][:tenant] == @agent } if @agent
      @by_tenant = @rows.group_by { |row| row[:cell][:tenant] }
      view("customers")
    end

    # The detail: the parsed cell, its facts (expired excluded by C1), notes
    # (append-only), and the operator audit (digests + counts, never content).
    def render_customer(scope, cell)
      @cell = cell
      mem = insika[:memory_store]
      @facts = mem ? mem.facts(tenant: cell[:tenant], customer: cell[:customer]) : []
      @notes = mem ? mem.notes(tenant: cell[:tenant], customer: cell[:customer], limit: 50) : []
      @audit = insika[:memory_audit_store]&.for_cell(scope) || []
      view("customer")
    end

    def customer_path(scope)
      # escape_path, not escape: the route decodes with unescape_path, which
      # does not turn '+' back into a space (escape's form-encoding would).
      "/studio/customers/#{Rack::Utils.escape_path(scope)}"
    end

    # Tasks & Approvals --------------------------------

    # Task list, most-recently-updated first. Empty-state if no store was injected.
    # `?agent=` narrows to one agent (the task's command payload stamps it).
    def render_tasks
      store = insika[:task_store]
      @agent = presence(request.params["agent"])
      @tasks = store ? store.each_id.filter_map { |id| store.find(id) } : []
      @tasks = @tasks.select { |t| task_agent(t) == @agent } if @agent
      @tasks = @tasks.sort_by { |t| t.updated_at.to_s }.reverse
      view("tasks")
    end

    def task_agent(task)
      command = task.command
      command.is_a?(Hash) ? command.dig("payload", "agent").to_s : ""
    end

    # Task detail: @task is set by the route. Adds the open approvals for this task
    # and its latest checkpoint (both degrade to empty when the store is absent).
    def render_task_detail(id)
      @pending = insika[:pending_action_store] ? insika[:pending_action_store].open_for(id) : []
      @checkpoint = insika[:checkpoint_store]&.latest(id)
      view("task")
    end

    # Approvals inbox: every :pending action across tasks, each paired with its
    # task (for the status pill + a link into the task detail). `?agent=`
    # narrows to one agent (via the owning task).
    def render_approvals
      pstore = insika[:pending_action_store]
      tstore = insika[:task_store]
      @agent = presence(request.params["agent"])
      @approvals = pstore ? pstore.all_open.map { |pa| { pending: pa, task: tstore&.find(pa.task_id) } } : []
      if @agent
        @approvals = @approvals.select { |a| task_agent(a[:task]) == @agent if a[:task] }
      end
      view("approvals")
    end

# Evals -------------------------------------

# The stored cases, grouped by agent, plus the one being edited (?id=). Cases whose
# stored mapping no longer validates are listed separately: a broken case must be
# visible, because a run silently skips it.
def render_evals
  store = insika[:golden_store]
  @cases = store ? store.all : []
  @invalid = store ? store.invalid : []
  @filter = presence(request.params["agent"])
  @cases = @cases.select { |g| g.agent == @filter } if @filter
  @by_agent = @cases.group_by(&:agent).sort.to_h
  wanted = presence(request.params["id"])
  @case = wanted && @cases.find { |g| g.id == wanted }
  @case_yaml = @case ? golden_yaml(@case) : nil
  view("evals")
end

# The case as the YAML an operator edits — the same shape `evals/golden/**` holds,
# so there is one format to learn and a pull request can review what was authored.
# A SIMULATED case carries `persona:` instead of `turns:` — the two
# shapes are the same YAML, and dropping either key would silently change what
# the case tests.
def golden_yaml(golden)
  h = if golden.simulated?
        { "id" => golden.id, "agent" => golden.agent, "persona" => golden.persona.to_h }
      else
        { "id" => golden.id, "agent" => golden.agent, "turns" => golden.turns }
      end
  h["requires"] = golden.requires unless golden.requires.empty? # dropping it would un-skip the case
  h["reference"] = golden.reference unless golden.reference.empty? # …and this would un-compare it
  YAML.dump(h.merge("expect" => golden.expect))
end

    # Refinement -----------------------------

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

    # --- Parity  -------------------------------------------------

    # The nav row exists ONLY when a shadow channel is registered — the page is
    # not an invitation, unlike Refinement's.
    def parity_nav_item
      shadow_channel? ? [["Parity", "/studio/parity", :parity]] : []
    end

    def shadow_channel?
      registry = insika[:channel_registry]
      return false unless registry

      Array(registry.names).any? do |name|
        channel = registry.find(name)
        channel.respond_to?(:shadow?) && channel.shadow?
      end
    end

    def parity_pairs
      insika[:shadow_pair_store] ? insika[:shadow_pair_store].each.to_a : []
    end

    def render_parity
      @criterion = insika[:parity_criterion]
      @agent = presence(request.params["agent"])
      # ONE materialization per request: the fold and the pair list share this
      # array (the store's counts would scan the whole table a second time).
      pairs = parity_pairs
      pairs = pairs.select { |p| p.agent.to_s == @agent } if @agent
      @report = @criterion && Insika::Parity::Verdict.fold(pairs: pairs, criterion: @criterion)
      @pairs = pairs.sort_by { |p| p.created_at.to_s }.reverse.first(50)
      @pending = pairs.count { |p| p.status == :complete }
      if @criterion
        @judge_cost = @pending * @criterion.rule.min_judge_models * 2
        @judge_models = ((insika[:settings_store]&.get || {})["evals"] || {})
      end
      # Judge agreement : split/unknown from the fold, plus how many
      # verdicts flipped with presentation order.
      @agreement = { order_dependent: pairs.count { |p| p.verdict.is_a?(Hash) && p.verdict["order_dependent"] } }
      view("parity")
    end

    # --- Artifacts  ---------------------------------------------

    # The restrictive CSP for artifact CONTENT (both the authenticated and the
    # signed route): artifact content is LLM output — untrusted. No script, no
    # external fetch, no forms; inline styles (the report's own styling) and
    # data: images (inline SVG) are the two things a report legitimately needs.
    ARTIFACT_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"

    def artifact_store = insika[:artifact_store]

    # -> { key:, ttl:, base_url: } | nil (no signing configured -> no signed surface).
    def artifact_signing = insika[:artifact_signing]

    def artifact_tenant = presence(request.params["tenant"]) || "platform"

    # The Artifacts page: per-agent list (the listing IS the history — newest
    # first). Reads the store directly; the only mutation (delete) dispatches
    # :delete_artifact on the bus.
    def render_artifacts
      @agents = insika[:profile_source].ids.sort
      @agent = presence(request.params["agent"])
      @signed_available = !artifact_signing.nil? && artifact_signing[:key].to_s.length.positive?
      # #all, not #for_agent/#for_tenant: the Studio doesn't reliably know
      # which tenant string an artifact was bound under (Playground turns
      # bind tenant=agent; a plain single-tenant API turn binds "platform") —
      # see ArtifactStore#all. Filtering by the record's own `agent` field
      # sidesteps the guess.
      @artifacts = artifact_store&.all(agent: @agent) || []
      view("artifacts")
    end

    # The preview page: metadata + the artifact in a SANDBOXED iframe (no
    # allow-scripts / allow-same-origin / allow-forms — on top of the content
    # route's own restrictive CSP).
    def render_artifact(id)
      record = artifact_store&.find(id)
      return next_404 if record.nil?

      @artifact = record
      @content_url = "/studio/artifacts/#{Rack::Utils.escape_path(id)}/content"
      @signed_url = signed_artifact_url(record.id)
      view("artifact")
    end

    # The authenticated content route: raw content + the restrictive CSP. The
    # iframe (same-origin) and the channel-navigated operator read here.
    def serve_artifact_content(id)
      record = artifact_store&.find(id)
      return next_404 if record.nil?

      serve_artifact_bytes(record)
    end

    # The signed route: verifies the HMAC over (id, expiry) in constant time,
    # serves only what verifies AND is unexpired. Bad/expired/absent-key ->
    # 404 (never 403 — no oracle).
    def serve_signed_artifact(id, exp, sig)
      signing = artifact_signing
      key = signing && signing[:key].to_s
      return next_404 if key.to_s.empty?

      return next_404 unless Insika::ArtifactSigning.valid?(id: id, token: sig, key: key, exp: exp)

      record = artifact_store&.find(id)
      return next_404 if record.nil?

      serve_artifact_bytes(record)
    end

    # -> the signed sharing URL | nil (no key -> no signed surface).
    def signed_artifact_url(id)
      signing = artifact_signing
      return nil unless signing && signing[:key] && signing[:key].to_s.length.positive?

      Insika::ArtifactSigning.url_for(id: id, base: signing[:base_url],
                                      key: signing[:key], ttl: signing[:ttl])
    end

    def serve_artifact_bytes(record)
      response.headers["content-type"] = "#{record.mime}; charset=utf-8"
      response.headers["Content-Security-Policy"] = ARTIFACT_CSP
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Cache-Control"] = "no-store"
      response.write(record.content)
      request.halt
    end

    # --- Funnel  ------------------------------------------------

    # One card per STORE (agent) that declares a funnel, each with a block per
    # tenant that has folded cells. The only mutation on this page — the
    # baseline freeze — dispatches :freeze_funnel_baseline (D7).
    def render_funnel
      profiles = insika[:profile_source]&.all || []
      p = request.params["period"].to_i
      @period = p.positive? ? p : 30
      @agent = presence(request.params["agent"])
      profiles = profiles.select { |p| p.id == @agent } if @agent
      @stores = profiles.filter_map do |p|
        decl = Insika::FunnelDeclaration.parse(p.funnel)
        next unless decl

        { profile: p, decl: decl, tenants: tenants_for(p.id) }
      end
      view("funnel")
    end

    # the Follow-ups page. Per agent WITH a parsed policy, one
    # block: the pending/fired/cancelled/blocked lists (blocked rows carry the
    # reason pill), the per-arm counts, the read-only policy summary and the
    # A/B card (D10 — reads stores, mutates through bus commands only).
    def render_followups
      profiles = insika[:profile_source]&.all || []
      @agent = presence(request.params["agent"])
      profiles = profiles.select { |p| p.id == @agent } if @agent
      @stores = profiles.filter_map do |p|
        decl = Insika::FollowupPolicy.parse(p.followup)
        next unless decl

        {
          profile: p, policy: decl,
          tenant: presence(request.params["tenant"]) || "platform",
          records: followup_records(p.id, decl),
          ab: followup_ab(p.id, decl)
        }
      end
      @has_followups = !@stores.empty?
      view("followups")
    end

    # the Facts (wiki) page — the human gate on distilled
    # proposals. Reads ProposalStore + SessionStore directly (D7 — evidence is
    # a link, never a copy: the excerpt is read from the session at request
    # time); the mutations dispatch :resolve_proposal on the bus.
    def render_facts
      store = insika[:proposal_store]
      @pending = store ? store.pending(limit: 100) : []
      @stale   = store ? store.stale(limit: 50) : []
      @recent  = store ? store.resolved(limit: 20) : []
      # `?agent=` filters by the proposal's AGENT (the origin session's
      # stamp); `?store=` keeps filtering by the memory-cell scope (the
      # pre-review behavior). Both narrow the same three lists.
      @filter = presence(request.params["agent"]) || presence(request.params["store"])
      if @filter
        @pending = @pending.select { |p| scope_matches?(p, @filter) }
        @stale   = @stale.select { |p| scope_matches?(p, @filter) }
        @recent  = @recent.select { |p| scope_matches?(p, @filter) }
      end
      # The select: the filtered agents (profile ids) PLUS every scope a
      # proposal ever carried, so an agent with proposals and one without can
      # both be picked.
      @stores  = (insika[:profile_source].ids.sort +
                  (@pending + @stale + @recent).map(&:scope)).uniq.sort
      @sessions = insika[:session_store]
      view("facts")
    end

    # A proposal matches the filter as the memory scope it carries, or as the
    # agent of the session it came from (when the session is still around).
    def scope_matches?(proposal, filter)
      return true if proposal.scope == filter

      session = insika[:session_store]&.find(proposal.session_ref)
      session && session_agent(session) == filter
    end

    # the Harvest page — the human gate on mined skills. Reads
    # HarvestStore/SessionStore directly (the evidence excerpt is read from the
    # session at request time — D7: ids and indexes only are stored); every
    # mutation dispatches a bus command.
    def render_harvest
      @agents = insika[:profile_source].ids.sort
      @agent = presence(request.params["agent"]) || @agents.first
      store = insika[:harvest_store]
      # EVERY list respects the agent filter (the review fix) — the page is a
      # per-store inbox, not a global one.
      @candidates = @agent && store ? store.candidates(agent_id: @agent, status: "awaiting_approval") : []
      @pending_gates = @agent && store ? store.candidates(agent_id: @agent, status: "pending").first(50) : []
      @blocked = if @agent && store
                   store.candidates(agent_id: @agent, status: "gated")
                        .select { |c| !c.eval_gate || !c.conversion_gate || c.conversion_gate["passed"] == false }
                        .first(50)
                 else
                   []
                 end
      @recent = @agent && store ? store.candidates(agent_id: @agent, status: "promoted").first(20) : []
      @runs = @agent && store ? store.runs_for(@agent, limit: 5) : []
      @promotions = @agent && store ? store.promotions(agent_id: @agent, limit: 50) : []
      @criterion = insika[:harvest_criterion]
      @funnel = insika[:funnel_store]
      @sessions = insika[:session_store]
      @negative = insika[:negative_list]
      @filter = presence(request.params["agent"])
      view("harvest")
    end

    # --- Knowledge index -------------------------------------------------

    # Master data for the Knowledge drill-down: every concept of ONE agent
    # (+ optional tenant), parsed for the list columns (type/confidence/
    # occurrences/updated_at). A record that fails to parse (corrupted by a
    # hand edit) still shows by name, blank elsewhere, rather than vanishing.
    def load_knowledge_master(agent:, tenant: nil)
      @status ||= "all"
      store = insika[:knowledge_store]
      names = agent && store ? store.names(agent, tenant: tenant) : []
      concepts = names.filter_map do |n|
        Insika::Knowledge::Concept.parse(store.get(agent, n, tenant: tenant)) ||
          { name: n, description: "", type: "", confidence: 0.0, occurrences: 0, updated_at: "", body: "" }
      end.sort_by { |c| c[:name] }
      @all_count = concepts.size
      @conflict_count = concepts.count { |c| concept_conflict?(c) }
      @concepts = @status == "conflict" ? concepts.select { |c| concept_conflict?(c) } : concepts
    end

    def render_knowledge
      @agents = insika[:profile_source].ids.sort
      @agent = presence(request.params["agent"]) || @agents.first
      @tenant = presence(request.params["tenant"])
      @status = presence(request.params["status"]) || "all"
      load_knowledge_master(agent: @agent, tenant: @tenant)
      # Auto-open the first concept (drill-down convention), respecting the
      # active filter — the empty state only shows with nothing left to see.
      @selected = @concepts.first&.dig(:name)
      @concept_content = @selected ? concept_source(@agent, @selected, tenant: @tenant) : nil
      @selected_concept = @concept_content && Insika::Knowledge::Concept.parse(@concept_content)
      @concept_versions = @selected && insika[:knowledge_store]&.versions(@agent, @selected, tenant: @tenant)
      view("knowledge")
    end

    # Raw content for the editor — the complete concept markdown, straight
    # from the store (unlike a skill, there is no disk fallback to
    # reconstruct: a concept only ever exists in the store).
    def concept_source(agent, name, tenant: nil)
      insika[:knowledge_store]&.get(agent, name, tenant: tenant) || new_concept_template(name)
    end

    # An operator authoring a concept by hand starts as curated content, not
    # a claim to earn trust for — `provenance: policy`, full confidence, no
    # sources (nothing extracted it).
    def new_concept_template(name = "my-concept")
      Insika::Knowledge::Concept.render(
        name: name, description: "one sentence about what this concept says", type: "fact",
        body: "The durable claim, in your own words.",
        provenance: "policy", confidence: 1.0, sources: [], occurrences: 1,
        created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
      )
    end

    # A concept is flagged "conflict" status by the marker its own body
    # carries (§3.5) — no extra store field, the marker IS the flag.
    def concept_conflict?(parsed)
      parsed && parsed[:body].to_s.include?(Insika::Knowledge::CONTRADICTION_HEADING)
    end

    # The redirect/link target after a knowledge write or restore — back to
    # the concept's own detail pane when a name is known, else the index.
    def knowledge_path(agent, name, tenant)
      q = "agent=#{Rack::Utils.escape(agent.to_s)}"
      q += "&tenant=#{Rack::Utils.escape(tenant)}" if tenant
      name ? "/studio/knowledge/#{Rack::Utils.escape(name)}?#{q}" : "/studio/knowledge?#{q}"
    end

    # The evidence excerpt for a candidate — the origin sessions' messages at
    # the stored indexes, read at request time (D7: ids and indexes only).
    #
    # An index is validated by the miner as "fits at least one origin
    # session", so it must NOT be rendered against every origin session — the
    # same index would point at different conversations (the review fix).
    # Each index renders ONE message, from the first origin session where it
    # is in range, labeled with that session.
    def candidate_excerpt(candidate)
      Array(candidate.evidence_turns).filter_map do |i|
        session = Array(candidate.origin).filter_map { |sid| @sessions&.find(sid) }
                                          .find { |s| s.messages && s.messages[i] }
        next unless session

        [session.id, i, session.messages[i]["content"].to_s]
      end
    end

    # The negative list's rejection counts per rule, read from the RUN
    # records (D4 — the counts the Studio shows are what the engine logged:
    # the run carries { rule_id => count, "ungrounded" => N, ... }).
    def negative_rule_counts
      store = insika[:harvest_store]
      return {} unless store

      store.runs_for(@agent || "", limit: 200).each_with_object(Hash.new(0)) do |run, acc|
        Array(run.rejected).each { |rule, n| acc[rule] += n.to_i }
      end
    end

    # The excerpt for a proposal's evidence — the transcript messages at the
    # stored indexes, read at request time (D7: ids and indexes only are
    # stored). Deep-links to the existing session page.
    def proposal_excerpt(proposal)
      session = @sessions&.find(proposal.session_ref)
      return [] unless session && session.messages

      Array(proposal.evidence).filter_map do |i|
        session.messages[i] && session.messages[i]["content"].to_s
      end
    end

    # The agent's records across every status (a nil store reads as none).
    def followup_records(agent_id, _decl)
      store = insika[:followup_store]
      return [] unless store

      store.for_agent(tenant: presence(request.params["tenant"]) || "platform",
                      agent: agent_id)
    end

    # The A/B readout per arm (D3 — a read-only fold over the same records):
    #   sent         = fired count in the period;
    #   conversions  = outcome records whose session_id is a fired record's
    #                  session (primary-filtered by the   declaration
    #                  when one exists, else the first outcome per session);
    #   opt-outs     = contact cells flipped :revoked after a fired_at.
    # The note anchors the ruler outside the card: the A/B is the operator's;
    # this card reads the   baseline.
    def followup_ab(agent_id, _decl)
      store = insika[:followup_store]
      return {} unless store

      from = (Time.now.utc - 30 * 86_400).iso8601
      fired = store.for_agent(tenant: presence(request.params["tenant"]) || "platform",
                              agent: agent_id)
                .select { |r| r.status == "fired" && r.at.to_s >= from }
      fired.group_by(&:arm).each_with_object({}) do |(arm, records), acc|
        sessions = records.filter_map(&:session_id)
        acc[arm] = { sent: records.size, conversions: conversions_for(agent_id, sessions),
                     opt_outs: opt_outs_since(records) }
      end
    end

    # The conversions of the arm's fired sessions. Primary-filtered by the
    #   funnel declaration when the agent declares one; else the FIRST
    # outcome per session (an outcome record is one vote per session).
    def conversions_for(agent_id, sessions)
      outcomes = insika[:outcome_store]
      return 0 unless outcomes

      records = sessions.empty? ? [] : outcomes.all.select { |r| sessions.include?(r.session_id) }
      primary = primary_stage_for(agent_id)
      return records.count { |r| r.outcome == primary } if primary

      records.group_by(&:session_id).size
    end

    def primary_stage_for(agent_id)
      profile = insika[:profile_source]&.fetch(agent_id)
      decl = profile && Insika::FunnelDeclaration.parse(profile.funnel)
      decl && decl.primary
    end

    # The opt-outs of ONE arm: contact cells of the customers THAT ARM fired
    # to (same tenant), flipped :revoked after that customer's own fire. Never
    # a global revoked count — an unrelated opt-out (another tenant, another
    # customer) must not count against an arm, or the H-followup kill decision
    # reads strangers.
    def opt_outs_since(records)
      store = insika[:contact_store]
      return 0 unless store

      cells = store.cells
      # group this arm's fires by (tenant, customer) -> the earliest fire
      records.group_by { |r| [r.tenant, r.customer] }.sum do |(tenant, customer), recs|
        fired_at = recs.filter_map { |r| parse_time(r.fired_at || r.at) }.min
        next 0 if fired_at.nil?

        cell = cells["#{tenant}:#{customer}"]
        cell && cell["state"] == "revoked" && revoke_after?(cell, fired_at) ? 1 : 0
      end
    end

    def revoke_after?(cell, fired_at)
      updated = parse_time(cell["updated_at"])
      updated && updated > fired_at
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # Tenant list per agent, derived from the store cells (D7, the 0031 drill
    # pattern) — multi-tenant deployments show one card block per tenant; a
    # single-tenant deployment just "platform".
    def tenants_for(agent_id)
      cells = insika[:funnel_store]&.pairs.to_a || []
      cells.select { |c| c[:agent] == agent_id }.map { |c| c[:tenant] }
    end

    # Sums the folded counts over the period -> { stage => count } for the view.
    # A nil store (base wiring) reads as all-zero — the page still renders the
    # declaration and the freeze form.
    def funnel_period_counts(store, tenant, agent, period)
      return {} unless store

      today = Date.today.iso8601
      from = (Date.today - period).iso8601
      store.days(tenant: tenant, agent: agent, from: from, to: today)
           .each_with_object(Hash.new(0)) { |(_, counts), acc| counts.each { |s, n| acc[s] += n } }
    end

    # BudgetLedger's current counters (D6): "tokens today / this month". nil
    # store -> the view renders 0 (the empty state).
    def funnel_spend(store, tenant, agent)
      return { daily: 0, monthly: 0 } unless store

      store.current(tenant: tenant, agent: agent)
    end

    # the session's stage history — each outcome record of the
    # session folded to its stage by the agent's declaration (unmapped kinds
    # render the raw outcome with a muted note — the hole is visible).
    # Without a declaration the block renders the raw outcomes.
    def stage_history_for(sid)
      records = Array(insika[:outcome_store]&.all&.select { |r| r.session_id == sid })
                 .sort_by { |r| r.at.to_s }
      return [] if records.empty?

      agent = records.first.agent
      profile = insika[:profile_source]&.fetch(agent)
      decl = profile && Insika::FunnelDeclaration.parse(profile.funnel)
      {
        declaration: decl,
        rows: records.map do |r|
          stage = decl && decl.advance_on[r.outcome]
          { outcome: r.outcome, stage: stage, at: r.at, value: r.value }
        end
      }
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

    # parse_kv_lines moved to Studio::Forms.

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

    def agent_path(id, anchor = nil, query = nil)
      base = "/studio/agents/#{Rack::Utils.escape(id)}"
      base += "?#{query}" if query
      anchor ? "#{base}##{anchor}" : base
    end

    # "New from template": evaluates the template (same isolated
    # eval the CLI's `insika new` never even needs, since it just copies
    # files — this is the OTHER door) and imports every pack through the
    # SAME PackImporter a hand-written pack would use — E2's byte-identical
    # promise. mcp_instances ride separately (never part of a
    # pack, McpStore is its own store) — each dispatched as its own
    # :upsert_mcp, the same Command a Studio-authored instance would use
    # (Studio never writes a store directly). -> { agent_id: }, the
    # template's primary agent (Definition#id / System#id: the first
    # declared) — the redirect target when several agents were created.
    def create_agent_from_template(name)
      built = Insika::Templates.evaluate(name)
      packs = built.respond_to?(:to_packs) ? built.to_packs : [built.to_pack]
      importer = Insika::PackImporter.new(bus: insika[:command_bus], profiles: insika[:profile_source])
      packs.each { |pack| importer.import(pack) }
      declared_mcp = Array(built.mcp_instances)
      declared_mcp.each { |decl| dispatch(:upsert_mcp, decl) }
      { agent_id: built.id }
    end

    # Deterministic avatar hue: the id's fingerprint, so agents/sessions are
    # scannable at a glance (Linear-style). CSP forbids inline styles, so the
    # hue is a class: avatar-h0..avatar-h9 in application.css.
    def avatar_class(id)
      "avatar-h#{id.to_s.bytes.sum % 10}"
    end

    # Where a prompt POST lands back: the same file open in the drill, scrolled
    # to the prompts section. No file (a delete, say) → the agent page itself.
    def prompt_edit_path(id, file)
      name = presence(file)
      name ? "#{agent_path(id)}/prompts/#{Rack::Utils.escape(name)}#prompts" : agent_path(id, "prompts")
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

    # An MCP instance's env/headers (already MASKED) -> "KEY=value" text per
    # line, for the textarea. Sorts by key (stable across renders).
    def env_lines(env)
      (env || {}).sort.map { |k, v| "#{k}=#{v}" }.join("\n")
    end

    # An MCP instance's args (stdio argv) -> one token per line, for the textarea.
    def list_lines(list) = Array(list).join("\n")
  end
end
