# frozen_string_literal: true

module Insika
  module Evals
    # Runs each moderator over the same labeled messages and counts how they
    # differ from the label. Pure: the moderators are injected.
    class ModeratorCompare
      BLOCKS = %w[refuse escalate].freeze

      def initialize(moderators:)
        @moderators = moderators
      end

      def run(cases)
        @moderators.to_h { |name, mod| [name, score(mod, cases)] }
      end

      private

      def score(mod, cases)
        r = { "correct" => 0, "total" => cases.size, "false_blocks" => 0, "missed_blocks" => 0,
              "unavailable" => 0, "misses" => [] }
        times = cases.map do |c|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          v = mod.classify(c["message"])
          tally(r, c, v)
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
        end.sort
        r.merge("p50_ms" => pct(times, 0.5), "p95_ms" => pct(times, 0.95))
      end

      def tally(r, c, v)
        r["unavailable"] += 1 if v.unavailable?
        want_block = BLOCKS.include?(c["expected"])
        ok = want_block ? v.block? : !v.block? && !v.unavailable?
        return r["correct"] += 1 if ok

        r["misses"] << c["id"]
        r["false_blocks"] += 1 if !want_block && v.block?
        r["missed_blocks"] += 1 if want_block && !v.block?
      end

      def pct(sorted, q) = sorted.empty? ? 0 : sorted[((sorted.size - 1) * q).round].round(1)
    end
  end
end
