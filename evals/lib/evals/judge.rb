# frozen_string_literal: true

require "json"

module Evals
  # The LLM-judge (RFC-0008 §3.3, Fase B). Scores a golden's `rubric` against the
  # actual assistant reply — the subjective layer on top of the deterministic
  # asserts. Pure over an injected `ask` callable (prompt -> raw model text), so it's
  # unit-testable without an LLM; the real ask (RubyLLM on the utility_model, temp 0)
  # is built by the CLI.
  #
  # Conservative by construction: an unparseable judge reply scores 0 (fails) rather
  # than silently passing, and a borderline case can be settled by a quorum (median
  # of N samples) to blunt single-shot flakiness.
  class Judge
    Verdict = Struct.new(:score, :pass, :reason, keyword_init: true)

    DEFAULT_MIN_SCORE = 0.7

    # ask: ->(prompt) { "<raw model text>" }. quorum: samples per case (median wins).
    def initialize(ask:, quorum: 1)
      @ask = ask
      @quorum = [quorum.to_i, 1].max
    end

    # Golden + the LAST TurnResult -> Verdict, or nil when there's nothing to judge
    # (no rubric). `min_score` comes from the golden (default 0.7).
    def score(golden:, result:)
      rubric = golden.rubric.to_s.strip
      return nil if rubric.empty?

      prompt = build_prompt(rubric, golden.user_turns, result.output_text.to_s)
      samples = Array.new(@quorum) { parse(@ask.call(prompt).to_s) }
      med = median(samples.map { |s| s[:score] })
      min = golden.min_score || DEFAULT_MIN_SCORE
      Verdict.new(score: med.round(3), pass: med >= min,
                  reason: samples.map { |s| s[:reason] }.compact.reject(&:empty?).first.to_s)
    end

    private

    def build_prompt(rubric, user_turns, reply)
      <<~PROMPT
        You are a strict QA judge for a customer-service AI assistant. Judge the
        ASSISTANT REPLY against the RUBRIC — nothing else.

        RUBRIC:
        #{rubric}

        CONVERSATION (user turns, in order):
        #{user_turns.map { |t| "- #{t}" }.join("\n")}

        ASSISTANT REPLY:
        #{reply}

        Score from 0.0 (fails the rubric) to 1.0 (fully meets it). Respond with ONLY a
        JSON object, no prose:
        {"score": <0..1>, "reason": "<one short sentence>"}
      PROMPT
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
end
