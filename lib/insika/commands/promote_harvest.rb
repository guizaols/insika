# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # — the human's answer, the ONLY path that lands a
    # skill. Snapshot FIRST (the pre-promotion state), then the two existing
    # write commands, then the append-only log row (D8). A promotion row's
    # `rolled_back_at` makes the log the single ledger; re-promotion after a
    # rollback is a NEW row with a NEW snapshot. The candidate flips to
    # `promoted` ONLY after the writes land (record-after).
    class PromoteHarvest
      def initialize(harvest_store:, skill_store:, skill_catalog:, profile_source:,
                     criterion:, conversion_gate:, event_stream:,
                     write_skill: nil, set_skill_agents: nil)
        @harvest_store = harvest_store
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @profiles = ProfileSource.coerce(profile_source)
        @criterion = criterion
        @conversion_gate = conversion_gate
        @event_stream = event_stream
        @write_skill = write_skill ||
                       Insika::Commands::WriteSkill.new(skill_store: skill_store,
                                                        skill_catalog: skill_catalog,
                                                        event_stream: event_stream)
        @set_skill_agents = set_skill_agents ||
                            Insika::Commands::SetSkillAgents.new(profile_source: @profiles,
                                                                 event_stream: event_stream)
      end

      # payload: { candidate_id:, operator?, note? }
      # operator from payload || command.meta[:operator] || "operator"
      # -> Candidate (promoted | gated — the conversion re-check moved, D8-bis)
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        candidate_id = AgentPayload.presence(p[:candidate_id])
        raise Insika::ValidationError, "candidate_id is required" if candidate_id.nil?

        candidate = @harvest_store.find_candidate(candidate_id) ||
                    (raise Insika::NotFoundError, "harvest candidate not found: #{candidate_id}")
        operator = (AgentPayload.presence(p[:operator]) || command.meta[:operator] || "operator").to_s

        # D8-bis — the conversion ruler is RE-READ at the moment the skill
        # lands (cheap: a fold read). A dip below the frozen baseline since
        # gating PARKS the candidate at gated with the current numbers — the
        # operator re-decides alertly. The eval gate is NOT re-run (expensive,
        # and the skill body is not anchored to instruction files — nothing
        # drifted to re-validate). A base graph without a conversion gate
        # refuses with the named reason — never passes, never crashes.
        current = if @conversion_gate
                    @conversion_gate.call(tenant: command.meta[:tenant], agent: candidate.agent)
                  else
                    Insika::Harvest::ConversionGate::Result.new(
                      passed: false, reason: :no_conversion_gate_wired, metric: nil, window: nil,
                      current: nil, baseline: nil, threshold: nil, snapshot_ref: nil
                    )
                  end
        return @harvest_store.recheck_conversion(candidate.id, conversion_gate: current.to_h) unless current.passed

        # The criterion must STILL be the frozen one (D8-bis): a criterion that
        # changed between boot and promotion is a criterion nobody froze.
        unless @criterion && @criterion.sha == candidate.criterion_sha
          raise Insika::ValidationError,
                "the harvest criterion changed since boot (#{candidate.criterion_sha.inspect} -> " \
                "#{@criterion&.sha.inspect}) — re-gate the candidate against the new frozen file"
        end

        # Snapshot first, then the writes, then the log row, then the flip.
        existed = @skill_store.get(candidate.name, agent: candidate.agent)
        # D8 + the review fix: the snapshot records EVERY agent the skill was
        # enabled for BEFORE this promotion (SetSkillAgents' vocabulary). A
        # homonymous skill allowed by B must stay allowed when A promotes —
        # and the rollback restores exactly this set, B included.
        enabled_for = agents_with_skill(candidate.name)
        snapshot = @harvest_store.create_snapshot(
          agent: candidate.agent, skill: candidate.name, content: existed,
          existed: !existed.nil?,
          enabled_for: enabled_for
        )

        @write_skill.call(Insika::Command.build(:write_skill,
                                                { name: candidate.name, content: candidate.body,
                                                  agent: candidate.agent }))
        # ENABLE for the candidate's agent WITHOUT disabling anyone else who
        # already had it: the wanted set is the pre-promotion holders plus the
        # candidate.
        @set_skill_agents.call(Insika::Command.build(:set_skill_agents,
                                                     { name: candidate.name,
                                                       agent_ids: enabled_for | [candidate.agent] }))

        promotion = @harvest_store.append_promotion(
          id: SecureRandom.uuid, agent: candidate.agent, skill: candidate.name,
          origin: candidate.origin, eval_ref: "cand:#{candidate.id}",
          conversion_ref: candidate.conversion_gate && candidate.conversion_gate["snapshot_ref"],
          approver: operator, snapshot_ref: snapshot.id,
          criterion_sha: candidate.criterion_sha
        )
        @harvest_store.mark_promoted(candidate.id, promotion_ref: promotion.id)

        emit(:skill_promoted, agent: candidate.agent, skill: candidate.name,
                              candidate_id: candidate.id, snapshot_ref: snapshot.id,
                              promotion_ref: promotion.id, approver: operator)
        @harvest_store.find_candidate(candidate.id)
      end

      private

      def profile_of(agent_id)
        @profiles.fetch(agent_id) ||
          (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")
      end

      # Every agent whose allowlist currently names the skill — the pre-
      # promotion holder set (an agent with skills=nil has ALL, so it holds
      # every name and is not "removable"; SetSkillAgents skips it).
      def agents_with_skill(name)
        @profiles.all.select { |p| Array(p.skills).include?(name) }.map(&:id)
      end

      def emit(type, **data)
        # ids and refs only — the skill body never enters the stream (D7).
        @event_stream.emit(Insika::Event.new(
                             type: type, data: data, meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end