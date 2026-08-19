# frozen_string_literal: true

require "digest"
require "yaml"

module Insika
  module Soak
    # The frozen pre-declared envelope for a soak run. Parses the
    # fenced `yaml` block inside a markdown file, validates it completely or not
    # at all, and exposes the SHA-256 of the WHOLE file — every hourly snapshot
    # is stamped with it, so editing the envelope mid-run turns the run
    # `invalid` instead of producing a verdict nobody can defend.
    #
    # No defaults, no tolerance: an envelope with a hole is not a
    # pre-declaration. Contrast with EnvSchema (tolerant, warn-and-boot) — that
    # resilience protects a live service; this strictness protects a claim.
    class Envelope
      # Required keys. A missing one is a ConfigError, not a default.
      REQUIRED = %i[
        version target duration_hours warmup_hours
        arrival turns_per_hour session_turns concurrency_cap web_concurrency
        rss_growth_ratio prep_p95_drift_ratio
        restarts_max error_rate_ceiling no_usage_rate_ceiling
        coverage_min_ratio gap_seconds_max hourly_turn_floor
      ].freeze

      # Written after E1, before E2 (techspec D3). Absent -> `calibrated?` is
      # false and the 72h run refuses to start; the 4h dry run does not require them.
      CALIBRATED = %i[rss_ceiling_mb prep_p95_ceiling_ms total_p95_ceiling_ms].freeze

      # Keys validated as ratios: must be strictly greater than 1 (the gate is
      # "no more than 1.15x", so a ratio of 1 or below is a nonsense gate).
      RATIO_KEYS = %i[rss_growth_ratio prep_p95_drift_ratio].freeze

      # Keys validated as positive integers.
      POSITIVE_COUNT_KEYS = %i[
        duration_hours warmup_hours turns_per_hour session_turns
        concurrency_cap web_concurrency gap_seconds_max hourly_turn_floor
      ].freeze

      # Keys validated as rates in [0, 1].
      RATE_KEYS = %i[error_rate_ceiling no_usage_rate_ceiling coverage_min_ratio].freeze

      # Raises Insika::ConfigError: file missing, no fenced yaml block,
      # unparseable, a REQUIRED key absent, or a value out of range.
      def self.load(path)
        bytes = File.binread(path)
        parse(bytes, sha: "sha256:#{Digest::SHA256.hexdigest(bytes)}")
      rescue Errno::ENOENT
        raise ConfigError, "soak envelope not found: #{path}"
      end

      # Pure parse (specs, fixtures). `sha` is stamped verbatim.
      def self.parse(source, sha:)
        new(values: validate(YAML.safe_load(fenced_yaml(source)) || {}), sha: sha)
      rescue Psych::SyntaxError => e
        raise ConfigError, "soak envelope yaml is unparseable: #{e.message.lines.first.to_s.strip}"
      end

      def self.fenced_yaml(source)
        match = source.to_s.match(/```yaml\s*\n(.*?)\n```/m)
        raise ConfigError, "soak envelope has no fenced yaml block" unless match

        # Markdown fence content may be indented; YAML cares about the column.
        lines = match[1].lines
        indent = lines.reject { |l| l.strip.empty? }.map { |l| l[/\A */].length }.min
        lines.map { |l| l[indent..] || "\n" }.join
      end
      private_class_method :fenced_yaml

      def self.validate(raw)
        values = raw.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v if k.to_s =~ /\A[a-z_][a-z0-9_]*\z/
        end

        REQUIRED.each do |key|
          raise ConfigError, "soak envelope is missing required key: #{key}" if values[key].nil?
        end

        RATIO_KEYS.each do |key|
          v = values[key]
          unless v.is_a?(Numeric) && v > 1
            raise ConfigError, "soak envelope key #{key} must be > 1 (got #{v.inspect})"
          end
        end

        POSITIVE_COUNT_KEYS.each do |key|
          v = values[key]
          unless v.is_a?(Integer) && v.positive?
            raise ConfigError, "soak envelope key #{key} must be a positive integer (got #{v.inspect})"
          end
        end

        unless values[:restarts_max].is_a?(Integer) && values[:restarts_max] >= 0
          raise ConfigError, "soak envelope key restarts_max must be >= 0 (got #{values[:restarts_max].inspect})"
        end

        RATE_KEYS.each do |key|
          v = values[key]
          unless v.is_a?(Numeric) && v >= 0 && v <= 1
            raise ConfigError, "soak envelope key #{key} must be a rate in 0..1 (got #{v.inspect})"
          end
        end

        unless values[:warmup_hours] < values[:duration_hours]
          raise ConfigError, "soak envelope key warmup_hours must be < duration_hours " \
                             "(got #{values[:warmup_hours]} >= #{values[:duration_hours]})"
        end

        CALIBRATED.each do |key|
          v = values[key]
          next if v.nil?

          unless v.is_a?(Numeric) && v.positive?
            raise ConfigError, "soak envelope key #{key} must be a positive number when set (got #{v.inspect})"
          end
        end

        values.freeze
      end
      private_class_method :validate

      attr_reader :sha, :values

      def initialize(values:, sha:)
        @values = values
        @sha = sha
      end

      def [](key) = values[key]

      def calibrated? = CALIBRATED.all? { |key| !values[key].nil? }

      # E1 shape (<= 8h): the dry run skips the calibrated ceilings.
      def dry_run? = values[:duration_hours] <= 8

      def to_h = values.merge(sha: sha)
    end
  end
end
