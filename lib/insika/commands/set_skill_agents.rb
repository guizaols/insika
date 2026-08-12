# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: enables/disables a skill on N
    # agents at once, adjusting each one's `profile.skills` allowlist — and, with
    # `eager_ids`, which of them keep the body in the prompt on EVERY turn
    # (`profile.skills_eager`). Takes effect on the next dispatch (hot via
    # ProfileSource). -> { name, enabled_for, eager_for, skipped_all, skipped_eager_all }.
    #
    # Both are per-agent decisions about the same skill, which is why they are one
    # command: eagerness lives on the agent precisely BECAUSE the skill is shared, so
    # the screen that says "which agents can load this" is the screen that says "and
    # which of them always have it".
    #
    # Allowlist semantics (AgentProfile): nil = ALL, [] = none,
    # [names] = subset. Important and deliberate consequence:
    #  - enabling on an agent with skills=nil: no-op (already has all).
    #  - DISABLING on an agent with skills=nil: NOT done here — removing one from
    #    "all" would require enumerating the catalog and materializing an explicit
    #    allowlist (destructive/surprising). These agents are left intact and
    #    go into `skipped_all`. To restrict, use an explicit :set_agent_tools/allowlist
    #    first.
    #
    # `skills_eager` is NOT allowlist semantics (nil = NONE, see
    # SkillCatalog#eager_for), so the two fields are adjusted by different rules: nil
    # there is an empty set that can simply be added to, and only the BLANKET `true`
    # has the same "cannot remove one name from all" problem (-> skipped_eager_all).
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
        raise Insika::ValidationError, "eager_ids must be a list" unless p[:eager_ids].nil? || p[:eager_ids].is_a?(Array)

        wanted = Array(p[:agent_ids]).map(&:to_s)
        # eager_ids ABSENT means "this form does not manage eagerness" — leave every
        # profile's setting alone. An empty ARRAY means "none of them", which is a real
        # instruction and must be applied. `nil` and `[]` are not the same request.
        eager_wanted = p[:eager_ids].nil? ? nil : Array(p[:eager_ids]).map(&:to_s)
        result = { enabled_for: [], eager_for: [], skipped_all: [], skipped_eager_all: [] }

        @profile_source.all.each { |profile| apply(profile, name, wanted, eager_wanted, result) }

        @event_stream.emit(Insika::Event.new(
                             type: :skill_agents_set,
                             data: { name: name, agent_ids: wanted, eager_ids: eager_wanted,
                                     skipped_all: result[:skipped_all] }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name }.merge(result)
      end

      private

      def apply(profile, name, wanted, eager_wanted, result)
        want = wanted.include?(profile.id)
        new_skills = next_skills(profile.skills, name, want)
        new_eager = next_eager(profile, name, eager_wanted, result)

        if new_skills == :skip
          result[:skipped_all] << profile.id
          new_skills = profile.skills
        end
        result[:enabled_for] << profile.id if want
        result[:eager_for] << profile.id if eager_wanted&.include?(profile.id)
        return if new_skills == profile.skills && new_eager == profile.skills_eager

        @profile_source.put(Insika::AgentProfile.build(
                              **profile.to_h.merge(skills: new_skills, skills_eager: new_eager)
                            ))
      end

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

      # -> new skills_eager. nil eager_wanted = not managed by this call.
      def next_eager(profile, name, eager_wanted, result)
        current = profile.skills_eager
        return current if eager_wanted.nil?

        want = eager_wanted.include?(profile.id)
        # Blanket `true` already includes every skill; removing ONE name from it would
        # mean materializing the whole catalog as a list, the same destructive surprise
        # `skipped_all` exists for.
        if Coercion.truthy?(current)
          result[:skipped_eager_all] << profile.id unless want
          return current
        end

        list = current.nil? || current == false ? [] : Array(current).map(&:to_s)
        want ? (list | [name]) : (list - [name])
      end
    end
  end
end
