# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: takes a CANDIDATE for a completed
    # refinement run, validates it against the agent's write allowlist, and scores it
    # by actually running it — clone the agent, apply the edits to the clone, replay
    # the golden set, compare to the accepted baseline.
    #
    # Synchronous like `run_refinement`, and for the same reason: it is operator-paced
    # work with a human waiting on the answer. It is NOT cheap — the replay is a real
    # conversation per golden case — so it is fired deliberately, never on a timer
    # (a recurring timer may schedule OTHER turns; this gate stays human-paced).
    #
    # Payload:
    #   run_id     (required) a run in :completed — the evidence the candidate answers
    #   candidate  { proposer?, rationale?, edits: [ {file, op, anchor?, before, after,
    #              addresses?} ] } — or omit it and pass `propose: true` to have the
    #              configured model(s) write one from the run's findings.
    #   propose    truthy — write the candidate with the agent's proposer PANEL.
    #   tolerance  Float — overrides the configured judge-score tolerance for this gate
    #
    # -> the Run, now :awaiting_approval (gate passed), :applied (`mode: auto_apply`
    # and the candidate cleared the extra bar) or :rejected (the gate said no).
    #
    # **`propose: true` is required rather than inferred from a missing candidate.**
    # Both a proposal and a gate cost real provider money, and a caller who simply
    # forgot the candidate should get an error, not a bill.
    #
    # Two refusals happen BEFORE anything is cloned, because both mean the operator
    # has not actually enabled this: an agent still in `mode: report` (writing
    # is opt-in and an absent config is report-only), and a candidate whose every edit
    # was dropped (stale, off-allowlist, over budget). Neither is worth a provider bill.
    #
    # makes the proposal a PANEL and the run's spend a BUDGET. The
    # command's shape does not change: N models write N candidates, the gate scores
    # each, and the best survivor is the one proposal a human is shown. A deployment
    # with one proposer and no budget behaves exactly as did.
    class GateRefinement
      WRITE_MODES = %w[propose auto_apply].freeze

      # An unattended write is held to a SMALLER bar than an approved one: one edit,
      # by default. `auto_apply` exists so a well-understood, well-golden'd agent can
      # fix a typo'd instruction overnight — not so it can rewrite three files while
      # nobody is looking. The operator raises it deliberately.
      DEFAULT_AUTO_APPLY_MAX_EDITS = 1

      # proposer_factory: ->(refinement_config) { [Refinement::Proposer] | Proposer | nil }.
      # Optional — a deployment with none can still gate a candidate that arrives from
      # the API, which is exactly what shipped before the proposer existed.
      # resolver: the :resolve_refinement handler, used ONLY for `mode: auto_apply`.
      # Reusing it rather than writing files here is what keeps auto-apply honest: it
      # goes through the same staleness re-check, the same versioned write and the
      # same `:refinement_applied` event a human approval does.
      def initialize(profiles:, refinement_store:, agent_file_store:, gate:, event_stream:,
                     proposer_factory: nil, resolver: nil)
        @profiles = ProfileSource.coerce(profiles)
        @runs = refinement_store
        @agent_files = agent_file_store
        @gate = gate
        @event_stream = event_stream
        @proposer_factory = proposer_factory
        @resolver = resolver
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
        require_completed!(run)

        result = run_panel(run, config, p)
        report = (result.winner || Refinement::Panel.best_refusal(result.entries)).report

        gated = @runs.gated(run.id, report: report, panel: result.entries,
                                    cost: result.budget)
        emit(:refinement_gated, gated, passed: report.passed, reason: report.reason,
                                       cases: report.cases, passed_cases: report.passed_cases,
                                       regressions: report.regressions.size,
                                       candidates: result.entries.size,
                                       tokens: result.budget.to_h["spent"])
        auto_apply(gated, config, report) || gated
      end

      private

      # Propose (a panel, or the caller's own candidate), build, gate, rank. The
      # `gating` status and the `:refinement_proposed` event land BEFORE any scoring,
      # because the scoring is minutes of real replay and a run that says nothing
      # until it finishes looks hung.
      def run_panel(run, config, payload)
        panel = Refinement::Panel.new(
          gate: @gate, proposers: proposers_for(run, config, payload),
          budget: Refinement::Budget.new(tokens: budget_tokens(config))
        )

        panel.run(agent_id: run.agent_id, run_id: run.id, findings: run.findings,
                  files: writable_files(run.agent_id, config),
                  allowlist: allowlist!(run.agent_id, config),
                  contents: current_files(run.agent_id), limits: config,
                  raw: payload[:candidate], tolerance: payload[:tolerance]) do |entries|
          @runs.gating(run.id, candidates: entries)
          emit(:refinement_proposed, run, candidates: entries.size,
                                          proposers: entries.flat_map(&:proposers).uniq,
                                          edits: entries.sum { |e| e.candidate.edits.size })
        end
      end

      def budget_tokens(config)
        budget = config["budget"]
        budget.is_a?(Hash) ? budget["tokens"] : nil
      end

      def refinement_config(profile)
        raw = profile.respond_to?(:refinement) ? profile.refinement : nil
        raw.is_a?(Hash) ? Coercion.deep_stringify(raw) : {}
      end

      # Editing an agent's instructions is opt-in, explicitly, per agent — the whole
      # point of is that the reachable surface is small and declared. An absent
      # or `report` config is not "not configured yet", it is a NO.
      def require_write_mode!(config, agent_id)
        mode = Coercion.presence(config["mode"]) || "report"
        return if WRITE_MODES.include?(mode)

        raise Insika::ValidationError,
              "agent '#{agent_id}' is in refinement mode '#{mode}' — set `refinement.mode` to " \
              "propose (and list the writable files) before gating a candidate"
      end

      # `RefinementStore#gating` refuses a run that is not :completed — but it is
      # called AFTER the proposal, so the refusal used to arrive with the provider
      # bill already paid. Found live: a run_id pointing at an :awaiting_approval run
      # burned a minute and two model calls to learn the run could not be gated.
      # Same rule as mode and allowlist: everything the engine can refuse for free
      # is refused before a model is asked anything.
      def require_completed!(run)
        return if run.status == :completed

        raise ArgumentError, "run #{run.id} is #{run.status}, expected completed"
      end

      # The model(s) write the candidates. Each is shown the run's findings
      # and the CURRENT content of the allowlisted files only — the same allowlist the
      # builder then enforces, so a proposal cannot even name a file it may not touch.
      #
      # A caller who supplied their own candidate needs no proposer at all; that path
      # is what an API client and the phase-C Studio button use.
      def proposers_for(run, config, payload)
        return [] if payload[:candidate]

        unless Insika::EnvSchema.truthy?(payload[:propose])
          raise Insika::ValidationError,
                "candidate is required (or pass propose: true to have the configured model write one)"
        end

        panel = Array(@proposer_factory&.call(config))
        if panel.empty?
          raise Insika::ValidationError,
                "no proposer is configured for '#{run.agent_id}' — set `refinement.proposers` " \
                "(or `refinement.proposer`, or a platform utility_model) to a model that can " \
                "write the candidate"
        end

        panel
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

      # `mode: auto_apply` — the ONE path where a prompt changes with no
      # human in the loop. Off by default and deliberately narrow: it needs the mode,
      # a gate PASS with zero regressions, and a diff under `auto_apply_max_edits`.
      # Everything else parks at :awaiting_approval, which is the product.
      #
      # A candidate that passed but is too large is NOT rejected — it waits for a
      # person. "Too big to apply unattended" and "wrong" are different verdicts, and
      # collapsing them would throw away a proposal the gate already paid to score.
      #
      # Without a wired resolver this returns nil and the run stays awaiting approval:
      # a deployment that cannot apply must not record that it did.
      # -> the applied Run, or nil when nothing was applied.
      def auto_apply(run, config, report)
        return nil unless Coercion.presence(config["mode"]) == "auto_apply"
        return nil unless run.awaiting_approval? && report.passed && report.regressions.empty?
        return nil if @resolver.nil?

        max = (config["auto_apply_max_edits"] || DEFAULT_AUTO_APPLY_MAX_EDITS).to_i
        edits = run.edits.size
        if edits > max
          emit(:refinement_auto_apply_skipped, run, edits: edits, max_edits: max)
          return nil
        end

        @resolver.call(Insika::Command.build(:resolve_refinement,
                                             { run_id: run.id, decision: "approved",
                                               operator: "auto_apply",
                                               note: "auto_apply: gate passed #{report.passed_cases}/" \
                                                     "#{report.cases} with no regression" }))
      end

      def current_files(agent_id)
        @agent_files.list(agent_id).each_with_object({}) do |name, acc|
          acc[name] = @agent_files.read(agent_id, name).to_s
        end
      end

      # Counts and ids only, never file content: these events reach the operator
      # stream and the same rule the findings follow applies here.
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
