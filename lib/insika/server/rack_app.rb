# frozen_string_literal: true

# the /v1 transport as a VALUE the host app mounts, instead of a
# server the engine starts.
#
#   mount Insika::Server.rack_app(INSIKA, token: ENV.fetch("INSIKA_TOKEN")), at: "/ai"
#
# The assembly used to live inline in DSL::ServerBoot#run, welded to
# `Async::HTTP::Server.new(...).run` on the next line: a host that already owns a
# reactor and a router could not reach it. Nothing here is new behavior — the
# server boot now calls this instead of inlining it, which is what keeps the two
# from drifting.
#
# The Studio is deliberately NOT part of this (the embed contract): it is
# a class-level singleton, so it is one per process, and a host that wants the
# operator UI mounts `Studio::App` itself and accepts that limitation.

require_relative "app"

module Insika
  module Server
    # `handle` is anything that answers #runtime (a DSL Definition/System) or a
    # DSL::Runtime itself. -> a Rack app (`#call(env)`).
    #
    # It is mount-safe: routing reads `path_info`, so `Rack::URLMap`/Rails' `mount`
    # moving the prefix into SCRIPT_NAME leaves every route intact.
    def self.rack_app(handle, token: nil, **config)
      AppBuilder.new(handle, token: token, **config).app
    end

    # Assembles Server::App from a graph. Also answers the two questions the boot
    # banner asks (`workflows?`/`channels?`), so registering the env channels
    # happens exactly once and in one place.
    class AppBuilder
      # Fixed local token: gates /v1 (Bearer) — and, under `serve`, logs into the
      # Studio (cookie). Never a real secret; override with `token:`/ADMIN_TOKEN.
      def initialize(handle, token: nil, **config)
        @rt = handle.respond_to?(:runtime) ? handle.runtime : handle
        @graph = @rt.graph
        @token = token || ENV.fetch("ADMIN_TOKEN", "local-demo")
        @config = config
      end

      attr_reader :token
      attr_reader :graph
      # RFC-0025: the frozen criterion, memoized when the relay runs in shadow —
      # nil otherwise. Loaded ONCE at boot (the refusal below), then shared.
      attr_reader :criterion

      def app
        tenancy = @config[:tenancy] || ENV["INSIKA_TENANCY"] || "single_tenant"
        # WS1: the token store is handed over ONLY in multi_tenant mode — in
        # single_tenant the classic gateway token is the only credential
        # (passing the store would silently widen the surface).
        store = tenancy == "multi_tenant" ? @graph.token_store : nil
        @app ||= Insika::Server::App.new(
          command_bus: @graph.bus, event_stream: @graph.event_stream,
          session_store: @graph.session_store, task_store: @graph.task_store,
          pending_action_store: @graph.pending_action_store,
          provisioner: Insika::PackImporter.new(bus: @graph.bus, profiles: @graph.profiles),
          # GET /v1/agents/:id — the read-only capability view a case's `requires`
          # resolves against.
          profiles: @graph.profiles,
          # the OSS onboarding surface (start.md + models.json + docs).
          # This is the primary "build my first agent" target — models.json reports the
          # DSL's stores + the agents this process serves (each id IS the `model`).
          onboarding: build_onboarding,
          # GET /v1/workflows + POST /v1/workflows/:name, opt-in by
          # injection like every other edge — nil when the system declares none,
          # so the routes simply do not exist (404, parity).
          workflow_registry: (@graph.workflow_registry if workflows?),
          # the bundled relay, when the env turns it on. Same rule as the
          # OTEL bridge — a feature only `config.ru` can reach is a feature the
          # docs are half-true about.
          channels: (@graph.channel_registry if channels?),
          config: { gateway_token: @token, tenancy: tenancy }.merge(@config),
          token_store: store,
          outcome_store: @graph.outcome_store,
          # a 500's error_ref must be findable in the process log.
          logger: $stdout
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
          # RFC-0025 D2: NO criterion, no shadow — enforced at boot, not per
          # turn. Raises ConfigError when the file is missing, unparseable, or
          # incomplete; the criterion is memoized here and injected into
          # ChannelDelivery (its sha stamps every pair our half records).
          if relay&.shadow?
            @criterion = Insika::Parity::Criterion.load(
              Insika::EnvSchema.read("INSIKA_PARITY_CRITERION") || "evals/PARITY.md"
            )
            @graph.channel_delivery&.criterion_sha = @criterion.sha
          end
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

      private

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
    end
  end
end
