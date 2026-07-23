# frozen_string_literal: true

# Boots the single-process HTTP server for Definition#serve: /studio (control UI,
# cookie-auth) + /v1 (drop-in OpenAI-Responses API), the same topology as
# scripts/serve_real.rb, but wired from a DSL Runtime instead of a deployment.
# Required lazily (pulls the server + Studio + Async) — never on `require "harness"`.

require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require "rack/urlmap"

root = File.expand_path("../../..", __dir__)
require File.join(root, "server", "app")
require File.join(root, "studio", "app")

module Harness
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
      end

      def run
        app = build_server_app
        configure_studio
        dispatch = Rack::URLMap.new("/studio" => Studio::App, "/" => app)
        endpoint = Async::HTTP::Endpoint.parse("http://#{@host}:#{@port}")
        middleware = Protocol::Rack::Adapter.new(dispatch)

        banner
        Async do
          @graph.executor.supervised = true # serving mode: turns survive disconnects
          Async::HTTP::Server.new(middleware, endpoint).run
        end
      end

      private

      def build_server_app
        Harness::Server::App.new(
          command_bus: @graph.bus, event_stream: @graph.event_stream,
          session_store: @graph.session_store, task_store: @graph.task_store,
          pending_action_store: @graph.pending_action_store,
          provisioner: Harness::PackImporter.new(bus: @graph.bus, profiles: @graph.profiles),
          # Item 20 / §5.6: the OSS onboarding surface (start.md + models.json + docs).
          # This is the primary "build my first agent" target — models.json reports the
          # DSL's stores + the single agent this process serves (its id IS the `model`).
          onboarding: build_onboarding,
          config: { gateway_token: @token }
        )
      end

      def build_onboarding
        config = @rt.pack.config
        Harness::Onboarding.standard(
          root: File.expand_path("../../..", __dir__),
          settings_store: @rt.component(:settings_store),
          provider_store: @rt.component(:provider_store),
          agents: -> { [{ id: config[:id], model: config[:model], provider: config[:provider] }] }
        )
      end

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
          task_store: @graph.task_store, checkpoint_store: @graph.checkpoint_store,
          pending_action_store: @graph.pending_action_store
        )
      end

      def persistence
        @graph.durable? ? "durable (sqlite)" : "ephemeral (memory)"
      end

      def banner
        base = "http://#{@host}:#{@port}"
        agent = @rt.pack.config[:id]
        puts "\e[1mHarness — serving agent \"#{agent}\"\e[0m"
        puts "  #{base}/studio          → control UI (login token: \"#{@token}\")"
        puts "  #{base}/v1/responses    → drop-in API (Bearer \"#{@token}\", model: \"#{agent}\")"
        puts "  #{base}/start.md        → onboarding for your coding agent (+ /models.json, /docs)"
        puts "  Ctrl-C to stop."
      end
    end
  end
end
