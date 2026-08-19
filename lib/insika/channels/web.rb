# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Insika
  module Channels
    # The web widget — the FIRST Shape A channel, and the adoption
    # claim behind the whole design: an adopter pastes one tag into their site and has
    # a working agent, with no backend of their own and no build step.
    #
    #   <script src="https://agents.example.com/channels/web/asset/widget.js"
    #           data-agent="support" data-title="Ask us anything" defer></script>
    #
    # Shape A means the reply comes back on the request's own stream, so there is
    # no outbox, no claim and no `deliver` here — the three routes and a static
    # asset are the entire surface:
    #
    #   POST /channels/web/sessions      mint an opaque session id (the engine's)
    #   POST /channels/web/messages      the turn, answered as SSE on this connection
    #   GET  /channels/web/asset/widget.js
    #
    # What makes this channel different from the relay is that it is PUBLIC: the
    # caller is an anonymous browser, so there is no shared secret to check and the
    # money faucet is real. Three things stand in for the missing credential, and
    # all three are refusals, never grants (R2):
    #
    #   · an AGENT allowlist — a visitor addresses the agents the operator published
    #     to the widget, not every agent in the deployment;
    #   · an ORIGIN allowlist — exact match, no wildcards, and no "allow all" value;
    #   · a mandatory chat RATE LIMIT — the channel answers `:disabled`
    #     until one is configured, because a public endpoint with an LLM behind it
    #     and no ceiling is an unmetered bill waiting to happen.
    #
    # R1/R2 hold: this object translates and refuses, and does nothing else. No
    # Executor, no store, no RubyLLM — the rate-limit probe is injected as a plain
    # callable so the channel never learns what a profile or a settings store is.
    class Web
      DEFAULT_ID = "web"

      # The static files this channel serves, by request name. A closed map, not a
      # directory listing: `asset/:f` takes a name from the URL, and anything that
      # resolves a path from user input is a traversal waiting to be found.
      ASSETS = {
        "widget.js" => { file: "web/widget.js", content_type: "application/javascript; charset=utf-8" }
      }.freeze

      # An unversioned URL cannot be cached for a year — the next release would
      # never reach a browser that already has it. Short max-age + an ETag instead:
      # the common case is a 304 with no body, and an upgrade lands within minutes.
      # (A deliberate narrowing of's "long-cache versioned URL": the install
      # snippet has no version in it, so there is nothing to bust.)
      ASSET_CACHE_CONTROL = "public, max-age=300"

      attr_reader :id

      # The bundled widget as an operator configures it. BOTH allowlists are the
      # switch: a widget with no origins can be embedded nowhere, and one with no
      # agents can address nothing, so either one missing means the operator has not
      # actually asked for this channel. -> Web | nil.
      def self.from_env(env = ENV, id: DEFAULT_ID, chat_rate_limit: nil)
        origins = csv(Insika::EnvSchema.read("INSIKA_WIDGET_ORIGINS", env))
        agents  = csv(Insika::EnvSchema.read("INSIKA_WIDGET_AGENTS", env))
        return nil if origins.empty? || agents.empty?

        new(origins: origins, agents: agents, id: id, chat_rate_limit: chat_rate_limit)
      end

      # The probe's gate needs, asked exactly the way `EdgeLimiter` asks it at
      # turn time: the per-agent override first, the platform default second. Built
      # here so both composition roots wire the gate identically, and returned as a
      # lambda so the channel itself stays store-free.
      #
      # Resolved on every check rather than at boot: an operator who removes the
      # limit tomorrow closes the widget, instead of leaving it open because it was
      # configured correctly once.
      def self.limit_resolver(profiles:, settings_store: nil)
        lambda do |agent_id|
          limits = profiles&.fetch(agent_id.to_s)&.limits || {}
          next limits[:chat_rate_limit] if limits.key?(:chat_rate_limit)

          ((settings_store&.get || {})["edge"] || {})["chat_rate_limit"]
        end
      end

      def self.csv(value) = value.to_s.split(",").map(&:strip).reject(&:empty?)

      # origins:         exact-match origin allowlist (`https://shop.example`). No
      #                  wildcard, no "*" — CORS is a browser courtesy and a value
      #                  that means "anyone" would only make it look like a control.
      # agents:          agent ids a visitor may address.
      # chat_rate_limit: callable(agent_id) -> the effective limit, or nil. Absent ⇒
      #                  the channel is `:disabled`, which is the fail-closed
      #                  reading of "no ceiling configured".
      def initialize(origins:, agents:, id: DEFAULT_ID, chat_rate_limit: nil)
        @id = id.to_s
        @origins = Array(origins).map(&:to_s)
        @agents = Array(agents).map(&:to_s)
        @chat_rate_limit = chat_rate_limit
        @assets = {}
      end

      # -> :ok | :unauthorized | :disabled. Same verdict vocabulary as every other
      # channel (no Rack triple in `lib/`), and the same fail-closed default.
      #
      # A request with NO `Origin` is not a browser, so there is nothing for CORS to
      # protect and refusing it would be theatre — curl can always set any origin it
      # likes. The rate limit is what actually defends this route, which is why it
      # is checked here and not left to the operator's memory.
      def authenticate(req)
        return :disabled if @agents.empty?
        return :disabled unless rate_limited?

        origin = req.get_header("HTTP_ORIGIN").to_s
        return :ok if origin.empty?

        allowed_origin?(origin) ? :ok : :unauthorized
      end

      # Is a chat rate limit configured for EVERY agent the widget publishes? All of
      # them and not just the one being addressed: the check runs before the body is
      # parsed, and "the widget is open for agent A but closed for agent B" is a
      # posture nobody can hold in their head.
      def rate_limited?
        return false if @chat_rate_limit.nil?

        !@agents.empty? && @agents.all? { |agent| @chat_rate_limit.call(agent).to_i.positive? }
      end

      # POST /channels/web/messages — STRING keys in, because this body comes off
      # the public internet and nothing in it should become a symbol.
      #
      #   { "agent": "support", "session_id": "web:8f3c…", "message": "oi" }
      #
      # The agent allowlist is checked HERE, which is a refusal and not a grant: the
      # profile still decides what that agent may do.
      def parse(_req, body:)
        body = body.is_a?(Hash) ? body : {}
        agent = body["agent"].to_s.strip
        session_id = body["session_id"].to_s.strip
        message = body["message"].to_s

        raise Insika::ValidationError, "agent is required" if agent.empty?
        raise Insika::ValidationError, "agent '#{agent}' is not published to the widget" unless @agents.include?(agent)
        raise Insika::ValidationError, "session_id is required" if session_id.empty?
        raise Insika::ValidationError, "message is required" if message.strip.empty?

        { agent: agent, session_id: session_id, message: message }
      end

      #'s hard rule for a public channel: the ENGINE issues the id and the
      # client never proposes one. A visitor-supplied session id on an anonymous
      # endpoint is session hijacking by enumeration, so there is no create-on-write
      # path — `POST /messages` with an unknown id is a 404, not a new conversation.
      def mint_session_id = "#{@id}:#{SecureRandom.hex(16)}"

      # Turn Event -> SSE frame | nil. Four frames, which is the whole widget
      # protocol: what to type, what to say while a tool runs, and how it ended.
      #
      # `:intermediate` and `:thinking` are deliberately absent. `:content` is the
      # ANSWER — the model's narration on the way there is internal, and a
      # widget that rendered it would show the customer the engine thinking out loud.
      def frame_for(event)
        case event.type
        when :content        then sse("delta", { delta: event.data[:delta].to_s })
        when :tool_call      then sse("working", { name: event.data[:name].to_s })
        when :task_completed then sse("done", {})
        when :task_failed    then sse("error", { message: event.data[:message].to_s })
        when :task_cancelled then sse("error", { message: "task cancelled" })
        when :error          then sse("error", { message: event.data[:message].to_s })
        end
      end

      # GET /channels/web/asset/:f -> { content_type:, body:, etag: } | nil.
      # Read once and memoized: the file ships with the gem and cannot change under
      # a running process.
      def asset(name)
        entry = ASSETS[name.to_s]
        return nil if entry.nil?

        @assets[name.to_s] ||= begin
          body = File.read(File.expand_path(entry[:file], __dir__))
          { content_type: entry[:content_type], body: body,
            etag: %("#{Digest::SHA256.hexdigest(body)[0, 16]}"),
            cache_control: ASSET_CACHE_CONTROL }
        end
      end

      # -> the CORS headers for this request's origin. An origin that is not on the
      # list simply gets none, and the browser refuses the response itself — the
      # engine does not have to pretend that is an authorization decision.
      def cors_headers(origin)
        o = origin.to_s
        return { "vary" => "origin" } unless allowed_origin?(o)

        { "access-control-allow-origin" => o,
          "vary" => "origin",
          "access-control-allow-headers" => "content-type",
          "access-control-allow-methods" => "POST, OPTIONS",
          "access-control-max-age" => "600" }
      end

      private

      def allowed_origin?(origin) = !origin.empty? && @origins.include?(origin)

      def sse(name, data) = "event: #{name}\ndata: #{JSON.generate(data)}\n\n"
    end
  end
end
