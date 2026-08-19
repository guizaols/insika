# frozen_string_literal: true

require "json"
require "rack"
require "async"
require "securerandom"
require_relative "sse_body"
require_relative "tenant_auth" # WS1: Bearer -> { role:, tenant_id: } (single/multi-tenant)
require_relative "a2a/app" # A2A edge adapter (pulls protocol/errors/message/projection/card)
require_relative "responses" # OpenAI Responses adapter (/v1/responses) — drop-in for the OpenClaw gateway

module Insika
  module Server
    # Rack app. Transports ONLY
    # translate requests into Commands — the server holds no business
    # logic. It parses JSON, builds `Command.build(...)`, dispatches on the
    # CommandBus and projects the Event Stream to SSE. Reads are NOT Commands: they are
    # direct reads from the stores.
    #
    # AUDITABLE constitutional rule: `server/` does not import the Executor,
    # store WRITE methods, or RubyLLM. Requires: json, rack, async and the
    # core types (Command/Event/errors) already loaded by the composition root.
    class App
      SSE_HEADERS = {
        "content-type" => "text/event-stream",
        "cache-control" => "no-cache",
        "connection" => "keep-alive"
      }.freeze

      # Terminal events of a turn (close the task subscription in the
      # transport). The overflow :error self-closes its own subscription at the
      # EventStream (enqueues CLOSED), so it needs no entry here to end `each`.
      TERMINAL_EVENTS = %i[task_completed task_failed task_cancelled].freeze
      private_constant :TERMINAL_EVENTS

      # the `/v1` contract, versioned by date. A caller PINS behaviour
      # with `Insika-Version: YYYY-MM-DD` so a future breaking change does not move
      # silently underneath it; absent header = today's (only) version. Only one
      # entry exists so far — the day a second one is added, the routes that
      # changed branch on this value instead of being served whichever behaviour
      # happened to be current.
      KNOWN_VERSIONS = ["2026-08-08"].freeze
      private_constant :KNOWN_VERSIONS

      # the 500 envelope. A 500 is by definition unexpected — the client
      # cannot fix the request, so the contract is "you may retry, wait this
      # long, and quote this ref when you report it". The ref only means
      # anything because the same line goes to the server log (see #internal_error_response).
      RETRY_AFTER_SECONDS = 1
      private_constant :RETRY_AFTER_SECONDS

      # The operator control UI now lives in the Studio; server/ is a
      # pure transport surface (/v1, /a2a). The constitutional rule holds: server/
      # only READS stores and never imports the Executor, store writes, or RubyLLM.
      def initialize(command_bus:, event_stream:, session_store:, task_store:,
                     config:, pending_action_store: nil, a2a: nil, provisioner: nil,
                     workflow_registry: nil, onboarding: nil, profiles: nil,
                     channels: nil, logger: nil, token_store: nil, outcome_store: nil,
                     executor: nil, db_path: nil)
        @command_bus = command_bus
        @event_stream = event_stream
        @session_store = session_store
        @task_store = task_store
        @config = config
        @pending_action_store = pending_action_store # read for GET /v1/tasks/:id
        @a2a = a2a # A2A edge. nil = server does not expose A2A (parity).
        @provisioner = provisioner # PackImporter. nil = provisioning not exposed.
        # WS1 multi-tenant credentials. nil = single_tenant mode (the classic
        # single operator credential, gateway_token). Present = tokens resolve
        # from the store (per-tenant + operator), gateway_token still resolves
        # as operator (an existing deployment switching modes keeps its token).
        @token_store = token_store
        # "single_tenant" (default, parity) | "multi_tenant".
        @tenancy = config.fetch(:tenancy, "single_tenant")
        # READ-ONLY registry, injected only where workflows are
        # exposed (the minimal wiring). nil = no /v1/workflows routes (parity — the
        # deployment does not expose workflows). Reading a catalog is a READ, like a
        # store read: the constitutional rule (no Executor/store-writes/RubyLLM) holds.
        @workflow_registry = workflow_registry
        # LLM-first onboarding surface (start.md + models.json +
        # docs). PUBLIC (no auth — the whole point of the "read <base>/start.md" trick
        # is that the developer's coding agent can fetch it), and READ-ONLY, so the
        # constitutional rule holds. nil = routes not exposed (parity — the production
        # deployment opts in). Reading files/masked stores is a READ, like a store read.
        @onboarding = onboarding
        # READ-ONLY ProfileSource, so `GET /v1/agents/:id` can answer
        # what an agent has — the eval is a client and cannot read a store. Same
        # constitutional footing as the workflow registry: reading a catalog is a
        # READ. nil = the route 404s (parity).
        @profiles = profiles
        # ONE generic route family for every channel, opt-in by
        # injecting the registry (nil ⇒ the routes do not exist, parity with @a2a).
        # The channel does the translating; this class keeps doing only transport.
        @channels = channels
        # WS7: business outcomes per conversation (POST /v1/outcomes — a Control
        # command on the bus — and the tenant-scoped GET /v1/outcomes read).
        # nil = the routes 404 (parity).
        @outcome_store = outcome_store
        # where a 500's error_ref goes to be FOUND. nil = silent (parity for
        # embedders); the serving wirings pass $stdout. Class+message+backtrace
        # only — the ref never travels with request payloads (secrets stay out).
        @logger = logger
        #   GET /v1/vitals: process readings, operator-only, no store.
        # Both optional — nil means the body simply omits those readings.
        @executor = executor
        @db_path = db_path
        @heartbeat = config.fetch(:heartbeat, 15)
        @sync_timeout = config.fetch(:sync_timeout, 10) # synchronous control
      end

      # Explicit routing, NO framework: ~10 routes in a `case`. A single
      # `rescue` centralizes the error->status mapping. Only SYNCHRONOUS
      # errors (before the fiber) become HTTP status; a task failure travels as
      # an event on the stream and lands in GET /v1/tasks/:id.
      def call(env)
        req = Rack::Request.new(env)
        route(req)
      rescue JSON::ParserError => e
        error_response(400, e) # malformed JSON, before any dispatch
      rescue Insika::ValidationError => e
        error_response(422, e)
      rescue Insika::NotFoundError => e
        error_response(404, e)
      rescue Async::TimeoutError => e
        error_response(504, e) # synchronous control request exceeded the ceiling
      rescue StandardError => e
        internal_error_response(e)
      end

      private

      def route(req)
        # UTF-8, not the ASCII-8BIT Rack hands us. A path segment becomes a STORE KEY
        # (`/v1/agents/:id`, `/v1/sessions/:id`), and the sqlite3 driver binds a
        # BINARY string as a BLOB — which never matches a TEXT column. So every such
        # read answered 404 on a durable deployment while passing every spec, because
        # the in-memory store is a Ruby Hash and a binary string is `eql?` to its
        # UTF-8 twin. Found by calling `GET /v1/agents/:id` against a real database.
        segments = req.path_info.split("/").reject(&:empty?).map { |s| Coercion.utf8(s) }
        if segments.first == "v1"
          version_error = version_gate(req)
          return version_error if version_error
        end

                gate = public_route?(req.request_method, segments) ? nil : gateway_gate(req)
        return gate if gate
        # WS1: a TENANT principal is confined to its own runtime surfaces (chat
        # + its own reads). Every authoring/provisioning surface stays
        # operator-only — a tenant can never mint tokens, author tools or
        # change platform config. single_tenant (no principal) is untouched.
        if tenant_principal?(req) && !tenant_surface?(req.request_method, segments)
          return auth_error(403, "operator surface")
        end

        case [req.request_method, segments]
        in ["GET", ["up"]]
          health # readiness/liveness (Railway/k8s) — no auth, no store access
        in ["GET", ["start.md"]] if @onboarding
          markdown_response(200, @onboarding.start_md(base_url: public_base(req)))
        in ["GET", ["models.json"]] if @onboarding
          json_response(200, @onboarding.models_json(base_url: public_base(req)))
        in ["GET", ["docs"]] if @onboarding
          json_response(200, { docs: @onboarding.docs_index(base_url: public_base(req)) })
        in ["GET", ["docs", file]] if @onboarding && file.end_with?(".md")
          handle_doc(file)
        in ["POST", ["v1", "commands", type]]
          handle_command(req, type)
        in ["POST", ["v1", "sessions"]]
          handle_create_session(req)
        in ["POST", ["v1", "messages"]]
          handle_send_message(req)
        in ["GET", ["v1", "workflows"]] if @workflow_registry
          handle_list_workflows
        in ["POST", ["v1", "workflows", name]] if @workflow_registry
          handle_trigger_workflow(req, name)
        in ["POST", ["v1", "responses"]]
          handle_responses(req)
        in ["POST", ["v1", "outcomes"]] if @outcome_store
          handle_record_outcome(req)
        in ["GET", ["v1", "outcomes"]] if @outcome_store
          handle_list_outcomes(req)
        in ["POST", ["v1", "tools", "manifest"]]
          handle_import_tools(req)
        in ["POST", ["v1", "mcp", name, "import"]]
          handle_import_mcp_tools(req, name)
        in ["POST", ["v1", "agents"]] if @provisioner
          handle_provision(req)
        in ["DELETE", ["v1", "agents", id]] if @provisioner
          handle_deprovision(req, id)
        in ["GET", ["v1", "agents", id]] if @profiles
          handle_read_agent(id)
        in ["GET", ["v1", "sessions", id]]
          handle_read_session(req, id)
        in ["GET", ["v1", "tasks", id]]
          handle_read_task(req, id)
        in ["GET", ["v1", "events"]]
          handle_events(req)
        in ["GET", ["v1", "vitals"]]
          handle_vitals
        in ["POST", ["channels", id, "events"]] if @channels
          handle_channel_event(req, id)
        in ["POST", ["channels", id, "shadow-reply"]] if @channels
          handle_channel_shadow_reply(req, id)
        in ["POST", ["channels", id, "sessions"]] if @channels
          handle_channel_session(req, id)
        in ["POST", ["channels", id, "messages"]] if @channels
          handle_channel_message(req, id)
        in ["GET", ["channels", id, "asset", file]] if @channels
          handle_channel_asset(req, id, file)
        in ["OPTIONS", ["channels", id, *]] if @channels
          handle_channel_preflight(req, id)
        in ["POST", ["a2a"]] if @a2a
          handle_a2a(req)
        in ["GET", [".well-known", "agent-card.json"]] if @a2a
          json_response(200, @a2a.agent_card)
        else
          not_found # wrong method/route (or A2A not exposed -> @a2a nil)
        end
      end

      # The ONLY routes that answer without the gateway Bearer. Everything else is gated
      # in `route`, before the dispatch — an ALLOWLIST, because the previous shape (each
      # handler calling `gateway_gate` itself) is a rule you have to remember: the generic
      # `POST /v1/commands/:type` never called it, so every authoring Command
      # (`write_agent_file`, `upsert_llm_provider`, `delete_agent`…) was reachable by
      # anyone who knew the URL, as were the session/task/event reads. A route added
      # tomorrow is closed by default; making it public is now a deliberate edit here.
      #
      # `/up` is the health probe (no store access). The onboarding surface is opt-in
      # (INSIKA_ONBOARDING) and exists to be read by a coding agent before it has any
      # credential — turning it on is the operator choosing to publish it.
      PUBLIC_ROUTES = [
        ["GET", ["up"]],
        ["GET", ["start.md"]],
        ["GET", ["models.json"]],
        ["GET", ["docs"]],
        ["GET", [".well-known", "agent-card.json"]] # A2A discovery: the card is the ad
      ].freeze

      def public_route?(method, segments)
        return true if PUBLIC_ROUTES.include?([method, segments])
        return true if channel_route?(method, segments)

        method == "GET" && segments.length == 2 && segments.first == "docs"
      end

      # A channel route skips the GATEWAY bearer because the channel authenticates
      # it ITSELF — with the platform's own scheme (a relay's shared secret, a Slack
      # HMAC signature, the widget's origin allowlist plus its mandatory rate limit),
      # which is the only credential the caller has. Requiring the gateway token here
      # instead would mean handing every platform — and every anonymous browser — a
      # second secret it has no way to send.
      #
      # This is NOT an ungated route family: every handler below calls `channel_gate`
      # before parsing anything, and a channel that implements no `authenticate`, or
      # whose credential is unconfigured, answers `:disabled` rather than open.
      # ENUMERATED rather than prefix-matched, so a route added to this family
      # tomorrow is gated by default and publishing it is a deliberate edit here.
      def channel_route?(method, segments)
        case [method, segments]
        in ["POST", ["channels", _, "events" | "sessions" | "messages" | "shadow-reply"]] then true
        in ["GET", ["channels", _, "asset", _]] then true
        in ["OPTIONS", ["channels", _, *]] then true # CORS preflight carries no credential, by spec
        else false
        end
      end

      # Bearer-gate error (503 disabled / 401 unauthorized), shared by the
      # gateway surfaces. JSON body, fail-closed.
      def auth_error(status, message, extra_headers = {})
        [status,
         { "content-type" => "application/json" }.merge(extra_headers),
         [JSON.generate(error: { class: "Insika::Error", message: message })]]
      end

      # POST /v1/commands/:type — generic: every new Command is born with a
      # transport. The control vs turn distinction is BY THE SHAPE of the result (the
      # transport knows no semantics).
      #
      # The principal's tenant is stamped like on every other surface. It is
      # nil for an operator (this route is operator-only — see TENANT_SURFACES),
      # which is exactly why a tenant-scoped command such as `forget_customer`
      # ALSO reads a `tenant` from its payload: over HTTP the operator names the
      # tenant, because the credential does not carry one.
      def handle_command(req, type)
        command = Insika::Command.build(type.to_sym, parse_body(req), transport: :http,
                                                                      tenant: req_tenant(req))
        command_response(dispatch_with_timeout(command))
      end

      # POST /v1/outcomes — the operator or the integration records a business
      # outcome for a conversation (WS7). A Control command on the bus, tenant
      # stamped from the principal (WS1) — additive, outside the response
      # contract: the engine transports the outcome, never interprets it.
      # 201 { outcome: { agent, outcome, value, session_id, at } }.
      def handle_record_outcome(req)
        command = Insika::Command.build(:record_outcome, parse_body(req), transport: :http,
                                         tenant: req_tenant(req))
        record = dispatch_with_timeout(command)
        json_response(201, { outcome: { agent: record.agent, outcome: record.outcome,
                                        value: record.value, session_id: record.session_id,
                                        at: record.at } })
      end

      # GET /v1/outcomes[?agent=] — the Studio scorecard's data: the LAST
      # outcome per agent (state cards) + the per-day series. Tenant-scoped
      # (WS1): a tenant principal reads only its own outcomes.
      def handle_list_outcomes(req)
        tenant = req_tenant(req)
        agent = req.GET["agent"]
        latest = @outcome_store.latest_per_agent(tenant: tenant)
        latest = { agent => latest[agent] }.compact if agent && !agent.empty?
        series = @outcome_store.series(tenant: tenant, agent: agent)
        json_response(200, { latest: latest, series: series })
      end

      # POST /v1/sessions — sugar for create_session; 201 {session}.
      def handle_create_session(req)
        body = parse_body(req)
        tenant = req_tenant(req)
        # WS1: a tenant's session must be born under its OWN "<tenant>:" namespace
        # — the read path (GET /v1/sessions/:id) refuses anything else. Scope the
        # caller's id the same way message_flow scopes a session_id; a tenant that
        # passed none gets a namespaced uuid instead of an unprefixed one it could
        # never read back.
        if tenant
          id = body[:id] || body["id"]
          id = Insika::Coercion.blank?(id) ? scoped_session_id(tenant, SecureRandom.uuid)
                                           : scoped_session_id(tenant, id)
          body = body.merge(id: id)
        end
        command = Insika::Command.build(:create_session,
                                         { vars: body[:vars] || {}, id: body[:id] }.compact,
                                         transport: :http, tenant: tenant)
        session = dispatch_with_timeout(command)
        json_response(201, { session: session.to_h })
      end

      # POST /v1/messages — sugar for send_message; ?stream missing/"true" -> SSE,
      # "false" -> 200 JSON aggregated at the terminal event.
      def handle_send_message(req)
        stream = req.GET["stream"] != "false"
        # only the aggregated-JSON form has room for the `merged`/`steered`
        # verdict, so only it may join a message to another turn. Once the stream is open
        # there is no way to tell the caller it does not own the reply.
        message_flow(parse_body(req), stream: stream, transport: stream ? :http : :"http:json",
                                      tenant: req_tenant(req))
      end

      # GET /docs/:name.md — one public doc as raw markdown. The
      # slug is a KEY of the onboarding allowlist, so no filesystem traversal is
      # possible; an unknown slug -> 404. `file` still carries the ".md" suffix.
      def handle_doc(file)
        markdown = @onboarding.doc(file.sub(/\.md\z/, ""))
        return not_found if markdown.nil?

        markdown_response(200, markdown)
      end

      # Public base url for the interpolated onboarding links. Prefers an explicit
      # config[:public_url] (behind a proxy/TLS terminator the request scheme is the
      # internal http), else the request's own base_url.
      def public_base(req)
        Insika::Coercion.presence(@config[:public_url]) || req.base_url
      end

      # GET /v1/workflows — discovery. Direct read of the
      # registry catalog (name + description + the I/O schema contract). Not a
      # Command; opt-in via the injected registry.
      def handle_list_workflows
        json_response(200, { workflows: @workflow_registry.catalog })
      end

      # POST /v1/workflows/:name — triggers a workflow RUN. The name comes from the
      # ROUTE; agent/input/session_id from the body. Two shapes:
      #   · default        -> 202 { run_id, task_id } immediately (async at-most-once
      #     run; observe via GET /v1/tasks/:run_id or GET /v1/events?task_id=:run_id).
      #   · ?stream=true    -> SSE of the run's events (incl. :workflow_started /
      #     :workflow_completed), closing at the terminal event.
      # A bad input (input_schema) is a synchronous 422 with no run (WorkflowSchemaError
      # -> ValidationError in #call); an unknown workflow/agent -> 404/422.
      def handle_trigger_workflow(req, name)
        body = parse_body(req)
        payload = { workflow: name, agent: body[:agent],
                    input: body[:input], session_id: body[:session_id] }.compact
        workflow_flow(payload, stream: req.GET["stream"] == "true",
                               tenant: req_tenant(req))
      end

      # POST /v1/responses — OpenAI Responses adapter (drop-in for the OpenClaw
      # gateway). Bearer via `config[:gateway_token]` (fail-closed). Translates
      # the request -> :send_message and the turn's
      # Event Stream -> OpenAI Responses SSE. Always streams (the consumer asks for SSE).
      def handle_responses(req)
        gate = gateway_gate(req)
        return gate if gate

        parsed = Responses.parse_request(parse_body(req), req) # ValidationError -> 422
        tenant = req_tenant(req)
        ensure_session(parsed[:user], tenant: tenant)
        payload = { agent: parsed[:agent], session_id: parsed[:user], message: parsed[:message] }
        payload[:origin] = parsed[:origin] if parsed[:origin] # declared, else absent
        payload[:customer] = parsed[:customer] if parsed[:customer] # WS8: the memory scope handle
        payload[:parts] = parsed[:parts] if parsed[:parts] # WS9: multimodal content parts
        payload[:source] = parsed[:source] if parsed[:source] # WS9: voice-marked text
        payload[:channel] = parsed[:channel] if parsed[:channel] # WS9 (saída): the channel's output capabilities
        message_flow(payload, stream: true, serialize: Responses.method(:frame_for),
                              tenant: tenant)
      end

      # POST /v1/agents — provisions (upserts) an agent from a standardized
      # PACK. Same Bearer as /v1/responses (gateway_token,
      # fail-closed). The consumer (GatewayClient/ProvisionStore) sends the pack as
      # JSON; the PackImporter emits the authoring Commands. -> 200 { summary }.
      # Raw body (string keys): the pack's file/skill names are data keys,
      # not symbols.
      def handle_provision(req)
        gate = gateway_gate(req)
        return gate if gate

        pack = Insika::Pack.from_h(parse_raw_body(req))
        json_response(200, @provisioner.import(pack)) # Validation/NotFound -> 422/404 in #call
      end

      # POST /v1/tools/manifest — BATCH ingestion of data-tools via manifest
      # Same Bearer as provisioning (gateway_token, fail-
      # closed): it's an authoring/provisioning surface and resolves the
      # deployment's secrets. RAW body (string keys): the JSON Schema property names and
      # the headers are DATA, not symbols. Dispatches :import_tools -> 200 { per-tool
      # report }. Structural manifest error -> 422 via the #call rescue; per-tool
      # failure stays isolated in `errors[]` (R4). Dynamic base_url: the egress guard
      # + host_allowlist block destinations outside the allowlist at CALL time (R5).
      def handle_import_tools(req)
        gate = gateway_gate(req)
        return gate if gate

        command = Insika::Command.build(:import_tools, parse_raw_body(req), transport: :http)
        json_response(200, dispatch_with_timeout(command))
      end

      # POST /v1/mcp/:name/import — LIVE MCP ingestion. Same
      # Bearer as provisioning (gateway_token, fail-closed): it's an authoring
      # surface. Discovers the tools of the MCP instance `:name` (via a client injectable
      # at the composition root) and ingests them as data-tools (reuses :import_tools:
      # upsert + hot reload). Dispatches :import_mcp_tools -> 200 { per-tool report
      # + instance }. Missing instance -> 404; disabled/no-url -> 422; per-tool
      # failure isolated in `errors[]` (R4). The name comes from the ROUTE (data), not the body.
      def handle_import_mcp_tools(req, name)
        gate = gateway_gate(req)
        return gate if gate

        command = Insika::Command.build(:import_mcp_tools, { name: name }, transport: :http)
        json_response(200, dispatch_with_timeout(command))
      end

      # DELETE /v1/agents/:id — removes the agent (delete_agent). NotFoundError
      # (missing) -> 404 via the #call rescue.
      def handle_deprovision(req, id)
        gate = gateway_gate(req)
        return gate if gate

        json_response(200, @provisioner.delete(id))
      end

      # GET /v1/agents/:id — what this deployment HAS for that agent, so an eval
      # (a client: it never reads a store) can tell "this case cannot run here" from
      # "this case failed". Deliberately NOT the profile: the prompt,
      # the model and the guardrail config are none of the caller's business. Just the
      # two facts a case declares `requires` against.
      #
      # `tools` is the DECLARED allowlist, and `null` means the agent has an open one
      # (every registered tool) — the client reads that as "cannot rule anything out"
      # and runs the case rather than skipping it.
      def handle_read_agent(id)
        profile = @profiles.fetch(id)
        raise Insika::NotFoundError, "agent not found: #{id}" if profile.nil?

        allow = profile.tools_allow
        deny = Array(profile.tools_deny).map(&:to_s)
        json_response(200, {
                        id: profile.id,
                        tools: allow.nil? ? nil : (Array(allow).map(&:to_s) - deny),
                        capabilities: Array(profile.capabilities_declared).map(&:to_s)
                      })
      end

      # `/v1` only — `/a2a` is versioned by its own JSON-RPC spec and a channel's
      # shape is the platform's, so neither reads this header. Runs BEFORE the
      # gateway gate: which version the caller asked for is a contract question,
      # answerable regardless of whether the request is authorized. Absent header
      # -> nil (current behaviour); an unknown value -> 400, not a silent fallback.
      def version_gate(req)
        version = req.get_header("HTTP_INSIKA_VERSION")
        return nil if Coercion.blank?(version) || KNOWN_VERSIONS.include?(version)

        error_response(400, Insika::ValidationError.new("unknown Insika-Version: #{version.inspect}"))
      end

      # Gateway Bearer (fail-closed). -> error response (503/401) OR nil when
      # ok (the handler proceeds). In multi_tenant mode the resolved principal
      # is stashed on the request env: `tenant_principal?`/`req_tenant` read it
      # back for the surface gate and the command stamping.
      def gateway_gate(req)
        result = Insika::Server::TenantAuth.check(@config[:gateway_token], @token_store,
                                                  req.get_header("HTTP_AUTHORIZATION"))
        case result
        when :disabled then auth_error(503, "gateway disabled")
        when :unauthorized then auth_error(401, "unauthorized", "www-authenticate" => "Bearer")
        else
          req.set_header("insika.principal", result)
          nil
        end
      end

      # -> bool: is the requester a TENANT principal (multi_tenant mode only)?
      # The surface gate and the session/task read gates consume it; an operator
      # principal is NOT a tenant (it has the run of the deployment, exactly as
      # in single_tenant mode).
      def tenant_principal?(req)
        p = req.get_header("insika.principal")
        p && p[:role] == "tenant"
      end

      # The tenant the request operates AS: nil for an operator/classic request.
      def req_tenant(req)
        p = req.get_header("insika.principal")
        p && p[:role] == "tenant" ? p[:tenant_id] : nil
      end

      # A tenant may reach ONLY its own runtime surfaces. Everything else
      # (commands, provisioning, authoring, config) is the operator's. An
      # unknown route is NOT here -> a tenant is refused (the surface exists —
      # just not for them), not told it is missing.
