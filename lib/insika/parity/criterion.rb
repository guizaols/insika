# frozen_string_literal: true

require "digest"
require "yaml"

module Insika
  module Parity
    # C5 — the frozen criterion, parsed from `evals/PARITY.md`.
    # The prose a human reads and the yaml block the machine applies are the SAME
    # file, so there is exactly one place to edit — and the file's WHOLE bytes are
    # hashed, so an edit to the rationale invalidates the frozen rule too, which is
    # correct: the rationale is what makes the numbers reviewable.
    #
    # Strict by construction: a missing key or an unknown key is refused at load
    # (`ValidationError`), and no key has a default — a number the machine filled in
    # is a number nobody pre-registered (RFC §4.4).
    class Criterion
      Rule = Data.define(
        :version, :unit, :window_days, :pairs_per_day, :min_decided,
        :min_judge_models, :both_orders,
        :win_or_tie_floor, :estimator,
        :worse_rate_ceiling, :undecided_rate_ceiling, :incomplete_rate_ceiling,
        :per_agent_min_decided, :per_agent_win_or_tie_floor,
        :human_assisted, :silent
      )

      attr_reader :rule, :path, :sha

      def initialize(rule:, path:, sha:)
        @rule = rule
        @path = path
        @sha = sha
      end

      # Reads the file, extracts the FIRST ```yaml fence, validates STRICTLY.
      # Raises Insika::ConfigError when the file is absent or has no block;
      # Insika::ValidationError on an unknown or missing key.
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
          raise Insika::ConfigError, "parity criterion not readable at #{path}: #{e.class}"
        end

        def extract_yaml_block(bytes)
          match = bytes.match(/```yaml\n(.*?)\n```/m)
          raise Insika::ConfigError, "parity criterion has no ```yaml block (nothing to pre-register)" unless match

          match[1]
        end

        def build_rule(parsed)
          raise Insika::ValidationError, "criterion yaml block must be a mapping" unless parsed.is_a?(Hash)

          raw = parsed.transform_keys(&:to_s)
          keys = raw.keys.sort
          missing = Rule.members.map(&:to_s) - keys
          unknown = keys - Rule.members.map(&:to_s)
          raise Insika::ValidationError, "criterion is missing key(s): #{missing.join(', ')}" if missing.any?
          raise Insika::ValidationError, "criterion has unknown key(s): #{unknown.join(', ')}" if unknown.any?

          Rule.new(**Rule.members.to_h { |m| [m, raw[m.to_s]] })
        end
      end
    end
  end
end
