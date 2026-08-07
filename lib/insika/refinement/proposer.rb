# frozen_string_literal: true

require "json"

module Insika
  module Refinement
    # Writes a CANDIDATE from a run's findings (RFC-0013 §3.4, phase C / PR 3b) — the
    # one place in refinement where a model is asked for anything.
    #
    # It is deliberately the WEAKEST link and it is built that way: everything this
    # class produces is data that the CandidateBuilder bounds (allowlist, size,
    # growth, a `before` that must still match) and the Gate then scores by REPLAYING
    # the golden set. A hallucinated rationale, a misread finding, an invented anchor
    # — the worst outcome of each is a candidate that gets dropped or fails to improve
    # a score, and never reaches a customer. Nothing here is trusted; it is measured.
    #
    # Pure over an injected `ask` (prompt -> raw model text), like `Evals::Judge` and
    # `Safety::Factory`: unit-testable without a provider, and the real ask is one
    # lambda built by `ProposerFactory`.
    #
    # ## What it is shown
    #
    # The findings (already redacted at collection — a snippet went through the same
    # output filter a customer-facing turn does) and the CURRENT CONTENT of the
    # allowlisted files, verbatim and unmasked. That is not a leak: those files are
    # the agent's own instructions, which are sent to a model on every single turn.
    # Masking them here would buy nothing and would break anchoring — a `before`
    # copied from a masked view never matches the real file, so every edit near a
    # secret would drop as stale.
    #
    # Files OUTSIDE the allowlist are not shown at all. A model that can read them
    # proposes edits to them, which drop, which spends the operator's attention on
    # rejects.
    class Proposer
      # A model that answers with prose instead of JSON produces NOTHING, loudly.
      # Silently returning an empty candidate would read as "the traffic is fine".
      class Unusable < Insika::ValidationError; end

      MAX_FINDINGS = 10

      # ask:   ->(prompt) { "<raw model text>" }
      # model: what to record as the candidate's `proposer` — the ref an operator
      #        reads on the review card and in `:refinement_proposed`.
      def initialize(ask:, model: "unknown")
        @ask = ask
        @model = model.to_s
      end

      # -> a RAW candidate hash (string keys) for `CandidateBuilder.build`. It is not
      # a Candidate: this class does not get to decide what is in bounds.
      #
      # findings: the run's findings as stored (string keys).
      # files:    name => current content, allowlist only.
      def propose(agent_id:, findings:, files:, limits: {})
        raise Unusable, "there is nothing to propose from — the run found no findings" if Array(findings).empty?
        raise Unusable, "no writable file has any content to anchor an edit in" if files.empty?

        raw = @ask.call(build_prompt(agent_id, Array(findings).first(MAX_FINDINGS), files, limits)).to_s
        parsed = parse(raw)
        parsed["proposer"] = @model
        parsed
      end

      private

      # JSON or nothing. ````json` fences are the common wrapper and stripping them is
      # not leniency — the payload inside is still parsed strictly, so a model that
      # improvises a schema fails here instead of producing half a candidate.
      def parse(raw)
        body = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        first = body.index("{")
        last = body.rindex("}")
        raise Unusable, "the proposer answered with no JSON object" if first.nil? || last.nil? || last < first

        parsed = JSON.parse(body[first..last])
        raise Unusable, "the proposer's JSON is not an object" unless parsed.is_a?(Hash)
        raise Unusable, "the proposer's JSON carries no `edits`" unless parsed["edits"].is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Unusable, "the proposer's answer is not valid JSON: #{e.message}"
      end

      def build_prompt(agent_id, findings, files, limits)
        bounds = DEFAULT_LIMITS.merge(Coercion.deep_stringify(limits.is_a?(Hash) ? limits : {}))
        <<~PROMPT
          You are improving the written instructions of a production customer-service agent
          called "#{agent_id}". You are given (1) what actually broke in its recent real
          traffic and (2) the current text of the only files you may edit.

          Propose the SMALLEST set of anchored edits that would plausibly fix the findings.
          Your proposal will be scored by replaying the agent's test cases with your edits
          applied — plausible prose that changes no behaviour is worth nothing here.

          ## What broke

          #{render_findings(findings)}

          ## Files you may edit (current content, verbatim)

          #{render_files(files)}

          ## Rules

          - Answer with a single JSON object and NOTHING else. No prose, no fences.
          - At most #{bounds['max_edits']} edits. Each `after` at most #{bounds['max_bytes']} bytes.
          - `op` is "replace" or "append". Never rewrite a whole file.
          - For "replace": `before` MUST be copied character-for-character from the file
            above and must appear there EXACTLY ONCE. If you cannot find a unique anchor,
            use "append" instead. An edit whose `before` does not match is discarded.
          - For "append": `before` is ignored; the text is added at the end of the file.
          - `file` must be one of the file names listed above.
          - `addresses` lists the findings the edit is meant to fix, by their `kind` and
            subject (e.g. "tool_error:shipping_quote").
          - Do not propose an edit you cannot justify from a finding above. Fewer, better
            edits beat filling the quota.
          - You cannot remove a tool, change a guardrail or a model with these edits —
            those are configuration, not text. Do not write instructions that pretend to.
          - Some findings are INFRASTRUCTURE, not behaviour: a tool that failed on the
            network, on TLS, on a refused connection, on a timeout, on a blocked
            destination or on an HTTP status. The assistant does not choose URLs,
            schemes, hosts or credentials and cannot fix any of that by being told to.
            You may say what to DO when a tool fails; never say how to call it correctly.

          ## Answer with exactly this shape

          {"rationale": "one or two sentences on the cause you are addressing",
           "edits": [{"file": "TOOLS.md", "op": "replace", "anchor": "## shipping_quote",
                      "before": "<text copied from the file>",
                      "after": "<the replacement>",
                      "addresses": ["tool_error:shipping_quote"]}]}
        PROMPT
      end

      # Counts included: "this happened 24 times" is the difference between a defect
      # worth a prompt edit and a one-off the operator should ignore.
      def render_findings(findings)
        findings.map do |f|
          f = Coercion.deep_stringify(f.respond_to?(:to_h) ? f.to_h : f)
          line = "- #{f['kind']} (×#{f['count']}): #{f['title']}"
          line += "\n  #{f['detail']}" if Coercion.present?(f["detail"])
          line
        end.join("\n")
      end

      def render_files(files)
        files.map { |name, body| "### #{name}\n\n```\n#{body}\n```" }.join("\n\n")
      end
    end

    # Resolves WHICH model writes the candidate, and builds the ask.
    #
    #   refinement.proposer  on the agent  ("deepseek/deepseek-chat" | "deepseek-chat")
    #   -> the platform utility_model
    #   -> nil, and the caller refuses. There is no default model here on purpose:
    #      guessing one spends an operator's provider budget without being asked.
    module ProposerFactory
      module_function

      # config: the agent's `refinement` hash. -> Proposer | nil.
      def build(config, utility_model: nil, ask_factory: nil)
        ref = Coercion.presence(Coercion.deep_stringify(config || {})["proposer"]) ||
              Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = split_ref(ref)
        Proposer.new(ask: (ask_factory || method(:ruby_llm_ask)).call(model, provider), model: ref)
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model]. Same reading
      # `Safety::Factory` uses for the moderator — one syntax for "which model", not
      # one per feature.
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      # Temperature 0: a proposal an operator rejects should be re-proposable, and a
      # gate result should be attributable to the edit rather than to a sampling seed.
      # `ruby_llm` is required lazily so nothing loads a provider gem until a proposer
      # is actually configured.
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
