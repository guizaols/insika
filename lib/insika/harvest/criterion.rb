# frozen_string_literal: true

require "digest"
require "yaml"

module Insika
  module Harvest
    # C4 — the frozen conversion criterion (RFC §4.3), parsed from
    # `harvest/CRITERION.md`. The parity shape (Parity::Criterion) copied: one
    # file, one ```yaml fence, the WHOLE bytes hashed (an edit to the rationale
    # invalidates the frozen rule too), strict keys, no defaults. A skill may
    # land only when the store's ruler is not measurably worse than the
    # accepted state — the FILE is the criterion; a profile carries no
    # thresholds, and `GateHarvest`/`PromoteHarvest` receive the loaded
    # criterion (with its sha) at boot.
    class Criterion
      Rule = Data.define(:version, :metric, :window, :threshold, :min_span)

      attr_reader :rule, :path, :sha

      def initialize(rule:, path:, sha:)
        @rule = rule
        @path = path
        @sha = sha
      end

      # Reads the file, extracts the FIRST ```yaml fence, validates STRICTLY.
      # Raises Insika::ConfigError when the file is absent or has no block;
      # Insika::ValidationError on an unknown or missing key, or a malformed
      # value — every defect named.
      def self.load(path)
        bytes = read_bytes(path)
        block = extract_yaml_block(bytes)
        parsed = YAML.safe_load(block, permitted_classes: [], aliases: false)
        rule = build_rule(parsed)
        new(rule: rule, path: path, sha: "sha256:#{Digest::SHA256.hexdigest(bytes)}")
      end

      def to_h = @rule.to_h

      class << self
        private

        def read_bytes(path)
          File.read(path, encoding: "UTF-8")
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
          raise Insika::ConfigError, "harvest criterion not readable at #{path}: #{e.class}"
        end

        def extract_yaml_block(bytes)
          match = bytes.match(/```yaml\n(.*?)\n```/m)
          raise Insika::ConfigError, "harvest criterion has no ```yaml block (nothing to pre-register)" unless match

          match[1]
        end

        def build_rule(parsed)
          raise Insika::ValidationError, "criterion yaml block must be a mapping" unless parsed.is_a?(Hash)

          raw = parsed.transform_keys(&:to_s)
          keys = raw.keys.sort
          missing = Rule.members.map(&:to_s) - keys
          unknown = keys - Rule.members.map(&:to_s)
          raise Insika::ValidationError, "harvest criterion is missing key(s): #{missing.join(', ')}" if missing.any?
          raise Insika::ValidationError, "harvest criterion has unknown key(s): #{unknown.join(', ')}" if unknown.any?

          validate!(raw)
          Rule.new(**Rule.members.to_h { |m| [m, raw[m.to_s]] })
        end

        # Each defect named — a criterion nobody can read is a criterion
        # nobody froze (D5).
        def validate!(raw)
          version = raw["version"]
          raise Insika::ValidationError, "harvest criterion version must be an Integer (got #{version.inspect})" unless version.is_a?(Integer)

          metric = raw["metric"].to_s
          raise Insika::ValidationError, "harvest criterion metric must be a non-blank string" if metric.empty?

          window = raw["window"].to_s
          unless window.match?(/\A\d+h\z/)
            raise Insika::ValidationError, "harvest criterion window must match /\\A\\d+h\\z/ (got #{raw['window'].inspect})"
          end

          min_span = raw["min_span"].to_s
          unless min_span.match?(/\A\d+d\z/)
            raise Insika::ValidationError, "harvest criterion min_span must match /\\A\\d+d\\z/ (got #{raw['min_span'].inspect})"
          end

          threshold = raw["threshold"]
          unless threshold.is_a?(Float) && threshold >= 0 && threshold <= 1
            raise Insika::ValidationError, "harvest criterion threshold must be a Float in 0..1 (got #{threshold.inspect})"
          end
        end
      end
    end
  end
end