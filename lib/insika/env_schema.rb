# frozen_string_literal: true

module Insika
  # STRICT config, environment layer (item 23 / §8.1). OpenClaw's config discipline
  # — "recusa boot com chave desconhecida, no silent config compat" — applied to the
  # env vars the engine reads at boot. A declarative registry of the keys the engine
  # OWNS (config over convention: the schema IS data), used two ways:
  #
  #   · `validate(env)` — returns structured Findings: a value that fails its type
  #     (HARNESS_PORT=abc), and an UNKNOWN key inside a namespace the engine owns
  #     (HARNESS_EGRES_ALLOW_HTTP — a typo the runtime would otherwise ignore in
  #     silence). Unknown-key detection is scoped to the OWNED prefixes only, so the
  #     platform's own vars (Railway's RAILWAY_*, PORT, PATH, the litestream
  #     sidecar's LITESTREAM_*, the deployment's DEEPSEEK_*/ACHEI_*) are never flagged.
  #   · `enforce!(strict:)` — the boot gate. WARNS on every finding by default and
  #     lets the engine come up (last-known-good — a rotated key or a typo must never
  #     take the whole service down, same reasoning as the resilient DEEPSEEK boot);
  #     RAISES ConfigError only when strictness is on (HARNESS_CONFIG_STRICT truthy,
  #     or `strict: true`).
  #
  # Insika::Doctor reuses `validate` for its `env:*` checks; the boot roots call
  # `enforce!`. A deployment layers its own keys on via `extra:` (see
  # config/deployment.rb) so `harness env` and `harness doctor` see the full picture.
  module EnvSchema
    module_function

    # One env key the engine knows about. `type` drives validation; `secret` masks
    # the value in `harness env`; `enum` restricts allowed values; `required` makes
    # a blank value a finding (engine keys are all optional — deployment resilience —
    # so `required` is used by deployment extras, not the defaults here).
    Spec = Data.define(:name, :type, :secret, :required, :enum, :description) do
      def secret? = secret
      def required? = required

      # nil/blank when optional -> no finding. Present -> must satisfy the type. ->
      # error string or nil.
      def error_for(raw)
        value = raw.to_s
        return "is required (unset)" if value.strip.empty? && required
        return nil if value.strip.empty?

        case type
        when :integer
          "must be an integer, got #{value.inspect}" unless value.match?(/\A-?\d+\z/)
        when :boolean
          "must be a boolean (#{BOOLEANS.join('/')}), got #{value.inspect}" unless EnvSchema.boolean?(value)
        when :enum
          "must be one of #{enum.inspect}, got #{value.inspect}" unless Array(enum).include?(value)
        when :url
          "must be an http(s) URL, got #{value.inspect}" unless value.match?(%r{\Ahttps?://\S+\z})
        end # :string / :csv / :path -> any string is valid
      end
    end

    # A problem (or an :ok note) about the environment. dry/serializable — the proc-
    # free shape Doctor and `harness env` both render.
    Finding = Data.define(:key, :kind, :severity, :message) do
      def to_h = { "key" => key, "kind" => kind.to_s, "severity" => severity.to_s, "message" => message }
    end

    # Prefixes the engine fully OWNS: an unknown key under one of these is a typo, not
    # a foreign var. Only HARNESS_ — it is uniquely ours. Deliberately NOT OPENCLAW_
    # (shared with the OpenClaw gateway product, which sets its own OPENCLAW_HOME/
    # _STATE_DIR/… — the engine merely borrows 3 names for interop), nor LITESTREAM_
    # (the sidecar owns it), nor OTEL_ (the OpenTelemetry SDK owns its env).
    OWNED_PREFIXES = %w[HARNESS_].freeze

    BOOLEANS = %w[1 0 true false yes no on off].freeze

    def boolean?(value) = BOOLEANS.include?(value.to_s.strip.downcase)

    # Truthy per the engine's convention (telemetry/turn_timing agree). The single
    # home for "is this env flag on?".
    def truthy?(value) = %w[1 true yes on].include?(value.to_s.strip.downcase)

    def spec(name:, type: :string, secret: false, required: false, enum: nil, description: "")
      Spec.new(name: name, type: type, secret: secret, required: required, enum: enum, description: description)
    end

    # The engine's own keys. Deployment/app keys (DEEPSEEK_*, ACHEI_*, …) are NOT
    # here — a root passes them as `extra:`.
    DEFAULT = [
      spec(name: "HARNESS_DB", type: :path, description: "SQLite path; durable config+state. Unset -> ephemeral memory."),
      spec(name: "HARNESS_BIND", description: "Bind address for the transport server."),
      spec(name: "HARNESS_PORT", type: :integer, description: "Port for the transport server."),
      spec(name: "HARNESS_PUBLIC_URL", type: :url, description: "Public base URL (A2A agent card, links)."),
      spec(name: "HARNESS_ENV", description: "Environment name shown in the Studio (falls back to RACK_ENV)."),
      spec(name: "HARNESS_A2A_AGENT", description: "Agent id to expose over inbound A2A (opt-in)."),
      spec(name: "HARNESS_A2A_REMOTES", type: :csv, description: "Comma-separated remote A2A endpoints."),
      spec(name: "HARNESS_EGRESS_ALLOW_HTTP", type: :boolean, description: "Allow plain http egress from data-tools (default: https only)."),
      spec(name: "HARNESS_EGRESS_ALLOW_PRIVATE", type: :boolean, description: "Allow egress to private/loopback ranges (SSRF guard off)."),
      spec(name: "HARNESS_EGRESS_HOSTS", type: :csv, description: "Comma-separated host allowlist for data-tool egress."),
      spec(name: "HARNESS_OTEL", type: :boolean, description: "Turn on OpenTelemetry export (opt-in)."),
      spec(name: "HARNESS_TURN_TIMING", type: :boolean, description: "Emit per-turn TTFB breakdown in responses (opt-in, item 34)."),
      spec(name: "HARNESS_SUBAGENT_FANOUT_CAP", type: :integer, description: "Max parallel children in spawn_subagents (default 8)."),
      spec(name: "HARNESS_CONFIG_STRICT", type: :boolean, description: "Refuse boot on any config finding instead of warning (item 23)."),
      spec(name: "HARNESS_ONBOARDING", type: :boolean, description: "Expose the public onboarding surface (/start.md, /models.json, /docs) in production (opt-in, item 20)."),
      spec(name: "OPENCLAW_GATEWAY_TOKEN", secret: true, description: "Bearer for /v1 + /a2a (falls back to ADMIN_TOKEN)."),
      spec(name: "OPENCLAW_AGENTS_DIR", type: :path, description: "Directory of OpenClaw-style agent packs."),
      spec(name: "OPENCLAW_PLUGIN_DIR", type: :path, description: "Directory of plugins to load."),
      spec(name: "ADMIN_TOKEN", secret: true, description: "Studio login token; unset -> /studio fail-closed."),
      spec(name: "OTEL_SERVICE_NAME", description: "Service name for OTEL spans (default: harness).")
    ].freeze

    # -> [Finding]. `extra` = deployment/app specs to fold into the known set (and to
    # widen unknown-key detection over their names). Never raises.
    def validate(env = ENV, extra: [])
      specs = index(DEFAULT + Array(extra))
      findings = []

      specs.each_value do |s|
        next unless env.key?(s.name)

        msg = s.error_for(env[s.name])
        findings << Finding.new(key: s.name, kind: :invalid, severity: :error, message: "#{s.name} #{msg}") if msg
      end

      # required-but-ABSENT (present-but-blank is already caught by error_for above).
      specs.each_value do |s|
        next unless s.required? && !env.key?(s.name)

        findings << Finding.new(key: s.name, kind: :missing_required, severity: :error, message: "#{s.name} is required (unset)")
      end

      unknown_keys(env, specs).each do |name|
        findings << Finding.new(key: name, kind: :unknown, severity: :error,
                                message: "#{name} is not a known config key (typo? unknown key in an owned namespace)")
      end

      findings
    end

    # -> the specs the engine + a root know about (DEFAULT + extra), for `harness env`.
    def known_specs(extra: []) = (DEFAULT + Array(extra)).sort_by(&:name)

    # BOOT GATE. Validates the environment, WARNS every finding via `warn` (a callable
    # taking a String), and RAISES ConfigError only when strict. `strict` defaults to
    # the HARNESS_CONFIG_STRICT flag. -> [Finding] (also on the happy path). The root
    # keeps booting on warnings (last-known-good).
    def enforce!(env = ENV, extra: [], strict: nil, warn: method(:default_warn))
      strict = truthy?(env["HARNESS_CONFIG_STRICT"]) if strict.nil?
      findings = validate(env, extra: extra)
      findings.each { |f| warn.call("config: #{f.message}") }

      errors = findings.select { |f| f.severity == :error }
      raise Insika::ConfigError.new("strict config check refused boot", findings: errors) if strict && errors.any?

      findings
    end

    def default_warn(message) = Kernel.warn("[config] #{message}")

    # -- internal ------------------------------------------------------

    def index(specs) = specs.each_with_object({}) { |s, acc| acc[s.name] = s }

    # env keys under an owned prefix that are NOT in the known set.
    def unknown_keys(env, specs)
      env.keys.select { |k| OWNED_PREFIXES.any? { |p| k.to_s.start_with?(p) } && !specs.key?(k.to_s) }.sort
    end
  end
end
