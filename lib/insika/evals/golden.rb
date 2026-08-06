# frozen_string_literal: true

require "yaml"

# Evals — the quality harness (RFC-0008). It lives in `lib/` so the engine itself can
# call it (the refinement gate of RFC-0013 needs to score a candidate agent, and a
# second copy of the judge would be the worst possible outcome), but it stays a
# CLIENT: it reaches a running deployment over HTTP through `HttpTransport` and never
# reads a store directly. `evals/run.rb` is a thin CLI over this module.
module Insika
  module Evals
    # A curated behavior case, loaded from a data file (evals/golden/<agent>/*.yml).
    # Data, not code — same spirit as tools-as-data. See evals/README.md for the format.
    Golden = Struct.new(:id, :agent, :turns, :expect, :source, keyword_init: true) do
      # The user messages to replay, in order.
      def user_turns = turns.map { |t| t["user"] }

      # Tool refs the case expects; a trailing "?" marks OPTIONAL (never fails).
      # -> [{ name:, optional: }]
      def tools_called
        Array(expect["tools_called"]).map do |ref|
          s = ref.to_s
          optional = s.end_with?("?")
          { name: optional ? s[0..-2] : s, optional: optional }
        end
      end

      # Names of the negative assertions to run (e.g. "pii_leak", "tool_error").
      def must_not = Array(expect["must_not"]).map(&:to_s)

      # How much the agent should ask before acting (RFC-0014 §3.3). nil = the store
      # has no opinion and only the rubric decides.
      def policy = GoldenLoader.presence(expect["policy"])

      # LLM-judge rubric + threshold (consumed in Fase B — deferred here).
      def rubric = expect["rubric"]
      def min_score = expect["min_score"]
    end

    # Loads + validates golden files. Fails LOUD on a malformed case — a silently
    # dropped golden is a hole in the safety net.
    module GoldenLoader
      class InvalidGolden < StandardError; end

      module_function

      # Loads every *.yml/*.yaml under `dir` (recursive), sorted by path for a stable
      # run order. -> [Golden].
      def load_dir(dir)
        Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).sort.map { |f| load_file(f) }
      end

      def load_file(path)
        raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
        build(raw, source: path)
      rescue Psych::SyntaxError => e
        raise InvalidGolden, "#{path}: invalid YAML — #{e.message}"
      end

      # hash (string keys) -> validated Golden. `source` is only for error messages.
      def build(raw, source: "(inline)")
        raise InvalidGolden, "#{source}: golden must be a mapping" unless raw.is_a?(Hash)

        id = presence(raw["id"]) || (raise InvalidGolden, "#{source}: 'id' is required")
        agent = presence(raw["agent"]) || (raise InvalidGolden, "#{source}: 'agent' is required (case '#{id}')")
        turns = normalize_turns(raw["turns"], id: id, source: source)
        expect = raw["expect"] || {}
        raise InvalidGolden, "#{source}: 'expect' must be a mapping (case '#{id}')" unless expect.is_a?(Hash)

        validate_policy!(expect["policy"], id: id, source: source)
        Golden.new(id: id, agent: agent, turns: turns, expect: expect, source: source)
      end

      # A typo'd policy must not silently mean "no policy" — the case would go on
      # passing while the rule it was written for stopped being checked. The
      # `Assertions` constant is resolved at CALL time (this file loads first, and
      # assertions.rb touches `Safety::Detectors` at load time).
      def validate_policy!(value, id:, source:)
        name = presence(value)
        return if name.nil? || Assertions::POLICIES.key?(name)

        raise InvalidGolden, "#{source}: unknown policy #{name.inspect} (case '#{id}') — " \
                             "known: #{Assertions::POLICIES.keys.join(', ')}"
      end

      # turns: a non-empty array of { "user" => String }. Rejects anything else so a
      # typo (e.g. `users:`) surfaces at load time, not as an empty replay.
      def normalize_turns(turns, id:, source:)
        unless turns.is_a?(Array) && !turns.empty?
          raise InvalidGolden, "#{source}: 'turns' must be a non-empty array (case '#{id}')"
        end

        turns.each_with_index.map do |t, i|
          user = t.is_a?(Hash) ? presence(t["user"]) : nil
          user || (raise InvalidGolden, "#{source}: turns[#{i}] needs a non-empty 'user' (case '#{id}')")
          { "user" => user }
        end
      end

      def presence(v)
        s = v.to_s.strip
        s.empty? ? nil : s
      end
    end
  end
end
