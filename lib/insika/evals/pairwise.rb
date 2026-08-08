# frozen_string_literal: true

require "json"

module Insika
  module Evals
    # PAIRWISE AGAINST THE INCUMBENT (RFC-0014 §3.4) — the number that answers "can we
    # replace it". An absolute 0.72 says a reply cleared a bar we invented; it says
    # nothing about whether the system already answering 403,231 chats would have done
    # better with the same customer.
    #
    # Same opening, two transcripts, one question: which one served the customer
    # better? Three outcomes (better / comparable / worse), plus two the panel can
    # produce and must not hide — `split` when the judges disagree and `unknown` when
    # none of them answered in a readable way.
    #
    # Three honesty rules, each of them the difference between a number people should
    # trust and one they should not:
    #
    # 1. **Anonymous.** The judge sees "A" and "B" and is never told which one is
    #    Insika. Told, it would have an opinion about the new system rather than about
    #    the conversations.
    # 2. **Both orders, every judge.** Position bias is THE known failure of pairwise
    #    LLM judging, and it is the same species as the kill criterion ("`better`
    #    tracks length, or politeness"). So each judge is asked twice with the
    #    transcripts swapped, and a verdict that FLIPS with presentation order is
    #    reported as `comparable` with `order_dependent: true` — a preference that
    #    depends on which one was printed first is not a preference.
    # 3. **A split panel stays split.** Averaging "better" and "worse" into
    #    "comparable" invents agreement that nobody expressed.
    #
    # Cost: 2 provider calls per judge per case (§5). This is why it never runs as
    # part of the gate and is opt-in on the CLI.
    class Pairwise
      BETTER = "better"
      COMPARABLE = "comparable"
      WORSE = "worse"
      SPLIT = "split"
      UNKNOWN = "unknown"

      # `vs` names WHO the reference half actually is: `agent` (model against model)
      # or `human-assisted` (a person typed part of it, P23a's `origin: operator`).
      # It rides on the verdict rather than beside it so a report cannot print the
      # outcome without the label.
      Verdict = Struct.new(:outcome, :reason, :vs, :judges, :order_dependent, keyword_init: true) do
        def human_assisted? = vs == "human-assisted"
        def decided? = [BETTER, COMPARABLE, WORSE].include?(outcome)
      end

      # asks: [->(prompt) { "<raw model text>" }] — the SAME panel the rubric judge
      # uses (JudgePanel builds both), because "the judges the operator configured" is
      # one decision, not two.
      def initialize(asks:)
        @asks = Array(asks).compact
        raise ArgumentError, "a pairwise comparison needs at least one `ask`" if @asks.empty?
      end

      # golden + the run's [TurnResult] -> Verdict, or nil when the case carries no
      # reference (most of them: a pair is curated by a human, like the case itself).
      def compare(golden:, turns:)
        return nil unless golden.reference?

        ours = Pairwise.transcript(golden.user_turns, turns)
        theirs = Pairwise.reference_transcript(golden.reference_messages)
        return nil if ours.strip.empty?

        panel = @asks.map { |ask| judge_once(ask, ours, theirs) }
        combine(panel, vs: golden.human_assisted? ? "human-assisted" : "agent")
      end

      # The replayed conversation as the judge reads it: the user turns we sent,
      # interleaved with the answers the deployment published. `turns` may be shorter
      # than `user_turns` (an errored turn aborts the replay) — zip on what ran.
      def self.transcript(user_turns, turns)
        Array(turns).each_with_index.map do |t, i|
          ["customer: #{user_turns[i]}", "assistant: #{t.output_text.to_s.strip}"]
        end.flatten.join("\n")
      end

      # The incumbent's half. Human turns are NOT flagged to the judge: what it grades
      # is the conversation as the customer received it, and telling it "a person wrote
      # this one" is an invitation to grade the author instead. The fact is carried to
      # the READER as `vs: human-assisted` instead, which is where it changes a decision.
      def self.reference_transcript(messages)
        Array(messages).map do |m|
          speaker = m["role"].to_s == "user" ? "customer" : "assistant"
          "#{speaker}: #{m['text'].to_s.strip}"
        end.join("\n")
      end

      private

      # One model, asked twice with the sides swapped. -> { outcome:, reason:,
      # order_dependent: }
      def judge_once(ask, ours, theirs)
        first = outcome_of(parse(ask.call(prompt(ours, theirs))), ours_is: "A")
        second = outcome_of(parse(ask.call(prompt(theirs, ours))), ours_is: "B")

        return { outcome: UNKNOWN, reason: [first[:reason], second[:reason]].compact.first.to_s, order_dependent: false } \
          if first[:outcome] == UNKNOWN && second[:outcome] == UNKNOWN

        reason = [first[:reason], second[:reason]].reject { |r| r.to_s.empty? }.first.to_s
        agreed = [first[:outcome], second[:outcome]].reject { |o| o == UNKNOWN }.uniq
        return { outcome: agreed.first, reason: reason, order_dependent: false } if agreed.length == 1

        { outcome: COMPARABLE, reason: reason, order_dependent: true }
      end

      # A strict majority decides; anything less is `split`. Unknown judges are left
      # OUT of the tally (they expressed nothing) but stay visible in `judges`.
      def combine(panel, vs:)
        voted = panel.reject { |j| j[:outcome] == UNKNOWN }
        winner, group = voted.group_by { |j| j[:outcome] }.max_by { |_, js| js.length }
        outcome = if voted.empty? then UNKNOWN
                  elsif group.length * 2 > voted.length then winner
                  else SPLIT
                  end
        # The reason comes from the judges that CARRIED the verdict, so a split or an
        # unknown is explained by whoever produced it rather than by an outvoted one.
        spoke = outcome == winner ? group : panel

        Verdict.new(outcome: outcome, vs: vs,
                    reason: spoke.map { |j| j[:reason].to_s }.reject(&:empty?).first.to_s,
                    judges: panel.map { |j| j[:outcome] },
                    order_dependent: panel.any? { |j| j[:order_dependent] })
      end

      # "A won" means Insika won only when Insika WAS A. The mapping is the whole
      # point of asking twice.
      def outcome_of(parsed, ours_is:)
        winner = parsed[:winner]
        outcome = case winner
                  when "tie" then COMPARABLE
                  when nil then UNKNOWN
                  else winner == ours_is ? BETTER : WORSE
                  end
        { outcome: outcome, reason: parsed[:reason] }
      end

      def prompt(a, b)
        <<~PROMPT
          You are comparing two customer-service conversations that began with the SAME
          customer message. Decide which one SERVED THE CUSTOMER BETTER: did the customer
          get what they came for, without detours, wrong information or invented facts?

          Ignore length, tone, politeness, emoji and formatting UNLESS they changed what
          the customer actually got. A short answer that solves the problem beats a long
          one that does not.

          CONVERSATION A:
          #{a}

          CONVERSATION B:
          #{b}

          Respond with ONLY a JSON object, no prose:
          {"winner": "A" | "B" | "tie", "reason": "<one short sentence>"}
        PROMPT
      end

      # An unreadable reply is UNKNOWN, never a preference: scoring it as a tie would
      # quietly count a broken judge as evidence that the two systems are equivalent.
      def parse(raw)
        block = raw.to_s[/\{.*\}/m]
        raise JSON::ParserError, "no JSON object" unless block

        obj = JSON.parse(block)
        winner = obj["winner"].to_s.strip.upcase
        winner = "tie" if %w[TIE DRAW EQUAL COMPARABLE].include?(winner)
        raise JSON::ParserError, "unknown winner" unless %w[A B tie].include?(winner)

        { winner: winner, reason: obj["reason"].to_s }
      rescue JSON::ParserError, TypeError
        { winner: nil, reason: "unparseable pairwise output: #{raw.to_s[0, 120].inspect}" }
      end
    end
  end
end
