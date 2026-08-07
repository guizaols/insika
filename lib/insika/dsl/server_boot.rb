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

root = File.expand_path("../../..", __dir__)
require File.join(root, "server", "app")
require File.join(root, "studio", "app")

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
      end

      def run
        app = build_server_app
        configure_studio
        dispatch = Rack::URLMap.new("/studio" => Studio::App, "/" => app)
        endpoint = Async::HTTP::Endpoint.parse("http://#{@host}:#{@port}")
        middleware = Protocol::Rack::Adapter.new(dispatch)
        # Item 16 / P4: the OTEL bridge is opt-in but must be reachable from the DSL
        # front door too — the convention is worthless if only config.ru can export.
        # nil (the default) -> attach is a no-op and no gem is loaded.
        telemetry = Insika::Telemetry.setup(service_name: ENV.fetch("OTEL_SERVICE_NAME", "insika"))

        banner(telemetry)
        Async do
          @graph.executor.supervised = true # serving mode: turns survive disconnects
          Insika::Telemetry.attach(event_stream: @graph.event_stream, recorder: telemetry)
          Async::HTTP::Server.new(middleware, endpoint).run
        end
      end

      private

      def build_server_app
        Insika::Server::App.new(
          command_bus: @graph.bus, event_stream: @graph.event_stream,
          session_store: @graph.session_store, task_store: @graph.task_store,
          pending_action_store: @graph.pending_action_store,
          provisioner: Insika::PackImporter.new(bus: @graph.bus, profiles: @graph.profiles),
          # GET /v1/agents/:id — the read-only capability view a case's `requires`
          # resolves against (RFC-0014 §3.2).
          profiles: @graph.profiles,
          # Item 20 / §5.6: the OSS onboarding surface (start.md + models.json + docs).
          # This is the primary "build my first agent" target — models.json reports the
          # DSL's stores + the single agent this process serves (its id IS the `model`).
          onboarding: build_onboarding,
          # Item 22: GET /v1/workflows + POST /v1/workflows/:name, opt-in by
          # injection like every other edge — nil when the system declares none,
          # so the routes simply do not exist (404, parity).
          workflow_registry: (@graph.workflow_registry if workflows?),
          # RFC-0011: the bundled relay, when the env turns it on. Same rule as the
          # OTEL bridge above — a feature only `config.ru` can reach is a feature the
          # docs are half-true about.
          channels: (@graph.channel_registry if channels?),
          config: { gateway_token: @token }
        )
      end

      def workflows? = !@graph.workflow_registry.names.empty?

      # Registers the env-configured channels once, and reports whether any exist.
      def channels?
        unless defined?(@channels_ready)
          @channels_ready = true
          relay = Insika::Channels::Relay.from_env(
            http: Insika::HttpClient.new,
            allow_http: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_HTTP"]),
            allow_private: Insika::EnvSchema.truthy?(ENV["INSIKA_EGRESS_ALLOW_PRIVATE"])
          )
          @graph.channel_registry.register(relay.id, relay) if relay

          widget = Insika::Channels::Web.from_env(
            chat_rate_limit: Insika::Channels::Web.limit_resolver(
              profiles: @graph.profiles, settings_store: @rt.component(:settings_store)
            )
          )
          @graph.channel_registry.register(widget.id, widget) if widget
        end
        !@graph.channel_registry.names.empty?
      end

      def build_onboarding
        configs = @rt.packs.map(&:config)
        Insika::Onboarding.standard(
          root: File.expand_path("../../..", __dir__),
          settings_store: @rt.component(:settings_store),
          provider_store: @rt.component(:provider_store),
          # EVERY agent this process serves — each id IS a `model` on
          # /v1/responses, so a coding agent reading models.json sees the whole
          # system, not just the first one.
          agents: -> { configs.map { |c| { id: c[:id], model: c[:model], provider: c[:provider] } } }
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
        puts "  Ctrl-C to stop."
      end
    end
  end
end
