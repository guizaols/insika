# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (RFC-0013 phase C): takes a CANDIDATE for a completed
    # refinement run, validates it against the agent's write allowlist, and scores it
    # by actually running it — clone the agent, apply the edits to the clone, replay
    # the golden set, compare to the accepted baseline (§3.5).
    #
    # Synchronous like `run_refinement`, and for the same reason: it is operator-paced
    # work with a human waiting on the answer. It is NOT cheap — the replay is a real
    # conversation per golden case — so it is fired deliberately, never on a timer
    # (D8: the engine has no scheduler and this RFC does not add one).
    #
    # Payload:
    #   run_id     (required) a run in :completed — the evidence the candidate answers
    #   candidate  { proposer?, rationale?, edits: [ {file, op, anchor?, before, after,
    #              addresses?} ] } — or omit it and pass `propose: true` to have the
    #              configured model write one from the run's findings (§3.4).
    #   propose    truthy — write the candidate with the agent's proposer.
    #   tolerance  Float — overrides the configured judge-score tolerance for this gate
    #
    # -> the Run, now :awaiting_approval (gate passed) or :rejected (it did not).
    #
    # **`propose: true` is required rather than inferred from a missing candidate.**
    # Both a proposal and a gate cost real provider money, and a caller who simply
    # forgot the candidate should get an error, not a bill.
    #
    # Two refusals happen BEFORE anything is cloned, because both mean the operator
    # has not actually enabled this: an agent still in `mode: report` (§3.8 — writing
    # is opt-in and an absent config is report-only), and a candidate whose every edit
    # was dropped (stale, off-allowlist, over budget). Neither is worth a provider bill.
    class GateRefinement
      WRITE_MODES = %w[propose auto_apply].freeze

      # proposer_factory: ->(refinement_config) { Refinement::Proposer | nil }. Optional
      # — a deployment with none can still gate a candidate that arrives from the API,
      # which is exactly what phase C shipped before the proposer existed.
      def initialize(profiles:, refinement_store:, agent_file_store:, gate:, event_stream:,
                     proposer_factory: nil)
        @profiles = ProfileSource.coerce(profiles)
        @runs = refinement_store
        @agent_files = agent_file_store
        @gate = gate
        @event_stream = event_stream
        @proposer_factory = proposer_factory
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        run_id = AgentPayload.presence(p[:run_id])
        raise Insika::ValidationError, "run_id is required" if run_id.nil?

        run = @runs.find(run_id) || (raise Insika::NotFoundError, "refinement run not found: #{run_id}")
        profile = @profiles[run.agent_id] ||
                  (raise Insika::NotFoundError, "agent '#{run.agent_id}' not configured")
        config = refinement_config(profile)
        require_write_mode!(config, run.agent_id)

        raw = p[:candidate] || propose(run, config, p)
        candidate = build_candidate(run.agent_id, raw, config)
        @runs.gating(run.id, candidate: candidate)
        emit(:refinement_proposed, run, proposer: candidate.proposer,
                                        edits: candidate.edits.size, dropped: candidate.dropped.size)

        report = @gate.score(agent_id: run.agent_id, candidate: candidate,
                             run_id: run.id, tolerance: p[:tolerance])
        gated = @runs.gated(run.id, report: report)
        emit(:refinement_gated, gated, passed: report.passed, reason: report.reason,
                                       cases: report.cases, passed_cases: report.passed_cases,
                                       regressions: report.regressions.size)
        gated
      end

      private

      def refinement_config(profile)
        raw = profile.respond_to?(:refinement) ? profile.refinement : nil
        raw.is_a?(Hash) ? Coercion.deep_stringify(raw) : {}
      end

      # Editing an agent's instructions is opt-in, explicitly, per agent — the whole
      # point of §3.1 is that the reachable surface is small and declared. An absent
      # or `report` config is not "not configured yet", it is a NO.
      def require_write_mode!(config, agent_id)
        mode = Coercion.presence(config["mode"]) || "report"
        return if WRITE_MODES.include?(mode)

        raise Insika::ValidationError,
              "agent '#{agent_id}' is in refinement mode '#{mode}' — set `refinement.mode` to " \
              "propose (and list the writable files) before gating a candidate"
      end

      # The model writes the candidate (§3.4, PR 3b). It is shown the run's findings
      # and the CURRENT content of the allowlisted files only — the same allowlist the
      # builder then enforces, so a proposal cannot even name a file it may not touch.
      #
      # A run with no findings is refused here rather than sent to a model: asking one
      # to invent an improvement from no evidence is how a refinement loop starts
      # rewriting a working prompt.
      def propose(run, config, payload)
        unless Insika::EnvSchema.truthy?(payload[:propose])
          raise Insika::ValidationError,
                "candidate is required (or pass propose: true to have the configured model write one)"
        end

        proposer = @proposer_factory&.call(config)
        if proposer.nil?
          raise Insika::ValidationError,
                "no proposer is configured for '#{run.agent_id}' — set `refinement.proposer` " \
                "(or a platform utility_model) to a model that can write the candidate"
        end

        proposer.propose(agent_id: run.agent_id, findings: run.findings,
                         files: writable_files(run.agent_id, config), limits: config)
      end

      # The allowlist ∩ what the agent actually has. A configured file the agent never
      # got is not shown and not editable — the builder would drop the edit anyway
      # ("does not exist for this agent"), and paying a model to write one is waste.
      def writable_files(agent_id, config)
        allow = allowlist!(agent_id, config)
        current_files(agent_id).select { |name, _| allow.include?(name) }
      end

      # Checked before the proposer runs as well as before the gate: an empty
      # allowlist is `mode: propose` with nothing switched on, and it is the one
      # refusal that must land before a provider call, not after it.
      def allowlist!(agent_id, config)
        allow = Array(config["files"]).map(&:to_s)
        if allow.empty?
          raise Insika::ValidationError,
                "agent '#{agent_id}' has an empty refinement.files allowlist — nothing is writable"
        end

        allow
      end

      def build_candidate(agent_id, raw, config)
        raise Insika::ValidationError, "candidate is required" unless raw.is_a?(Hash)

        allowlist = allowlist!(agent_id, config)
        candidate = Refinement::CandidateBuilder.build(
          raw, allowlist: allowlist, contents: current_files(agent_id), limits: config
        )
        return candidate unless candidate.empty?

        # Every edit fell off. Say which and why, in the error: an operator who gets
        # "invalid candidate" back learns nothing, and the drop reasons are exactly
        # the debugging information (a stale `before` is the common one).
        raise Insika::ValidationError,
              "every edit was dropped — #{candidate.dropped.map { |d| "#{d.file}: #{d.reason}" }.join('; ')}"
      end

      def current_files(agent_id)
        @agent_files.list(agent_id).each_with_object({}) do |name, acc|
          acc[name] = @agent_files.read(agent_id, name).to_s
        end
      end

      # Counts and ids only, never file content: these events reach the operator
      # stream and the same rule the findings follow applies here (§5).
      def emit(type, run, **data)
        @event_stream.emit(Insika::Event.new(
                             type: type,
                             data: { agent: run.agent_id, run_id: run.id, status: run.status.to_s, **data },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
