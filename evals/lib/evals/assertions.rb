# frozen_string_literal: true

# D4 (RFC-0009): the PII/secret patterns live in the RUNTIME (single source of
# truth) — the eval is a CLIENT of the server by design, so it consumes them from
# there rather than keeping a divergent copy. The file is self-contained (no other
# Insika require), so this load is cheap and standalone.
require_relative "../../../lib/insika/safety/detectors"

module Evals
  # What the runner extracts from ONE replayed conversation, entirely from the
  # public SSE stream of POST /v1/responses (no store reads — the eval stays a
  # client). The assertion engine is pure over this value, so it's unit-testable
  # offline without a server.
  #
  #   output_text: the final assistant text (for content checks)
  #   tool_calls:  [{ "name" =>, "status" => }] captured from the stream's tool events
  #   error:       transport/turn error string, or nil on a clean turn
  TurnResult = Struct.new(:output_text, :tool_calls, :error, keyword_init: true) do
    def tool_names = Array(tool_calls).map { |t| (t["name"] || t[:name]).to_s }

    # A tool call whose status is anything but a success ("ok"/2xx/"success").
    def errored_tools
      Array(tool_calls).reject { |t| Assertions.ok_status?(t["status"] || t[:status]) }
    end
  end

  # A single check within a case (e.g. "tool:shipping_quote", "must_not:pii_leak").
  Check = Struct.new(:name, :pass, :detail, keyword_init: true)

  # The verdict for one golden case. `judge` (a Judge::Verdict) is attached AFTER
  # the deterministic pass when the case has a rubric and a judge is configured;
  # until then a rubric'd case is `judge_pending?` — it reads as "not fully
  # evaluated", never a silent pass. A case passes only if the deterministic checks
  # pass AND (there's no judge verdict OR it passed).
  CaseResult = Struct.new(:id, :agent, :checks, :error, :rubric, :judge, keyword_init: true) do
    def pass? = error.nil? && checks.all?(&:pass) && (judge.nil? || judge.pass)
    def failures = checks.reject(&:pass)
    # Has a rubric to score but no verdict yet (judge disabled / not run).
    def judge_pending? = !rubric.to_s.strip.empty? && judge.nil?
  end

  # Deterministic (Fase A) evaluation — cheap, zero-token, zero-flakiness. It's the
  # layer that catches the gross regressions (a tool stopped being called, a secret
  # leaked, the turn errored). Subjective scoring is the LLM-judge in Fase B.
  module Assertions
    # Named negative detectors for `must_not` now live in the runtime (D4). Kept as
    # an alias so any external reference to Evals::Assertions::PII_DETECTORS still
    # resolves; the values ARE the runtime's, never a fork.
    PII_DETECTORS = Insika::Safety::Detectors::PII

    module_function

    # A tool status counts as success when it's blank/"ok"/"success" or a 2xx code.
    def ok_status?(status)
      return true if status.nil?

      s = status.to_s.strip.downcase
      return true if s.empty? || %w[ok success succeeded done].include?(s)

      code = Integer(s, exception: false)
      code ? code.between?(200, 299) : false
    end

    # Golden + TurnResult -> CaseResult. A turn that failed to run yields a single
    # failing check (there's nothing to assert on a turn that never produced output).
    def evaluate(golden, result)
      if result.error
        return CaseResult.new(id: golden.id, agent: golden.agent, error: result.error, rubric: nil, judge: nil,
                              checks: [Check.new(name: "turn", pass: false, detail: "turn error: #{result.error}")])
      end

      checks = tool_checks(golden, result) + must_not_checks(golden, result)
      CaseResult.new(id: golden.id, agent: golden.agent, error: nil, checks: checks,
                     rubric: golden.rubric, judge: nil)
    end

    # Each REQUIRED expected tool must appear in the turn's tool calls. Optional
    # ("name?") tools are informational — present or not, they never fail.
    def tool_checks(golden, result)
      names = result.tool_names
      golden.tools_called.filter_map do |t|
        next if t[:optional]

        present = names.include?(t[:name])
        Check.new(name: "tool:#{t[:name]}", pass: present,
                  detail: present ? "called" : "expected but not called (saw: #{names.join(', ')})")
      end
    end

    # `must_not` detectors. "tool_error" is special (inspects statuses); the rest
    # are content detectors over the output text.
    def must_not_checks(golden, result)
      golden.must_not.map do |name|
        if name == "tool_error"
          bad = result.errored_tools
          Check.new(name: "must_not:tool_error", pass: bad.empty?,
                    detail: bad.empty? ? "no tool errors" : "errored: #{bad.map { |t| t['name'] || t[:name] }.join(', ')}")
        else
          hit = detect(name, result.output_text.to_s)
          Check.new(name: "must_not:#{name}", pass: hit.nil?,
                    detail: hit ? "matched #{hit.inspect}" : "clean")
        end
      end
    end

    # Runs a named detector over the text. "pii_leak" = union of all PII detectors;
    # otherwise a single named pattern. Delegates to the runtime's single source
    # (D4) — which itself fails loud on an unknown name (a typo'd assertion must not
    # silently pass).
    def detect(name, text)
      Insika::Safety::Detectors.detect(name, text)
    end
  end
end
