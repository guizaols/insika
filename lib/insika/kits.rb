# frozen_string_literal: true

module Insika
  # Kits: named bundles of skills, tools and tool groups that agents subscribe to
  # (AgentProfile#kits). Stored in Settings["kits"]; applied at READ time by
  # AgentDefaults::ProfileSource, so editing a kit reaches every subscriber on its
  # next turn and the agent's own record never holds a kit's items.
  #
  # A kit only ADDS to an explicit allowlist. An agent whose allowlist is "all"
  # (nil) already sees everything, so the kit leaves it alone.
  module Kits
    NAME = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
    LISTS = %w[skills tools tool_groups].freeze

    module_function

    # -> the normalized kit { "description", "skills", "tools", "tool_groups" }.
    def validate!(name, kit)
      raise Insika::ValidationError, "kit name must be a lowercase slug" unless name.to_s.match?(NAME)
      raise Insika::ValidationError, "kit must be an object" unless kit.is_a?(Hash)

      kit = kit.transform_keys(&:to_s)
      out = { "description" => kit["description"].to_s.strip }
      LISTS.each do |key|
        value = kit[key]
        raise Insika::ValidationError, "kit #{key} must be a list" unless value.nil? || value.is_a?(Array)

        out[key] = Array(value).map { |v| v.to_s.strip }.reject(&:empty?).uniq
      end
      out
    end

    # -> the profile with its kits' items unioned in (the same object when there is
    # nothing to add). Unknown kit names are ignored: a deleted kit just stops applying.
    def apply(profile, kits_by_name)
      chosen = Array(profile.kits).filter_map { |name| kits_by_name[name] }
      return profile if chosen.empty?

      pick = ->(key) { chosen.flat_map { |k| Array(k[key]) }.uniq }
      changes = {}
      unless profile.tools_allow.nil? && profile.tools_allow_groups.nil?
        tools = pick.("tools")
        groups = pick.("tool_groups")
        changes[:tools_allow] = Array(profile.tools_allow) | tools if tools.any?
        changes[:tools_allow_groups] = Array(profile.tools_allow_groups) | groups if groups.any?
      end
      skills = pick.("skills")
      changes[:skills] = Array(profile.skills) | skills if !profile.skills.nil? && skills.any?
      changes.empty? ? profile : profile.with(**changes)
    end
  end
end
