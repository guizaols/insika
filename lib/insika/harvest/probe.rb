# frozen_string_literal: true

module Insika
  module Harvest
    # The probe half of the eval gate: does the candidate skill HELP the
    # conversation it was mined from? The golden replay only proves it breaks
    # nothing. The gate replays the origin's customer turns on the clone
    # without the skill and then with it, and the pairwise judge compares the
    # two. Pure functions here; the replay lives in Gate.
    module Probe
      MAX_CASES = 3
      MAX_TURNS = 4

      # sessions: [[{ "role", "content" }]] -> [[customer text]]. A session is
      # cut at its last evidence turn (the moment the miner pointed at), or
      # kept whole when no evidence index fits it.
      def self.cases(sessions, evidence_turns:, max_cases: MAX_CASES, max_turns: MAX_TURNS)
        sessions.filter_map do |messages|
          messages = Array(messages)
          last = Array(evidence_turns).map(&:to_i).select { |t| t < messages.size }.max
          scope = last ? messages[0..last] : messages
          turns = scope.select { |m| m["role"].to_s == "user" }
                       .map { |m| m["content"].to_s.strip }
                       .reject(&:empty?)
                       .first(max_turns)
          turns unless turns.empty?
        end.first(max_cases)
      end

      # [Pairwise::Verdict | nil] -> Hash. A veto like the golden gate: any
      # `worse` fails, and so does a probe where nothing got better.
      # split/unknown/nil express no preference, so they count as comparable.
      def self.verdict(outcomes)
        better = outcomes.select { |v| v&.outcome == Insika::Evals::Pairwise::BETTER }
        worse = outcomes.select { |v| v&.outcome == Insika::Evals::Pairwise::WORSE }
        reason = if worse.any? then "probe_worse: #{worse.first.reason}"
                 elsif better.empty? then "probe_no_gain: no case improved over the agent without the skill"
                 end
        { "passed" => reason.nil?, "reason" => reason, "better" => better.size,
          "comparable" => outcomes.size - better.size - worse.size, "worse" => worse.size,
          "cases" => outcomes.size,
          "verdicts" => outcomes.map { |v| v && { "outcome" => v.outcome, "reason" => v.reason } } }
      end
    end
  end
end
