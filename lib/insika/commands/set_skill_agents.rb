# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: enables/disables a skill on N
    # agents at once, adjusting each one's `profile.skills` allowlist.
    # Takes effect on the next dispatch (hot via ProfileSource). -> { name, enabled_for }.
    #
    # Allowlist semantics (AgentProfile): nil = ALL, [] = none,
    # [names] = subset. Important and deliberate consequence:
    #  - enabling on an agent with skills=nil: no-op (already has all).
    #  - DISABLING on an agent with skills=nil: NOT done here — removing one from
    #    "all" would require enumerating the catalog and materializing an explicit
    #    allowlist (destructive/surprising). These agents are left intact and
    #    go into `skipped_all`. To restrict, use an explicit :set_agent_tools/allowlist
    #    first.
    class SetSkillAgents
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Insika::ValidationError, "name is required" if name.nil?
        raise Insika::ValidationError, "agent_ids must be a list" unless p[:agent_ids].nil? || p[:agent_ids].is_a?(Array)

        wanted = Array(p[:agent_ids]).map(&:to_s)
        enabled_for = []
        skipped_all = []

        @profile_source.all.each do |profile|
          want = wanted.include?(profile.id)
          new_skills = next_skills(profile.skills, name, want)

          if new_skills == :skip
            skipped_all << profile.id
            next
          end
          next if new_skills == profile.skills # no change

          @profile_source.put(Insika::AgentProfile.build(**profile.to_h.merge(skills: new_skills)))
          enabled_for << profile.id if want
        end

        @event_stream.emit(Insika::Event.new(
                             type: :skill_agents_set,
                             data: { name: name, agent_ids: wanted, skipped_all: skipped_all },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, enabled_for: enabled_for, skipped_all: skipped_all }
      end

      private

      # -> new allowlist | :skip (agent with nil that requested disable).
      def next_skills(current, name, want)
        if want
          current.nil? ? nil : (Array(current).map(&:to_s) | [name])
        elsif current.nil?
          :skip
        else
          Array(current).map(&:to_s) - [name]
        end
      end
    end
  end
end
