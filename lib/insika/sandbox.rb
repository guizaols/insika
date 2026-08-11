# frozen_string_literal: true

require_relative "coercion"
require_relative "sandbox/boundary"
require_relative "sandbox/runner"
require_relative "sandbox/local"
require_relative "sandbox/docker"

module Insika
  # Sandbox primitive (COMPETITIVE-ANALYSIS): a single, pluggable
  # interface for confined execution, promoted to the core from the insika-code
  # prototype. Two halves:
  #
  #   * FS confinement (`Boundary`) — ALWAYS host-side, always on: every path a
  #     tool resolves is proven inside the root before any IO.
  #   * command exec — via a swappable PROVIDER: `local` (in-process, the default)
  #     or `docker` (isolated container). Providers are chosen by DATA, not code
  #     (config-over-code): the agent profile's `sandbox` block names the provider
  #     and its policy.
  #
  # `Env` is the object a tool holds; `Sandbox.build(config)` assembles one from
  # the declarative config (the same hash shape stored on the profile).
  module Sandbox
    # Ergonomic alias so tools can rescue `Insika::Sandbox::Escape` without
    # reaching into the Boundary. It IS Boundary::Escape (same class).
    Escape = Boundary::Escape

    DEFAULT_TIMEOUT    = 120
    DEFAULT_MAX_OUTPUT = 40_000

    module_function

    # config keys (all optional, string or symbol):
    #   provider    "local" (default) | "docker"
    #   root        confinement root (default: Dir.pwd)
    #   timeout     per-exec wall-clock seconds (default 120)
    #   max_output  bytes of combined output kept (default 40_000)
    #   + provider-specific keys (image/network/memory/cpus/... for docker)
    def build(config = {})
      cfg  = Coercion.deep_stringify(config || {})
      root = cfg["root"].to_s.empty? ? Dir.pwd : cfg["root"]
      Env.new(
        boundary: Boundary.new(root),
        provider: provider_for(cfg),
        timeout: Integer(cfg["timeout"] || DEFAULT_TIMEOUT),
        max_output: Integer(cfg["max_output"] || DEFAULT_MAX_OUTPUT)
      )
    end

    def provider_for(cfg)
      case cfg["provider"].to_s
      when "", "local" then Local.new(shell: cfg["shell"] || "/bin/bash")
      when "docker"     then Docker.new(cfg)
      else raise ArgumentError, "unknown sandbox provider: #{cfg["provider"].inspect}"
      end
    end

    # The per-agent sandbox environment: composes an FS boundary with an exec
    # provider and the default limits. Delegates the boundary surface (resolve /
    # relative / inside?) and adds `exec`. Immutable, safely shared across turns.
    class Env
      attr_reader :boundary, :provider, :root, :timeout, :max_output

      def initialize(boundary:, provider:, timeout:, max_output:)
        @boundary   = boundary
        @provider   = provider
        @root       = boundary.root
        @timeout    = timeout
        @max_output = max_output
      end

      # --- FS boundary (host-side, always on) ---
      def resolve(path, for_write: false) = @boundary.resolve(path, for_write: for_write)
      def inside?(abs) = @boundary.inside?(abs)
      def relative(abs) = @boundary.relative(abs)

      # --- command exec (via the provider) -> Result ---
      def exec(command, timeout: @timeout, max_output: @max_output)
        @provider.exec(command, root: @root, timeout: timeout, max_output: max_output)
      end

      def to_s = "Sandbox(#{@provider}, root=#{@root})"
    end
  end
end
