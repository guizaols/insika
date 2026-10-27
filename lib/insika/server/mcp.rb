# frozen_string_literal: true

require "json"

module Insika
  module Server
    # `POST /mcp` — a read-only Model Context Protocol server over the conversations
    # this deployment ran (docs/MCP.md). Streamable HTTP, JSON responses only (no
    # server-initiated messages, so no SSE stream): a client sends one JSON-RPC
    # message per POST and reads one JSON reply.
    #
    # Transport only: every answer comes from SessionInsights. The App owns auth —
    # this route sits behind the gateway bearer and is operator-only (a tenant
    # credential is refused, like every other cross-tenant read).
    class Mcp
      PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
      SERVER_INFO = { "name" => "insika", "title" => "Insika conversations" }.freeze

      READ_ONLY = { "readOnlyHint" => true, "destructiveHint" => false,
                    "idempotentHint" => true, "openWorldHint" => false }.freeze

      SYNTHETIC = { "type" => "boolean", "description" => "Include simulator/eval sessions (default false)." }.freeze
      AGENT = { "type" => "string", "description" => "Agent id, e.g. agent-store-onda-eco." }.freeze

      TOOLS = [
        { "name" => "agent_summary",
          "title" => "Traffic per agent",
          "description" => "One row per agent: sessions, sessions with turns (imported transcripts have none), " \
                           "turns by status, flagged sessions, first and last turn.",
          "inputSchema" => { "type" => "object", "properties" => {
            "since" => { "type" => "string", "description" => "ISO-8601; count only turns created after it." },
            "include_synthetic" => SYNTHETIC
          } } },
        { "name" => "list_sessions",
          "title" => "List sessions",
          "description" => "Sessions newest first, with agent, customer, message and turn counts and open flags. " \
                           "By default only sessions the engine ran (with turns).",
          "inputSchema" => { "type" => "object", "properties" => {
            "agent" => AGENT,
            "since" => { "type" => "string", "description" => "ISO-8601; only sessions with a turn after it." },
            "with_turns" => { "type" => %w[boolean null],
                              "description" => "true (default): ran in the engine; false: imported only; null: both." },
            "flagged" => { "type" => "boolean", "description" => "Only sessions with an open or reported flag." },
            "include_synthetic" => SYNTHETIC,
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 50 }
          } } },
        { "name" => "get_transcript",
          "title" => "Read a session",
          "description" => "The full transcript of one session: each message with role, origin and guardrail flags.",
          "inputSchema" => { "type" => "object", "required" => ["session_id"], "properties" => {
            "session_id" => { "type" => "string" },
            "max_chars" => { "type" => "integer", "minimum" => 100, "default" => 4000,
                             "description" => "Cut each message at this length." }
          } } },
        { "name" => "list_flags",
          "title" => "List guardrail flags",
          "description" => "One row per guardrail flag with its category, source, reason, the message it judged " \
                           "and the reply that followed. Open flags only unless include_resolved.",
          "inputSchema" => { "type" => "object", "properties" => {
            "agent" => AGENT,
            "category" => { "type" => "string", "description" => "e.g. invented_policy, injection." },
            "include_resolved" => { "type" => "boolean" },
            "include_synthetic" => SYNTHETIC,
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 100 }
          } } }
      ].map { |tool| tool.merge("annotations" => READ_ONLY) }.freeze

      # JSON-RPC error codes (spec section 5.1).
      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602

      def initialize(insights:, version: Insika::VERSION)
        @insights = insights
        @version = version
      end

      # -> Hash (the JSON-RPC response) or nil (a notification: the App answers 202).
      def handle(message)
        return error(nil, INVALID_REQUEST, "expected one JSON-RPC message object") unless message.is_a?(Hash)

        id = message["id"]
        method = message["method"].to_s
        return nil unless message.key?("id") # a notification (notifications/initialized…) gets no reply

        result = case method
                 when "initialize" then initialize_result(message["params"])
                 when "ping" then {}
                 when "tools/list" then { "tools" => TOOLS }
                 when "tools/call" then call_tool(message["params"] || {})
                 else return error(id, METHOD_NOT_FOUND, "method not found: #{method}")
                 end
        { "jsonrpc" => "2.0", "id" => id, "result" => result }
      rescue ArgumentError => e
        error(id, INVALID_PARAMS, e.message)
      end

      def parse_error(detail) = error(nil, PARSE_ERROR, "parse error: #{detail}")

      private

      def initialize_result(params)
        asked = params.is_a?(Hash) ? params["protocolVersion"] : nil
        { "protocolVersion" => PROTOCOL_VERSIONS.include?(asked) ? asked : PROTOCOL_VERSIONS.first,
          "capabilities" => { "tools" => { "listChanged" => false } },
          "serverInfo" => SERVER_INFO.merge("version" => @version),
          "instructions" => "Read-only view of the conversations Insika ran. Start with agent_summary, " \
                            "then list_sessions or list_flags, then get_transcript for one session." }
      end

      # A tool's own failure is a RESULT with isError (the model reads it and can
      # correct itself); only an unknown tool or bad arguments are protocol errors.
      def call_tool(params)
        args = params["arguments"] || {}
        raise ArgumentError, "arguments must be an object" unless args.is_a?(Hash)

        data = run(params["name"].to_s, args)
        return tool_error("session not found: #{args['session_id']}") if data.nil?

        wrapped = data.is_a?(Array) ? { "items" => data } : data
        { "content" => [{ "type" => "text", "text" => JSON.generate(wrapped) }], "structuredContent" => wrapped }
      end

      def run(name, args)
        case name
        when "agent_summary"
          @insights.agent_summary(since: str(args, "since"), include_synthetic: args["include_synthetic"] == true)
        when "list_sessions"
          @insights.list_sessions(agent: str(args, "agent"), since: str(args, "since"),
                                  with_turns: args.key?("with_turns") ? args["with_turns"] : true,
                                  flagged: args["flagged"] == true, include_synthetic: args["include_synthetic"] == true,
                                  limit: int(args, "limit", 50, 1..500))
        when "get_transcript"
          id = str(args, "session_id") or raise ArgumentError, "session_id is required"
          @insights.transcript(id, max_chars: int(args, "max_chars", 4000, 100..))
        when "list_flags"
          @insights.list_flags(agent: str(args, "agent"), category: str(args, "category"),
                               include_resolved: args["include_resolved"] == true,
                               include_synthetic: args["include_synthetic"] == true,
                               limit: int(args, "limit", 100, 1..500))
        else
          raise ArgumentError, "unknown tool: #{name}"
        end
      end

      def str(args, key) = Coercion.presence(args[key].is_a?(String) ? args[key] : nil)

      def int(args, key, default, range)
        value = args.fetch(key, default)
        raise ArgumentError, "#{key} must be an integer in #{range}" unless value.is_a?(Integer) && range.cover?(value)

        value
      end

      def tool_error(text)
        { "content" => [{ "type" => "text", "text" => text }], "isError" => true }
      end

      def error(id, code, message)
        { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
      end
    end
  end
end
