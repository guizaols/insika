# frozen_string_literal: true

# D4 (RFC-0009): the PII/secret patterns live in the RUNTIME (single source of
# truth) — the eval consumes them rather than keeping a divergent copy. Since the
# module moved under `lib/`, `Safety::Detectors` is loaded by `insika.rb` before this
# file; the explicit climb out of `evals/` that used to be here is gone.

module Insika
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
    #
    # `skipped` (a reason, nil = it ran) is the THIRD outcome (RFC-0014 §3.2): the
    # deployment lacks something the case declared it needs, so there was nothing to
    # assert. It is never a pass and never a failure — a suite of 40 cases where 12
    # are skipped says something true, where 40 cases with 12 failures on capability
    # grounds says nothing and gets ignored.
    CaseResult = Struct.new(:id, :agent, :checks, :error, :rubric, :judge, :skipped, keyword_init: true) do
      def skipped? = !skipped.nil?
      def pass? = !skipped? && error.nil? && checks.all?(&:pass) && (judge.nil? || judge.pass)
      def failures = checks.reject(&:pass)
      # Has a rubric to score but no verdict yet (judge disabled / not run). A skipped
      # case is not pending anything — nobody is going to judge a turn that never ran.
      def judge_pending? = !skipped? && !rubric.to_s.strip.empty? && judge.nil?
    end

    # Deterministic (Fase A) evaluation — cheap, zero-token, zero-flakiness. It's the
    # layer that catches the gross regressions (a tool stopped being called, a secret
    # leaked, the turn errored). Subjective scoring is the LLM-judge in Fase B.
    module Assertions
      # Named negative detectors for `must_not` now live in the runtime (D4). Kept as
      # an alias so any external reference to Evals::Assertions::PII_DETECTORS still
      # resolves; the values ARE the runtime's, never a fork.
      PII_DETECTORS = Insika::Safety::Detectors::PII

      # HOW MUCH THE AGENT SHOULD ASK BEFORE ACTING (RFC-0014 §3.3). Declared per
      # case because it is a per-STORE decision, not a universal rule: sometimes the
      # agent should establish the objective before searching ("energia, treino ou
      # sono?" — Acme does this well), and sometimes asking again is the
      # failure and it should just search. A global assertion would be wrong half
      # the time; the judge is TOLD the policy (Judge#build_prompt) and this layer
      # checks the half that needs no reader.
      #
      # Each rule is stated as the CUSTOMER-VISIBLE fact it checks. RFC-0014 phrased
      # this as "questions before the first tool call", written before P19: text a
      # model emits before calling a tool never reaches the customer now (it rides
      # `:intermediate`), and the eval is a client of `/v1/responses`, so what it can
      # observe per turn is the published answer plus the tools that turn called.
      # That is also the honest scope — a question nobody received is not a question.
      POLICIES = {
        # "UMA PERGUNTA POR VEZ" — the rule Insika broke twice under a 28 KB prompt.
        "ask_once" => "at most one question per reply",
        # Establish the objective before acting on a vague opener.
        "investigate_first" => "asks before calling a tool, on the first turn",
        # Act on the first plausible reading; refine after.
        "act_fast" => "calls a tool on the first turn instead of asking"
      }.freeze

      module_function

      # WHAT THIS DEPLOYMENT LACKS for the case to be worth running (RFC-0014 §3.2).
      # -> [reason]; empty = run it.
      #
      # `available` is the deployment's answer for this agent:
      #   { "tools" => [names] | nil, "capabilities" => [names] }
      # `tools` nil means an OPEN allowlist — the agent may call every registered tool,
      # so no tool requirement can be judged missing and the case runs. That is the
      # deliberate reading: "I could not rule it out" must not become a skip, or a
      # permissive agent would quietly stop being tested.
      def unmet_requirements(golden, available)
        tools = available["tools"]
        declared = Array(available["capabilities"]).map(&:to_s)

        missing_tools = tools.nil? ? [] : golden.required_tools - Array(tools).map(&:to_s)
        missing_caps = golden.required_capabilities - declared

        reasons = []
        reasons << "tool not available: #{missing_tools.join(', ')}" unless missing_tools.empty?
        reasons << "capability not declared: #{missing_caps.join(', ')}" unless missing_caps.empty?
        reasons
      end

      # The case did not run and MUST NOT read as either a pass or a failure.
      def skip(golden, reason)
        CaseResult.new(id: golden.id, agent: golden.agent, checks: [], error: nil,
                       rubric: nil, judge: nil, skipped: reason)
      end

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
      #
      # `turns` is every turn of the conversation, in order; `result` is the last one
      # (what the tool/content assertions have always run on). The policy checks need
      # all of them — "one question per reply" is a rule about every reply, and the
      # violation that motivated this was on the FIRST turn. Defaults to the single
      # result so existing callers keep working.
      def evaluate(golden, result, turns: nil)
        if result.error
          return CaseResult.new(id: golden.id, agent: golden.agent, error: result.error, rubric: nil, judge: nil,
                                checks: [Check.new(name: "turn", pass: false, detail: "turn error: #{result.error}")])
        end

        # NOT `Array(turns)`: TurnResult is a Struct, so Array() would explode a single
        # one into its members and hand the policy checks three strings.
        conversation = turns.nil? || turns.empty? ? [result] : turns
        checks = tool_checks(golden, result) + must_not_checks(golden, result) +
                 policy_checks(golden, conversation)
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

      # The declared `policy`, checked deterministically over the conversation. No
      # policy -> no check (and nothing to explain in the report).
      def policy_checks(golden, turns)
        name = golden.policy
        return [] if name.nil?

        # Exhaustive on purpose: a policy added to POLICIES without a rule here would
        # otherwise fall into whichever branch was last and check the wrong thing.
        pass, detail = case name
                       when "ask_once" then ask_once(turns)
                       when "investigate_first" then investigate_first(turns.first)
                       when "act_fast" then act_fast(turns.first)
                       else raise ArgumentError, "policy #{name.inspect} has no rule"
                       end
        [Check.new(name: "policy:#{name}", pass: pass, detail: detail)]
      end

      # Every reply asks at most one question. Reported with the offending turn and
      # the reply itself — "2 questions" alone sends the reader digging.
      def ask_once(turns)
        offender = turns.each_with_index.find { |t, _| count_questions(t.output_text) > 1 }
        return [true, "at most one question per reply"] unless offender

        turn, i = offender
        [false, "turn #{i + 1} asked #{count_questions(turn.output_text)} questions: " \
                "#{turn.output_text.to_s.strip[0, 160].inspect}"]
      end

      def investigate_first(turn)
        return [false, "no turn to check"] if turn.nil?

        tools = turn.tool_names
        return [false, "called #{tools.join(', ')} before asking anything"] unless tools.empty?
        return [false, "answered without asking: #{turn.output_text.to_s.strip[0, 160].inspect}"] if
          count_questions(turn.output_text).zero?

        [true, "asked before acting"]
      end

      def act_fast(turn)
        return [false, "no turn to check"] if turn.nil?

        tools = turn.tool_names
        return [true, "acted: called #{tools.join(', ')}"] unless tools.empty?

        [false, "asked instead of acting: #{turn.output_text.to_s.strip[0, 160].inspect}"]
      end

      # Questions in ONE reply. Deliberately crude and deliberately documented: a run
      # of "?" counts once ("já pensou??" is one question), and URLs are dropped first
      # so a tracking link's query string is not read as the agent asking something.
      # It is a policy signal, not grammar — and it already caught a real violation
      # ("é pra você ou tá pensando em presentear alguém? E qual seu tamanho?").
      def count_questions(text)
        text.to_s.gsub(%r{https?://\S+}, " ").scan(/\?+/).size
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
end
