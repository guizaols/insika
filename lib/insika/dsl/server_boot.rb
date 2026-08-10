# frozen_string_literal: true

# Boots the single-process HTTP server for Definition#serve: /studio (control UI,
# cookie-auth) + /v1 (drop-in OpenAI-Responses API), the same topology as
# scripts/serve_real.rb, but wired from a DSL Runtime instead of a deployment.
# Required lazily (pulls the server + Studio + Async) — never on `require "insika"`.

require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require "rack/urlmap"

require_relative "../server/rack_app"
require_relative "../studio/app"

module Insika
  module DSL
    class ServerBoot
      def initialize(runtime, port:, host:, token:)
        @rt = runtime
        @graph = runtime.graph
        @port = port
        @host = host
        # Fixed local token: logs into the Studio (cookie) and gates /v1 (Bearer).
        # Never a real secret — override with `token:` or ADMIN_TOKEN.
        @token = token || ENV.fetch("ADMIN_TOKEN", "local-demo")
        # RFC-0017 A3: the /v1 app is a value now — the same one a host mounts.
        # This boot adds the Studio and a reactor around it, nothing else.
        @builder = Insika::Server::AppBuilder.new(runtime, token: @token)
      end

      def run
        configure_studio
        dispatch = Rack::URLMap.new("/studio" => Studio::App, "/" => @builder.app)
        endpoint = Async::HTTP::Endpoint.parse("http://#{@host}:#{@port}")
        middleware = Protocol::Rack::Adapter.new(dispatch)
        # Item 16 / P4: the OTEL bridge is opt-in but must be reachable from the DSL
        # front door too — the convention is worthless if only config.ru can export.
        # nil (the default) -> attach is a no-op and no gem is loaded.
        telemetry = Insika::Telemetry.setup(service_name: ENV.fetch("OTEL_SERVICE_NAME", "insika"))

        banner(telemetry)
        # RFC-0016 A3: first Ctrl-C/SIGTERM closes the intake and drains in-flight
        # turns (INSIKA_DRAIN_TIMEOUT, default 20s); a second signal skips the wait.
        Insika::Shutdown.install(executor: @graph.executor)
        Async do
          @graph.executor.supervised = true # serving mode: turns survive disconnects
          Insika::Telemetry.attach(event_stream: @graph.event_stream, recorder: telemetry)
          Async::HTTP::Server.new(middleware, endpoint).run
        end
      end

      private

      def workflows? = @builder.workflows?
      def channels? = @builder.channels?

      def configure_studio
        Studio::App.configure(
          command_bus: @graph.bus, profile_source: @graph.profiles,
          event_stream: @graph.event_stream,
          config: { admin_token: @token, persistence: persistence },
          agent_file_store: @rt.component(:agent_file_store), skill_store: @rt.component(:skill_store),
          skill_catalog: @graph.skill_catalog, tool_catalog: @graph.tool_catalog,
          tool_store: @rt.component(:tool_store), memory_store: @graph.memory_store,
          session_store: @graph.session_store,
          settings_store: @rt.component(:settings_store), llm_provider_store: @rt.component(:provider_store),
          mcp_store: @rt.component(:mcp_store), system_file_store: @rt.component(:system_file_store),
          tool_trace_store: @rt.component(:tool_trace_store),
          context_trace_store: @rt.component(:context_trace_store),
          task_store: @graph.task_store, checkpoint_store: @graph.checkpoint_store,
          pending_action_store: @graph.pending_action_store
        )
      end

      def persistence
        @graph.durable? ? "durable (sqlite)" : "ephemeral (memory)"
      end

      def banner(telemetry = nil)
        base = "http://#{@host}:#{@port}"
        ids = @rt.packs.map { |p| p.config[:id].to_s }
        headline = ids.one? ? "agent \"#{ids.first}\"" : "#{ids.size} agents: #{ids.map(&:inspect).join(', ')}"
        models = ids.one? ? "model: \"#{ids.first}\"" : "model: one of #{ids.map(&:inspect).join(', ')}"
        puts "\e[1mInsika — serving #{headline}\e[0m"
        puts "  #{base}/studio          → control UI (login token: \"#{@token}\")"
        puts "  #{base}/v1/responses    → drop-in API (Bearer \"#{@token}\", #{models})"
        puts "  #{base}/start.md        → onboarding for your coding agent (+ /models.json, /docs)"
        puts "  #{base}/v1/workflows    → #{@graph.workflow_registry.names.join(', ')}" if workflows?
        puts "  #{base}/channels/…      → #{@graph.channel_registry.names.join(', ')}" if channels?
        # Only when on: an off-by-default line in the OSS front door is noise.
        puts "  OTEL              → #{Insika::Telemetry.metrics? ? "traces + metrics" : "traces"} to OTLP" if telemetry
        puts "  Ctrl-C to stop (drains in-flight turns; press twice to skip the wait)."
      end
    end
  end
end
