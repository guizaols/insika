# frozen_string_literal: true

require "json"

module Insika
  module Evals
    # The LLM-judge (RFC-0008 §3.3, Fase B). Scores a golden's `rubric` against the
    # actual assistant reply — the subjective layer on top of the deterministic
    # asserts. Pure over an injected `ask` callable (prompt -> raw model text), so it's
    # unit-testable without an LLM; the real ask (RubyLLM on the utility_model, temp 0)
    # is built by the CLI.
    #
    # Conservative by construction: an unparseable judge reply scores 0 (fails) rather
    # than silently passing.
    #
    # A PANEL, not a single voice (RFC-0013 §3.9). `quorum: N` samples ONE model N
    # times, which measures that model's variance and little else — at temperature 0 it
    # mostly returns the same answer, including the same blind spot. Two DIFFERENT
    # models disagreeing about a rubric is the signal worth having, so `asks:` takes one
    # callable per model: each judge is scored independently (its own samples, its own
    # median, its own pass/fail against the case's `min_score`), then
    #   • `aggregate`     combines the scores into the one the report and the baseline
    #                     read (:median | :mean | :min — :min is the strict panel),
    #   • `min_agreement` decides the verdict: the FRACTION of judges that must pass on
    #                     their own. 0.5 = a majority; 1.0 = unanimous.
    # `quorum` still applies, per judge, so a panel can also be sampled.
    class Judge
      # `judges` carries the per-model scores, so a split panel is visible in the report
      # instead of hiding inside an average.
      Verdict = Struct.new(:score, :pass, :reason, :judges, keyword_init: true)

      DEFAULT_MIN_SCORE = 0.7
      AGGREGATES = %i[median mean min].freeze

      # The store's operating policy, stated to the judge in the same words the
      # deterministic layer checks. Empty when the store has no opinion — then the
      # rubric alone decides, and inventing a default here would be inventing an
      # opinion for someone else's store.
      POLICY_INSTRUCTIONS = {
        "ask_once" => "This store allows AT MOST ONE question per reply. Two questions in " \
                      "one message is a failure even if the content is otherwise good.",
        "investigate_first" => "This store wants the objective established BEFORE acting: on a " \
                               "vague request the assistant should ask (once or twice, not a " \
                               "form), not search immediately.",
        "act_fast" => "This store wants the assistant to ACT on the first plausible reading and " \
                      "refine after — asking something it could have answered by searching is a " \
                      "failure."
      }.freeze

      # ask:  ->(prompt) { "<raw model text>" } — one judge (kept: the common case).
      # asks: [callable, …] — a panel, one entry per model.
      def initialize(ask: nil, asks: nil, quorum: 1, aggregate: :median, min_agreement: 0.5)
        @asks = Array(asks || ask).compact
        raise ArgumentError, "a judge needs at least one `ask`" if @asks.empty?

        @quorum = [quorum.to_i, 1].max
        @aggregate = aggregate.to_s.to_sym
        raise ArgumentError, "unknown aggregate: #{aggregate}" unless AGGREGATES.include?(@aggregate)

        @min_agreement = min_agreement.to_f.clamp(0.0, 1.0)
      end

      # Golden + the LAST TurnResult -> Verdict, or nil when there's nothing to judge
      # (no rubric). `min_score` comes from the golden (default 0.7).
      def score(golden:, result:)
        rubric = golden.rubric.to_s.strip
        return nil if rubric.empty?

        prompt = build_prompt(rubric, golden.user_turns, result.output_text.to_s, golden.policy)
        min = golden.min_score || DEFAULT_MIN_SCORE
        panel = @asks.map { |ask| judge_once(ask, prompt, min) }

        agreed = panel.count { |j| j[:pass] }
        Verdict.new(score: combine(panel.map { |j| j[:score] }).round(3),
                    pass: (agreed.to_f / panel.length) >= @min_agreement,
                    reason: panel.map { |j| j[:reason] }.reject(&:empty?).first.to_s,
                    judges: panel.map { |j| j[:score] })
      end

      private

      # One model's verdict: its own samples, its own median, its own pass/fail.
      def judge_once(ask, prompt, min)
        samples = Array.new(@quorum) { parse(ask.call(prompt).to_s) }
        med = median(samples.map { |s| s[:score] })
        { score: med, pass: med >= min,
          reason: samples.map { |s| s[:reason] }.compact.reject(&:empty?).first.to_s }
      end

      def combine(scores)
        case @aggregate
        when :mean then scores.empty? ? 0.0 : scores.sum / scores.length.to_f
        when :min then scores.min || 0.0
        else median(scores)
        end
      end

      # The `policy` is the one thing a rubric cannot carry alone (RFC-0014 §3.3): how
      # much this store wants the agent to ask before acting is a per-store decision,
      # and a judge that is not TOLD it will guess — half the time wrongly. The
      # deterministic half is `Assertions.policy_checks`; this is the other half.
      def build_prompt(rubric, user_turns, reply, policy = nil)
        <<~PROMPT
          You are a strict QA judge for a customer-service AI assistant. Judge the
          ASSISTANT REPLY against the RUBRIC — nothing else.

          RUBRIC:
          #{rubric}
          #{policy_clause(policy)}
          CONVERSATION (user turns, in order):
          #{user_turns.map { |t| "- #{t}" }.join("\n")}

          ASSISTANT REPLY:
          #{reply}

          Score from 0.0 (fails the rubric) to 1.0 (fully meets it). Respond with ONLY a
          JSON object, no prose:
          {"score": <0..1>, "reason": "<one short sentence>"}
        PROMPT
      end

      def policy_clause(policy)
        instruction = POLICY_INSTRUCTIONS[policy.to_s]
        return "" unless instruction

        "\nSTORE POLICY (weigh this as part of the rubric):\n#{instruction}\n"
      end

      # Extracts the first {...} block and parses it. Any failure (no JSON, bad JSON,
      # non-numeric score) -> score 0.0 with a diagnostic reason, so a broken judge
      # never masquerades as a pass. Score is clamped to [0,1].
      def parse(raw)
        block = raw[/\{.*\}/m]
        raise JSON::ParserError, "no JSON object" unless block

        obj = JSON.parse(block)
        score = Float(obj["score"])
        { score: score.clamp(0.0, 1.0), reason: obj["reason"].to_s }
      rescue JSON::ParserError, ArgumentError, TypeError
        { score: 0.0, reason: "unparseable judge output: #{raw.to_s[0, 120].inspect}" }
      end

      def median(nums)
        sorted = nums.compact.sort
        return 0.0 if sorted.empty?

        mid = sorted.length / 2
        sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
      end
    end

    # Builds the configured judge panel from `settings["evals"]` (RFC-0013 §3.9).
    #
    # It lives HERE and not in `evals/run.rb` because the CLI is no longer the only
    # caller: the refinement gate scores a candidate with the SAME judges the operator
    # configured, and §3.7 is explicit that a second copy of the judge would be the
    # worst possible outcome — the gate would then be grading against a rubric nobody
    # tuned. One builder, two callers.
    module JudgePanel
      module_function

      # settings: the `evals` hash (judges/quorum/aggregate/min_agreement).
      # overrides: the CLI's flags, which win over the stored config.
      # -> [Judge, [model names]] | nil when nobody is configured to ask. NIL AND NOT
      # a no-op judge: a rubric'd case with no judge reads as `judge_pending`, which is
      # visible, where a judge that always passes would be silent.
      def build(settings, overrides: {}, chat_factory: nil)
        settings = Coercion.deep_stringify(settings || {})
        overrides = overrides.transform_keys(&:to_s)
        models = resolve_models(settings, overrides)
        return nil if models.empty?

        factory = chat_factory || method(:ruby_llm_ask)
        judge = Judge.new(
          asks: models.map { |m| factory.call(m["model"], m["provider"]) },
          quorum: overrides["quorum"] || settings["quorum"] || 1,
          aggregate: overrides["aggregate"] || settings["aggregate"] || "median",
          min_agreement: overrides["min_agreement"] || settings["min_agreement"] || 0.5
        )
        [judge, models.map { |m| m["model"] }]
      end

      # Sugar for the callers that only want the judge (the gate).
      def judge(settings, **kw) = build(settings, **kw)&.first

      def resolve_models(settings, overrides)
        models = if Coercion.present?(overrides["judge_model"])
                   [{ "model" => overrides["judge_model"], "provider" => overrides["judge_provider"] }]
                 else
                   Array(settings["judges"])
                 end
        models.map { |m| Coercion.deep_stringify(m) }.reject { |m| m["model"].to_s.strip.empty? }
      end

      # The default way to reach a model: RubyLLM, temperature 0, required lazily so
      # nothing here loads a provider gem until a judge is actually configured.
      def ruby_llm_ask(model, provider)
        require "ruby_llm"
        lambda do |prompt|
          RubyLLM.chat(model: model, provider: provider, assume_model_exists: true)
                 .with_temperature(0).ask(prompt).content
        end
      end
    end
  end
end
