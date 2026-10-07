# frozen_string_literal: true

module Insika
  # Platform defaults for agent fields (Settings["agent_defaults"]): an agent
  # with no value of its own for an INHERITABLE field runs with the platform's.
  # The agent's own value always wins, whole (no merge of the two).
  #
  # Applied only where turns read profiles (the graph, through ProfileSource
  # below). Authoring (Studio, pack import) reads the agent's own record, so
  # saving an agent never copies a default into it and it keeps inheriting.
  #
  # FIELDS are the ones where "absent" already means "not configured". Fields
  # where absent means something else (tools_allow nil = every tool) or where
  # absent and off read the same (the memory/fencing booleans) are left out.
  module AgentDefaults
    FIELDS = %w[reliability knowledge memory_retrieval budget alerts guardrails
                grounding followup distill harvest].freeze

    module_function

    # -> the profile, rebuilt with the defaults it lacks (the same object when
    # there is nothing to fill).
    def apply(profile, defaults)
      fill = FIELDS.each_with_object({}) do |field, acc|
        value = defaults[field]
        acc[field.to_sym] = value if !value.nil? && profile.public_send(field).nil?
      end
      return profile if fill.empty?

      AgentProfile.build(**profile.to_h.merge(fill))
    end

    # A ProfileSource that hands out profiles with the platform defaults applied.
    # Anything else (put, delete, all_raw) goes to the wrapped source untouched.
    class ProfileSource
      include Insika::ProfileSource

      def initialize(source, settings_store:)
        @source = source
        @settings_store = settings_store
      end

      def fetch(id)
        profile = @source.fetch(id)
        profile && AgentDefaults.apply(profile, defaults)
      end

      def all
        d = defaults
        @source.all.map { |profile| AgentDefaults.apply(profile, d) }
      end

      def ids = @source.ids

      def respond_to_missing?(name, include_private = false) = @source.respond_to?(name, include_private) || super

      def method_missing(name, ...)
        return super unless @source.respond_to?(name)

        @source.public_send(name, ...)
      end

      private

      def defaults = @settings_store.get["agent_defaults"] || {}
    end
  end
end
