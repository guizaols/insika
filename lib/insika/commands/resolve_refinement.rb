# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: the human's answer to a gated proposal.
    #
    #   approve -> each edit is written through `AgentFileStore#write`, which pushes
    #              the previous content into `history`. Rollback is therefore already
    #              built: `restore_agent_file` with index 0, the same button the file
    #              editor has had since the Studio existed.
    #   reject  -> recorded on the run with the operator's note. The finding must
    #              re-surface with new evidence before anything is proposed again;
    #              nothing retries on its own.
    #
    # Payload `{ run_id:, decision: "approved"|"rejected", operator?, note? }`.
    # -> the resolved Run.
    #
    # **The candidate is re-validated against the CURRENT files before anything is
    # written.** The gate scored a snapshot; an operator approves minutes or days
    # later, and in between a human may have edited the same file in the Studio.
    # Applying an edit whose `before` no longer matches would silently overwrite that
    # person's work — the exact failure the anchored format exists to prevent, thrown
    # away at the last step. A stale approval is refused and the operator re-gates.
    class ResolveRefinement
      def initialize(profiles:, refinement_store:, agent_file_store:, event_stream:)
        @profiles = ProfileSource.coerce(profiles)
        @runs = refinement_store
        @agent_files = agent_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        run_id = AgentPayload.presence(p[:run_id])
        decision = AgentPayload.presence(p[:decision]).to_s
        raise Insika::ValidationError, "run_id is required" if run_id.nil?

        run = @runs.find(run_id) || (raise Insika::NotFoundError, "refinement run not found: #{run_id}")
        operator = p[:operator] || command.meta[:operator]

        case decision
        when "rejected"
          resolved = @runs.resolve(run.id, decision: :rejected, operator: operator, note: p[:note])
          emit(:refinement_rejected, resolved, files: [])
          resolved
        when "approved"
          apply(run, operator: operator, note: p[:note])
        else
          raise Insika::ValidationError, "invalid decision: #{decision} (approved|rejected)"
        end
      end

      private

      def apply(run, operator:, note:)
        unless run.awaiting_approval?
          raise ArgumentError, "run #{run.id} is #{run.status}, expected awaiting_approval"
        end

        config = refinement_config(run.agent_id)
        contents = current_files(run.agent_id)
        candidate = rebuild(run, config, contents)

        written = candidate.apply(contents)
        written.each { |file, body| @agent_files.write(run.agent_id, file, body) }

        # Recorded AFTER the writes land: a crash in between leaves the run awaiting
        # approval and the operator approves again. Re-approving re-validates against
        # the (now edited) files and refuses as stale, which is a confusing message but
        # a safe outcome — recording `applied` before writing would be a lie the
        # history could not correct.
        resolved = @runs.resolve(run.id, decision: :applied, operator: operator, note: note)
        emit(:refinement_applied, resolved, files: written.keys, edits: candidate.edits.size)
        resolved
      end

      # Re-runs the SAME validator the gate used, against the files as they are now.
      # Anything that drifted comes back as a drop, and any drop at all refuses the
      # apply: a partial application would land some edits and silently skip others,
      # leaving a prompt in a state no one reviewed and the gate never scored.
      def rebuild(run, config, contents)
        allowlist = Array(config["files"]).map(&:to_s)
        raw = { "proposer" => (run.candidate || {})["proposer"],
                "rationale" => (run.candidate || {})["rationale"],
                "edits" => run.edits }
        candidate = Refinement::CandidateBuilder.build(raw, allowlist: allowlist,
                                                            contents: contents, limits: config)

        if candidate.dropped.any? || candidate.edits.size != run.edits.size
          reasons = candidate.dropped.map { |d| "#{d.file}: #{d.reason}" }
          raise Insika::ValidationError,
                "the files changed since this proposal was gated, so it no longer applies " \
                "(#{reasons.join('; ')}). Re-run the gate against the current files."
        end

        candidate
      end

      def refinement_config(agent_id)
        profile = @profiles[agent_id] ||
                  (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")
        raw = profile.respond_to?(:refinement) ? profile.refinement : nil
        raw.is_a?(Hash) ? Coercion.deep_stringify(raw) : {}
      end

      def current_files(agent_id)
        @agent_files.list(agent_id).each_with_object({}) do |name, acc|
          acc[name] = @agent_files.read(agent_id, name).to_s
        end
      end

      # File NAMES are fine on the stream (the operator needs to know what changed);
      # their content is not, and never appears here.
      def emit(type, run, **data)
        @event_stream.emit(Insika::Event.new(
                             type: type,
                             data: { agent: run.agent_id, run_id: run.id, status: run.status.to_s,
                                     by: run.decision && run.decision["by"], **data },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
