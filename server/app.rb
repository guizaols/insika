# frozen_string_literal: true

require "json"
require "rack"
require "async"
require_relative "sse_body"
require_relative "admin_auth" # Bearer checker shared by the gateway edge (fail-closed)
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

      # The operator control UI now lives in the Studio (§12 G5); server/ is a
      # pure transport surface (/v1, /a2a). The constitutional rule holds: server/
      # only READS stores and never imports the Executor, store writes, or RubyLLM.
      def initialize(command_bus:, event_stream:, session_store:, task_store:,
                     config:, pending_action_store: nil, a2a: nil, provisioner: nil,
                     workflow_registry: nil, onboarding: nil, profiles: nil)
        @command_bus = command_bus
        @event_stream = event_stream
        @session_store = session_store
        @task_store = task_store
        @config = config
        @pending_action_store = pending_action_store # read for GET /v1/tasks/:id
        @a2a = a2a # A2A edge. nil = server does not expose A2A (parity).
        @provisioner = provisioner # PackImporter. nil = provisioning not exposed.
        # Item 22 / §4.4: READ-ONLY registry, injected only where workflows are
        # exposed (the minimal wiring). nil = no /v1/workflows routes (parity — the
        # deployment does not expose workflows). Reading a catalog is a READ, like a
        # store read: the constitutional rule (no Executor/store-writes/RubyLLM) holds.
        @workflow_registry = workflow_registry
        # Item 20 / §5.6: LLM-first onboarding surface (start.md + models.json +
        # docs). PUBLIC (no auth — the whole point of the "read <base>/start.md" trick
        # is that the developer's coding agent can fetch it), and READ-ONLY, so the
        # constitutional rule holds. nil = routes not exposed (parity — the production
        # deployment opts in). Reading files/masked stores is a READ, like a store read.
        @onboarding = onboarding
        # RFC-0014 §3.2: READ-ONLY ProfileSource, so `GET /v1/agents/:id` can answer
        # what an agent has — the eval is a client and cannot read a store. Same
        # constitutional footing as the workflow registry: reading a catalog is a
        # READ. nil = the route 404s (parity).
        @profiles = profiles
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
        error_response(500, e)
      end

      private

      def route(req)
        segments = req.path_info.split("/").reject(&:empty?)
        gate = public_route?(req.request_method, segments) ? nil : gateway_gate(req)
        return gate if gate

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
          handle_read_session(id)
        in ["GET", ["v1", "tasks", id]]
          handle_read_task(id)
        in ["GET", ["v1", "events"]]
          handle_events(req)
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

        method == "GET" && segments.length == 2 && segments.first == "docs"
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
      def handle_command(req, type)
        command = Insika::Command.build(type.to_sym, parse_body(req), transport: :http)
        command_response(dispatch_with_timeout(command))
      end

      # POST /v1/sessions — sugar for create_session; 201 {session}.
      def handle_create_session(req)
        body = parse_body(req)
        command = Insika::Command.build(:create_session, { vars: body[:vars] || {} },
                                         transport: :http)
        session = dispatch_with_timeout(command)
        json_response(201, { session: session.to_h })
      end

      # POST /v1/messages — sugar for send_message; ?stream missing/"true" -> SSE,
      # "false" -> 200 JSON aggregated at the terminal event.
      def handle_send_message(req)
        stream = req.GET["stream"] != "false"
        message_flow(parse_body(req), stream: stream)
      end

      # GET /docs/:name.md — one public doc as raw markdown (item 20 / §5.6). The
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

      # GET /v1/workflows — discovery (item 22 / §4.4). Direct read of the
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
        workflow_flow(payload, stream: req.GET["stream"] == "true")
      end

      # POST /v1/responses — OpenAI Responses adapter (drop-in for the OpenClaw
      # gateway). Bearer via `config[:gateway_token]` (fail-closed). Translates
      # the request -> :send_message and the turn's
      # Event Stream -> OpenAI Responses SSE. Always streams (the consumer asks for SSE).
      def handle_responses(req)
        gate = gateway_gate(req)
        return gate if gate

        parsed = Responses.parse_request(parse_body(req), req) # ValidationError -> 422
        ensure_session(parsed[:user])
        payload = { agent: parsed[:agent], session_id: parsed[:user], message: parsed[:message] }
        payload[:origin] = parsed[:origin] if parsed[:origin] # declared, else absent
        message_flow(payload, stream: true, serialize: Responses.method(:frame_for))
      end

      # POST /v1/agents — provisions (upserts) an agent from a standardized
      # PACK (Phase 6/D4/F7). Same Bearer as /v1/responses (gateway_token,
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
      # (Phase 7, Step B). Same Bearer as provisioning (gateway_token, fail-
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

      # POST /v1/mcp/:name/import — LIVE MCP ingestion (Phase 7, Step E). Same
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
      # "this case failed" (RFC-0014 §3.2). Deliberately NOT the profile: the prompt,
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

      # Gateway Bearer (fail-closed). -> error response (503/401) OR nil when
      # ok (the handler proceeds).
      def gateway_gate(req)
        case Insika::Server::AdminAuth.check(@config[:gateway_token], req.get_header("HTTP_AUTHORIZATION"))
        when :disabled then auth_error(503, "gateway disabled")
        when :unauthorized then auth_error(401, "unauthorized", "www-authenticate" => "Bearer")
        end
      end

      # Session correlated by `user`=chat.id: creates if new (explicit id),
      # continues if it exists (multi-turn). Via Command (server/ does not write to a store).
      # Benign race (two near-simultaneous turns creating) -> ArgumentError from the
      # store, treated as "already exists".
      def ensure_session(user)
        return if @session_store.find(user)

        @command_bus.dispatch(
          Insika::Command.build(:create_session, { id: user, vars: { channel: "responses" } }, transport: :http)
        )
      rescue ArgumentError
        nil
      end

      # GET /v1/sessions/:id — direct read (not a Command).
      def handle_read_session(id)
        session = @session_store.find(id)
        raise Insika::NotFoundError, "session not found: #{id}" if session.nil?

        json_response(200, { session: session.to_h })
      end

      # GET /v1/tasks/:id — direct read. This is where the consumer observes
      # PolicyDenied/post-202 failures: the terminal state lives in the Task
      # Store; nothing is lost if the client disconnected.
      def handle_read_task(id)
        task = @task_store.find(id)
        raise Insika::NotFoundError, "task not found: #{id}" if task.nil?

        body = { task: task_to_h(task) }
        # pending approvals: this is where the consumer/operator sees
        # what needs approval after an :approval_requested.
        if @pending_action_store
          body[:pending_actions] = @pending_action_store.open_for(id).map(&:to_h)
        end
        json_response(200, body)
      end

      # GET /v1/events?task_id=&session_id= — here the filters ARE known.
      # CONTINUOUS stream (post-crash reconnection route): does not close on a
      # terminal event — ends on client disconnect or cap.
      def handle_events(req)
        subscription = @event_stream.subscribe(task_id: req.GET["task_id"],
                                                session_id: req.GET["session_id"])
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
      def message_flow(payload, stream:, serialize: nil)
        command = Insika::Command.build(:send_message, payload, transport: :http)
        subscription = @event_stream.subscribe
        result =
          begin
            @command_bus.dispatch(command)
          rescue StandardError
            subscription.close
            raise
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

      # Workflow trigger flow (item 22). Async by default (the honest workflow
      # contract: fire the run, return the runId); ?stream=true streams the run's
      # events like a turn. Same subscribe-before-dispatch discipline as
      # message_flow so no eager event is lost when streaming. A synchronous handler
      # error (bad input / unknown workflow) closes the subscription and propagates
      # to #call (HTTP status).
      def workflow_flow(payload, stream:)
        command = Insika::Command.build(:trigger_workflow, payload, transport: :http)

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
          when :task_failed    then error = { class: event.data[:error], message: event.data[:message] }
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

      def not_found
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end

      # Liveness/readiness. Fixed 200: if the process accepts the connection and recovery
      # has already run (Boot only returns the app afterward — doc 07 §4), it's ready. Does NOT
      # touch a store (health cannot fail on IO nor require auth).
      def health = json_response(200, { status: "ok" })

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