TENANT_SURFACES = [
        ["POST", ["v1", "sessions"]],
        ["POST", ["v1", "messages"]],
        ["POST", ["v1", "responses"]],
        ["POST", ["v1", "outcomes"]],
        ["GET", ["v1", "outcomes"]],
        ["POST", ["v1", "workflows", nil]],
        ["GET", ["v1", "workflows"]],
        ["GET", ["v1", "sessions", nil]],
        ["GET", ["v1", "tasks", nil]],
        ["GET", ["v1", "events"]]
      ].freeze
      private_constant :TENANT_SURFACES

      def tenant_surface?(method, segments)
        TENANT_SURFACES.any? do |m, s|
          m == method && s.zip(segments).all? { |pattern, got| pattern.nil? || pattern == got }
        end
      end

      # Session id namespacing (WS1): a tenant's session lives under
      # "<tenant>:<id>", so two tenants using the SAME chat id never share a
      # session — the key itself is the isolation, not a convention. ":"
      # (never "/") so the id stays one URL path segment; the same delimiter
      # convention as the channels' "<channel>:<external_id>". Idempotent (a
      # caller passing its own namespaced id back is not double-prefixed).
      def scoped_session_id(tenant, id)
        return id if tenant.nil? || id.nil? || id.to_s.empty?
        return id if id.to_s.start_with?("#{tenant}:")

        "#{tenant}:#{id}"
      end

      # POST /channels/:id/events — the Shape B inbound webhook.
      # ACK FAST and never the reply: the platform (or the relay consumer) is holding
      # a connection open with a retry timer on it, so this dispatches the turn and
      # answers with its id. The answer itself leaves later, out of band, through the
      # channel's own `deliver`.
      #
      # The channel does ALL the translating — auth, envelope, session correlation —
      # and this handler stays what `server/` is allowed to be: a route that turns a
      # request into a Command. Four answers, and each one is a different fact:
      #   202 {task_id}            a turn is running; its reply will be delivered
      #   200 {task_id, duplicate} we already ran this event id
      #   200 {task_id, merged}    it joined a turn at the door
      #   200 {task_id, steered}   it was appended to a turn already running
      # A consumer that treats the last three as 202 delivers the same answer twice.
      def handle_channel_event(req, id)
        channel = @channels.find(id)
        return not_found if channel.nil?

        gate = channel_gate(channel, req)
        return gate if gate

        parsed = channel.parse(req, body: parse_raw_body(req)) # ValidationError -> 422
        session_id = channel.session_id_for(parsed[:external_id])
        ensure_session(session_id, vars: session_vars(id, parsed))

        payload = { agent: parsed[:agent], session_id: session_id,
                    message: parsed[:message], event_id: parsed[:event_id] }.compact
        ack = channel_ack(payload, transport: :"channel:#{id}")
        # in shadow the mirror's own reply may ride the SAME call
        # (Shape 1) — recorded before we answer, through the one command.
        if channel.respond_to?(:shadow?) && channel.shadow?
          dispatch_shadow_reply(id, parsed) if parsed[:incumbent_reply]
          return shadow_ack(ack)
        end
        ack
      end

      # POST /channels/:id/shadow-reply — the mirror contract's fallback (Shape 2),
      # for a consumer that mirrors the exchange BEFORE it answers the customer.
      # Same channel_gate (auth is the channel's, not the route's); 404 unless the
      # channel is in shadow — the same parity every other optional surface has.
      def handle_channel_shadow_reply(req, id)
        channel = @channels.find(id)
        return not_found if channel.nil? || !(channel.respond_to?(:shadow?) && channel.shadow?)

        gate = channel_gate(channel, req)
        return gate if gate

        parsed = channel.parse_shadow_reply(req, body: parse_raw_body(req)) # ValidationError -> 422
        result = dispatch_shadow_reply(id, parsed)
        json_response(202, { pair_id: result[:pair_id], status: result[:status] })
      end

      # The incumbent half rides ONE command whatever shape it arrived in, so
      # server/ never writes to a store and both doors share one behaviour.
      def dispatch_shadow_reply(id, parsed)
        @command_bus.dispatch(
          Insika::Command.build(:record_shadow_reply,
                                { channel: id.to_s, external_id: parsed[:external_id],
                                  event_id: parsed[:event_id], reply: parsed[:incumbent_reply] || parsed[:reply],
                                  at: parsed[:at] }.compact,
                                transport: :"channel:#{id}")
        )
      end

      # 202 -> 200 {task_id, shadow: true}: a consumer wired to "202 means a
      # reply is coming" must not be silently misled. The duplicate/merged/
      # steered verdicts pass through untouched (they already say 200).
      def shadow_ack(ack)
        status, _headers, body = ack
        return ack unless status == 202

        json_response(200, JSON.parse(body.join).merge("shadow" => true))
      end

      # POST /channels/:id/sessions — mint a conversation for a PUBLIC Shape A
      # channel. The engine issues the id and the client never
      # proposes one: an endpoint that created a session from a caller-supplied id
      # would let anyone read someone else's conversation by guessing.
      #
      # Only a channel that mints answers here — the relay's id is the consumer's own
      # key, so `/sessions` does not exist for it (404, the same parity every other
      # optional surface has).
      def handle_channel_session(req, id)
        channel = @channels.find(id)
        return not_found if channel.nil? || !channel.respond_to?(:mint_session_id)

        gate = channel_gate(channel, req)
        return cors(channel, req, gate) if gate

        session_id = channel.mint_session_id
        ensure_session(session_id, vars: { "channel" => id.to_s })
        cors(channel, req, json_response(201, { session_id: session_id }))
      end

      # POST /channels/:id/messages — the Shape A turn: the reply comes back on THIS
      # connection as SSE, so there is no outbox and nothing to deliver later. It is
      # `handle_responses` with the hardcoded `Responses` module swapped for the
      # looked-up channel, which is the whole point of naming the seam.
      #
      # The session must already exist AND belong to this channel. Both halves
      # matter: create-on-write would reopen the enumeration hole `/sessions` closes,
      # and skipping the ownership check would let a widget visitor stream a
      # relay customer's conversation by pasting its id.
      def handle_channel_message(req, id)
        channel = @channels.find(id)
        return not_found if channel.nil? || !channel.respond_to?(:frame_for)

        gate = channel_gate(channel, req)
        return cors(channel, req, gate) if gate

        parsed = channel.parse(req, body: parse_raw_body(req))
        return cors(channel, req, error_response(404, unknown_session)) unless channel_session?(id, parsed[:session_id])

        payload = { agent: parsed[:agent], session_id: parsed[:session_id], message: parsed[:message] }
        cors(channel, req, message_flow(payload, stream: true, transport: :"channel:#{id}",
                                                 serialize: channel.method(:frame_for)))
      rescue Insika::ValidationError => e
        # Answered here rather than through #call's rescue so the CORS headers ride
        # along: without them the browser cannot read the 422 and the visitor sees a
        # generic network failure instead of what was wrong.
        cors(channel, req, error_response(422, e))
      end

      # GET /channels/:id/asset/:f — the channel's static file (the widget's JS).
      # The name is a KEY of the channel's own closed map, never a path, so there is
      # no traversal to find. Public and unauthenticated by nature: it is a
      # `<script src>` on someone else's page.
      # The cache policy is short and the ETag does the rest: the URL carries no
      # version (the install snippet an adopter pasted has none), so a long max-age
      # would strand every browser on the widget it already has, while a revalidation
      # that answers 304 costs one empty round trip and ships an upgrade in minutes.
      def handle_channel_asset(req, id, file)
        channel = @channels.find(id)
        return not_found if channel.nil? || !channel.respond_to?(:asset)

        asset = channel.asset(file)
        return not_found if asset.nil?

        headers = { "content-type" => asset[:content_type],
                    "cache-control" => asset[:cache_control] || "no-cache",
                    "etag" => asset[:etag] }.compact
        return [304, headers, []] if asset[:etag] && req.get_header("HTTP_IF_NONE_MATCH") == asset[:etag]

        [200, headers, [asset[:body]]]
      end

      # OPTIONS /channels/:id/* — the CORS preflight. Answered BEFORE the channel's
      # own check on purpose: a preflight carries no credentials (the browser strips
      # them, by spec), so gating it would only mean the real request never happens.
      # It grants nothing — an origin off the allowlist gets no headers back and the
      # browser refuses the response itself.
      def handle_channel_preflight(req, id)
        channel = @channels.find(id)
        return not_found if channel.nil?

        cors(channel, req, [204, {}, []])
      end

      # Does this session exist AND belong to this channel? `vars["channel"]` is
      # written when the session is minted.
      def channel_session?(id, session_id)
        session = session_id && @session_store.find(session_id)
        return false if session.nil?

        vars = session.vars || {}
        (vars["channel"] || vars[:channel]).to_s == id.to_s
      end

      def unknown_session = Insika::NotFoundError.new("session not found")

      # Merges the channel's CORS headers into a response it is about to return. A
      # channel with no opinion (the relay: its consumer is a server, not a browser)
      # changes nothing.
      def cors(channel, req, response)
        return response unless channel.respond_to?(:cors_headers)

        headers = channel.cors_headers(req.get_header("HTTP_ORIGIN"))
        return response if headers.nil? || headers.empty?

        status, existing, body = response
        [status, existing.merge(headers), body]
      end

      # The channel's OWN credential check. A channel returns a verdict, not a status
      # code — HTTP is this file's vocabulary, not lib/'s — and a channel that never
      # implements one is refused rather than defaulted open: an unauthenticated
      # public inbound route with an LLM behind it is a money faucet.
      def channel_gate(channel, req)
        verdict = channel.respond_to?(:authenticate) ? channel.authenticate(req) : :disabled
        case verdict
        when :disabled then auth_error(503, "channel disabled")
        when :unauthorized then auth_error(401, "unauthorized", "www-authenticate" => "Bearer")
        end
      end

      # Dispatch + ack, with NO subscription: nothing about this request waits for the
      # turn. That is the difference between Shape B and every other surface here.
      def channel_ack(payload, transport:)
        result = @command_bus.dispatch(Insika::Command.build(:send_message, payload, transport: transport))
        verdict = %i[duplicate merged steered].find { |k| result[k] }
        return json_response(200, { task_id: result[:task_id], verdict => true }) if verdict

        json_response(202, { task_id: result[:task_id] })
      end

      # `channel` + `external_id` on the session are how a later turn
      # (and the outbox) know where a reply goes. The consumer's own `vars` ride along
      # on first contact, but never over those two — a caller must not be able to
      # rewrite its own conversation's address.
      def session_vars(channel_id, parsed)
        (parsed[:vars] || {}).merge("channel" => channel_id.to_s,
                                    "external_id" => parsed[:external_id].to_s)
      end

      # Session correlated by an explicit id (`user`=chat.id on /v1/responses, the
      # namespaced `<channel>:<external_id>` for a channel): creates if new, continues
      # if it exists (multi-turn). Via Command (server/ does not write to a store).
      # Benign race (two near-simultaneous turns creating) -> ArgumentError from the
      # store, treated as "already exists". A TENANT's id is namespaced (WS1), so
      # two tenants with the same chat id get two isolated sessions.
      def ensure_session(id, vars: { channel: "responses" }, tenant: nil)
        id = scoped_session_id(tenant, id)
        return if @session_store.find(id)

        @command_bus.dispatch(
          Insika::Command.build(:create_session, { id: id, vars: vars }, transport: :http,
                                tenant: tenant)
        )
      rescue ArgumentError
        nil
      end

      # GET /v1/sessions/:id — direct read (not a Command). A tenant may only
      # read its OWN sessions: the ownership is the id namespace itself (its
      # sessions live under "<tenant>:…"), anything else reads as a 404.
      def handle_read_session(req, id)
        tenant = req_tenant(req)
        if tenant && !id.to_s.start_with?("#{tenant}:")
          raise Insika::NotFoundError, "session not found: #{id}"
        end

        session = @session_store.find(id)
        raise Insika::NotFoundError, "session not found: #{id}" if session.nil?

        json_response(200, { session: session.to_h })
      end

      # GET /v1/tasks/:id — direct read. This is where the consumer observes
      # PolicyDenied/post-202 failures: the terminal state lives in the Task
      # Store; nothing is lost if the client disconnected. A tenant may only
      # read a task its own command stamped (the task record carries the
      # command with its meta.tenant) — someone else's reads as a 404.
      def handle_read_task(req, id)
        task = @task_store.find(id)
        raise Insika::NotFoundError, "task not found: #{id}" if task.nil?

        tenant = req_tenant(req)
        if tenant && task_tenant(task) != tenant
          raise Insika::NotFoundError, "task not found: #{id}"
        end

        body = { task: task_to_h(task) }
        # pending approvals: this is where the consumer/operator sees
        # what needs approval after an :approval_requested.
        if @pending_action_store
          body[:pending_actions] = @pending_action_store.open_for(id).map(&:to_h)
        end
        json_response(200, body)
      end

      # The tenant stamped on the task's persisted command (WS1): string or
      # symbol keys, whichever the store round-trip produced.
      def task_tenant(task)
        command = task.respond_to?(:command) ? task.command : nil
        return nil unless command.is_a?(Hash)

        meta = command["meta"] || command[:meta] || {}
        meta["tenant"] || meta[:tenant]
      end

      # GET /v1/events?task_id=&session_id= — here the filters ARE known.
      # CONTINUOUS stream (post-crash reconnection route): does not close on a
      # terminal event — ends on client disconnect or cap. A tenant's stream is
      # scoped to its own events (fail-closed on the event's meta.tenant).
      def handle_events(req)
        subscription = @event_stream.subscribe(task_id: req.GET["task_id"],
                                                session_id: req.GET["session_id"],
                                                tenant: req_tenant(req))
        sse_response(subscription)
      end

      # POST /a2a — JSON-RPC 2.0: HTTP 200 ALWAYS (the error travels in the envelope,
      # not in the status). Malformed JSON -> -32700 (A2A envelope, not the generic
      # HTTP error of #call). The A2A::App never leaks an exception. Parse with STRING
      # keys (the A2A wire is generic JSON — does NOT reuse `parse_body`, which
      # symbolizes for Command payloads).
      def handle_a2a(req)
        raw = req.body&.read
        body =
          begin
            raw.nil? || raw.empty? ? {} : JSON.parse(raw)
          rescue StandardError
            return json_response(200, A2A::Protocol.error(nil, A2A::Errors::PARSE_ERROR, "parse error"))
          end
        json_response(200, @a2a.rpc(body))
      end

      # --- Turn flow (SSE or aggregated) ------------------------------------

      # Subscribe BEFORE dispatching: under Async the task fiber may
      # run eagerly and emit :task_started before dispatch returns. The
      # task_id only exists AFTER dispatch -> subscribe WITHOUT a filter and filter in the
      # transport (TaskFilter). A SYNCHRONOUS handler error (Validation/NotFound)
      # happens here, BEFORE the SSE opens -> closes the subscription and propagates to the
      # #call rescue (becomes an HTTP status).
      def message_flow(payload, stream:, serialize: nil, transport: :http, tenant: nil)
        # WS9: content parts are CONTRACT at the edge — the closed shape is
        # validated here (422) before the command is built; the engine stays
        # lenient for transports that bypass this surface.
        parts = payload[:parts] || payload["parts"]
        if parts && !Insika::Media.well_formed?(parts)
          raise Insika::ValidationError,
                "malformed content part — each part must be {type: text|image|audio} with text/url"
        end
        # WS9: the only declared message source is "voice" (pre-transcribed
        # audio) — a consumer that writes prose here is told so, not silently.
        source = payload[:source] || payload["source"]
        if source && source.to_s != "voice"
          raise Insika::ValidationError, 'source must be "voice"'
        end
        # WS9 (saída): the channel's declared OUTPUT media capabilities. The
        # closed list IS the "abstraction admits only what leaks" rule: an
        # unknown value is refused here (422), never silently ignored; a
        # declared value is what the executor may wire (generate_image/tts).
        channel = payload[:channel] || payload["channel"]
        if channel.is_a?(Hash)
          caps = Insika::Media.channel_capabilities(channel)
          unknown = caps - Insika::Media::OUTPUT_CAPABILITIES
          unless unknown.empty?
            raise Insika::ValidationError,
                  "unknown channel capability: #{unknown.join(', ')}"
          end

          payload = payload.dup
          payload[:channel] = { capabilities: caps }
        end
        # WS1: a tenant's session_id is NAMESPACED before the command is built,
        # so the turn lands on the tenant's OWN session even when another tenant
        # uses the same chat id. The payload the caller sent is untouched.
        if tenant
          payload = payload.dup
          payload[:session_id] = scoped_session_id(tenant, payload[:session_id]) if payload[:session_id]
        end
        command = Insika::Command.build(:send_message, payload, transport: transport, tenant: tenant)
        subscription = @event_stream.subscribe
        result =
          begin
            @command_bus.dispatch(command)
          rescue StandardError
            subscription.close
            raise
          end

        # the message joined another turn — one still waiting at the
        # door (`merged`) or one already running (`steered`). Either way this call
        # owns no reply; the one holding `task_id` does. Say exactly that and open no
        # stream: a caller that delivered this response's (empty) output would
        # duplicate the answer.
        if result[:merged] || result[:steered]
          subscription.close
          verdict = result[:merged] ? :merged : :steered
          return json_response(200, { task_id: result[:task_id], verdict => true })
        end

        task_id = result[:task_id]
        # Bind the subscription to the task_id now that it exists: the cap now
        # counts only events for THIS task and the overflow :error goes out with the
        # right task_id. The already-enqueued events (eager fiber) belong to this task —
        # none is lost.
        subscription.bind(task_id: task_id)
        filtered = TaskFilter.new(subscription, task_id)
        stream ? sse_response(filtered, serialize: serialize) : aggregate_response(filtered, task_id)
      end

      # Workflow trigger flow. Async by default (the honest workflow
      # contract: fire the run, return the runId); ?stream=true streams the run's
      # events like a turn. Same subscribe-before-dispatch discipline as
      # message_flow so no eager event is lost when streaming. A synchronous handler
      # error (bad input / unknown workflow) closes the subscription and propagates
      # to #call (HTTP status).
      def workflow_flow(payload, stream:, tenant: nil)
        # WS1: same session-id namespacing as message_flow — the workflow's run
        # session is the tenant's own.
        if tenant
          payload = payload.dup
          payload[:session_id] = scoped_session_id(tenant, payload[:session_id]) if payload[:session_id]
        end
        command = Insika::Command.build(:trigger_workflow, payload, transport: :http, tenant: tenant)

        unless stream
          result = dispatch_with_timeout(command)
          return json_response(202, { run_id: result[:run_id] || result[:task_id], task_id: result[:task_id] })
        end

        subscription = @event_stream.subscribe
        result =
          begin
            @command_bus.dispatch(command)
          rescue StandardError
            subscription.close
            raise
          end
        task_id = result[:task_id]
        subscription.bind(task_id: task_id)
        sse_response(TaskFilter.new(subscription, task_id))
      end

      # stream=false: aggregates by iterating the filtered subscription in the
      # request's own fiber. Accumulates :content deltas; responds at the
      # terminal. The `error:` shape mirrors the :task_failed data (smallest
      # coherent extension — the state is also in GET /v1/tasks/:id). Non-happy
      # terminals (:task_cancelled, overflow :error) also become `error:` —
      # a cancelled/truncated turn is NEVER reported as a 200 success.
      def aggregate_response(subscription, task_id)
        content = +""
        events = []
        error = nil

        subscription.each do |event|
          events << event.to_h
          case event.type
          when :content        then content << event.data[:delta].to_s
          when :task_failed
            error = { class: event.data[:error], message: event.data[:message] }
            # A8: the classification rides through when the executor wrapped
            # the failure (ProviderError) — additive for every other terminal.
            error = error.merge(event.data.slice(:kind, :retryable, :retry_after))
          when :task_cancelled then error = { class: "Insika::CancelledError", message: "task cancelled" }
          when :error          then error ||= { class: nil, message: event.data[:message] }
          end
        end

        if error
          json_response(200, { task_id: task_id, events: events, error: error })
        else
          json_response(200, { content: content, task_id: task_id, events: events })
        end
      end

      def sse_response(subscription, serialize: nil)
        [200, SSE_HEADERS.dup, SSEBody.new(subscription: subscription, heartbeat: @heartbeat, serialize: serialize)]
      end

      # --- Dispatch and serialization --------------------------------------

      # Control Commands may exceed 10s -> 504. For
      # turn Commands the dispatch returns immediately (the turn lives in the fiber) —
      # the timeout is harmless. NEVER Timeout.timeout from the stdlib. With no current
      # reactor (pure control test), dispatches directly.
      def dispatch_with_timeout(command)
        task = Async::Task.current?
        return @command_bus.dispatch(command) if task.nil?

        task.with_timeout(@sync_timeout) { @command_bus.dispatch(command) }
      end

      # Turn -> {task_id:} -> 202. Any other shape (control:
      # Session/Task, which are Data) -> 200 with serialized to_h.
      def command_response(result)
        if turn_result?(result)
          json_response(202, { task_id: result[:task_id] })
        else
          json_response(200, result.to_h)
        end
      end

      # Turn = Hash with task_id PRESENT and non-nil. A control that
      # returned a Hash without a useful task_id is not mistaken for a turn.
      def turn_result?(result)
        result.is_a?(Hash) && !result[:task_id].nil?
      end

      # Empty body or no content-type -> {} (transport validates only
      # well-formed JSON; the payload belongs to the handler). Does NOT use req.params (it would
      # consume the body as a form) — reads the raw body.
      def parse_body(req)
        raw = req.body&.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw, symbolize_names: true)
      end

      # Like parse_body, but keeps STRING keys: for payloads with arbitrary
      # DATA keys (a pack's file/skill names), which must not become
      # symbols. Malformed JSON -> JSON::ParserError (#call maps it to 400).
      def parse_raw_body(req)
        raw = req.body&.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      end

      # Task#to_h is shallow (Data#to_h doesn't recurse): `executions` stays as an Array of
      # Execution (Data), which JSON.generate would serialize as an opaque string
      # (`"#<data ...>"`) — unreadable for the consumer observing failures via
      # GET /v1/tasks/:id. Recurses the Executions serialization.
      def task_to_h(task)
        task.to_h.merge(executions: task.executions.map(&:to_h))
      end

      def json_response(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end

      # Raw markdown (start.md / a public doc). charset is explicit so a coding agent
      # fetching over HTTP decodes accents correctly.
      def markdown_response(status, text)
        [status, { "content-type" => "text/markdown; charset=utf-8" }, [text]]
      end

      def error_response(status, error)
        json_response(status, { error: { class: error.class.name, message: error.message } })
      end

      # the 500 is the ONE status whose body carries the retry envelope —
      # retryable/retry_after tell the client what to do, error_ref is what it
      # quotes when the retry keeps failing. The SAME ref is logged here, or the
      # field is decoration. 4xx stay bare: a client error is fixed by editing
      # the request, not by waiting.
      def internal_error_response(error)
        ref = "err_#{SecureRandom.hex(8)}"
        # Observability only (shutdown.rb's rule): a logger failure must never
        # mask the 500 the client is owed.
        begin
          @logger&.puts("[server] #{ref} #{error.class}: #{error.message}\n" \
                        "#{Array(error.backtrace).first(5).join("\n")}")
        rescue StandardError
          nil
        end
        # B9/A8: a classified ProviderError quotes its own retry guidance;
        # everything else keeps the blanket retry (the caller may have died mid
        # request — a bounded wait is the safe default).
        retryable = error.respond_to?(:retryable) && !error.retryable.nil? ? error.retryable : true
        retry_after = error.respond_to?(:retry_after) && error.retry_after ? error.retry_after : RETRY_AFTER_SECONDS
        body = { error: { class: error.class.name, message: error.message,
                           retryable: retryable, retry_after: retry_after, error_ref: ref } }
        body[:error][:kind] = error.kind if error.respond_to?(:kind) && error.kind
        json_response(500, body)
      end

      def not_found
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end

      # Liveness/readiness. Fixed 200: if the process accepts the connection and recovery
      # has already run (Boot only returns the app afterward), it's ready. Does NOT
      # touch a store (health cannot fail on IO nor require auth).
      def health = json_response(200, { status: "ok" })

      #   process vitals. Operator-only by construction: not in
      # PUBLIC_ROUTES (no bearer -> unauthorized) and not in TENANT_SURFACES
      # (a tenant principal hits the operator-surface gate), so only an
      # operator reads process internals. Reads no store — pure OS/VM
      # readings, safe at any rate.
      def handle_vitals
        json_response(200, Insika::Vitals.snapshot(executor: @executor, db_path: @db_path))
      end

      # Thin Subscription decorator: discards
      # events from OTHER tasks and CLOSES the subscription after forwarding the task's
      # terminal event. Solves the subscribe-before-task_id gap without touching
      # the Subscription's signature.
      class TaskFilter
        def initialize(subscription, task_id)
          @subscription = subscription
          @task_id = task_id
        end

        def each
          @subscription.each do |event|
            next unless (event.meta || {})[:task_id] == @task_id

            yield event
            break if TERMINAL_EVENTS.include?(event.type)
          end
        ensure
          @subscription.close
        end

        def close = @subscription.close
      end
      private_constant :TaskFilter
    end
  end
end
