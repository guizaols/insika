# frozen_string_literal: true

require "time"
require "securerandom"

module Insika
  module Commands
    # RFC-0035 C10 — the snapshot restored (D9). `RollbackHarvest(snapshot_ref:)`
    # restores the pre-promotion state deterministically: WriteSkill with the
    # snapshot's pre-promotion content (or DeleteSkill when the skill did not
    # exist before — the snapshot's `existed` flag), SetSkillAgents to the
    # snapshot's pre-promotion `enabled_for`, and the `rolled_back_at` stamp on
    # the SAME log (the log stays the single ledger: a skill promoted, rolled
    # back, re-promoted is three readable rows). The "rehearsed once
    # end-to-end" acceptance is this command's full promote -> rollback cycle.
    class RollbackHarvest
      def initialize(harvest_store:, skill_store:, skill_catalog:, profile_source:,
                     event_stream:, write_skill: nil, delete_skill: nil, set_skill_agents: nil)
        @harvest_store = harvest_store
        @profiles = ProfileSource.coerce(profile_source)
        @event_stream = event_stream
        @write_skill = write_skill ||
                       Insika::Commands::WriteSkill.new(skill_store: skill_store,
                                                        skill_catalog: skill_catalog,
                                                        event_stream: event_stream)
        @delete_skill = delete_skill ||
                        Insika::Commands::DeleteSkill.new(skill_store: skill_store,
                                                          skill_catalog: skill_catalog,
                                                          event_stream: event_stream)
        @set_skill_agents = set_skill_agents ||
                            Insika::Commands::SetSkillAgents.new(profile_source: @profiles,
                                                                 event_stream: event_stream)
      end

      # payload: { snapshot_ref:, operator?, reason? }
      # -> Promotion (the row with rolled_back_at stamped)
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        snapshot_ref = AgentPayload.presence(p[:snapshot_ref])
        raise Insika::ValidationError, "snapshot_ref is required" if snapshot_ref.nil?

        snap = @harvest_store.find_snapshot(snapshot_ref) ||
               (raise Insika::NotFoundError, "harvest snapshot not found: #{snapshot_ref}")
        # The log row whose snapshot_ref matches — but a promotion that never
        # recorded its row (a crash between the writes and the append) rolls
        # back by snapshot, and the rollback stamp catches up on whatever row
        # exists (D8's honest price, resolved by reference).
        promotion = promotion_for_snapshot(snap)
        operator = (AgentPayload.presence(p[:operator]) || command.meta[:operator] || "operator").to_s

        if snap.existed
          @write_skill.call(Insika::Command.build(:write_skill,
                                                  { name: snap.skill, content: snap.content,
                                                    agent: snap.agent }))
        else
          begin
            @delete_skill.call(Insika::Command.build(:delete_skill,
                                                     { name: snap.skill, agent: snap.agent }))
          rescue Insika::NotFoundError
            # the desired state (gone) already holds — a snapshot taken for a
            # skill that never landed rolls back cleanly
          end
        end
        @set_skill_agents.call(Insika::Command.build(:set_skill_agents,
                                                     { name: snap.skill,
                                                       agent_ids: snap.enabled_for }))

        rolled = promotion ? @harvest_store.append_rollback(promotion_id: promotion.id,
                                                    operator: operator, reason: p[:reason]) : nil
        @event_stream.emit(Insika::Event.new(
                             type: :skill_rolled_back,
                             data: { snapshot_ref: snapshot_ref, skill: snap.skill,
                                     agent: snap.agent, operator: operator }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        rolled || promotion
      end

      private

      def promotion_for_snapshot(snap)
        @harvest_store.promotions.find { |row| row.snapshot_ref == snap.id }
      end
    end
  end
end