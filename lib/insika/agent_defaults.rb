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

    # Like #apply, but a default the agent cannot be built with (saved before it
    # was validated, or a rerank model the registry dropped since) leaves the
    # agent on its own values: one bad default must not stop every turn.
    def apply_safely(profile, defaults)
      apply(profile, defaults)
    rescue Insika::ValidationError => e
      warn "[insika] agent defaults not applied to #{profile.id}: #{e.message}"
      profile
    end

    # Raises ValidationError unless an agent can be built with these defaults.
    def validate!(defaults)
      fields = defaults.to_h { |field, value| [field.to_sym, value] }
      AgentProfile.build(id: "agent-defaults", model: nil, **fields)
      defaults
    end

    # The agent's own records behind a profile source: what authoring reads and
    # writes. A plain source is its own.
    def own(source) = source.is_a?(ProfileSource) ? source.source : source

    # A ProfileSource that hands out profiles with the platform defaults applied.
    # Read-only: writing a profile read here would save the defaults into the
    # agent, so put/delete refuse; writers use #source (AgentDefaults.own).
    # Other reads (all_raw) go to the wrapped source untouched.
    class ProfileSource
      include Insika::ProfileSource

      attr_reader :source

      def initialize(source, settings_store:)
        @source = source
        @settings_store = settings_store
      end

      def fetch(id)
        profile = @source.fetch(id)
        profile && fill(profile, normalized)
      end

      def all
        values = normalized
        @source.all.map { |profile| fill(profile, values) }
      end

      def ids = @source.ids

      def put(*) = raise(Insika::Error, "agent profiles are written through their own source (AgentDefaults.own)")
      def delete(*) = put

      def respond_to_missing?(name, include_private = false) = @source.respond_to?(name, include_private) || super

      def method_missing(name, ...)
        return super unless @source.respond_to?(name)

        @source.public_send(name, ...)
      end

      private

      # Every inheritable field is normalized on its own by AgentProfile.build,
      # so a profile takes the normalized values as they are (Data#with) and is
      # not rebuilt per read.
      def fill(profile, values)
        missing = values.select { |field, _| profile.public_send(field).nil? }
        missing.empty? ? profile : profile.with(**missing)
      end

      # The defaults as AgentProfile.build normalizes them, rebuilt only when the
      # stored defaults change. Frozen: every profile shares them. A field that
      # does not build is left out (warned once per change), so one bad default
      # cannot stop every turn.
      def normalized
        raw = @settings_store.get["agent_defaults"] || {}
        digest = raw.hash
        return @normalized if digest == @normalized_digest

        @normalized = build_values(raw.slice(*FIELDS).compact)
        @normalized_digest = digest
        @normalized
      end

      def build_values(raw)
        raw.filter_map do |field, value|
          built = AgentProfile.build(id: "agent-defaults", model: nil, field.to_sym => value)
          [field.to_sym, Ractor.make_shareable(built.public_send(field))]
        rescue Insika::ValidationError => e
          warn "[insika] agent defaults: #{field} not applied: #{e.message}"
          nil
        end.to_h
      end
    end
  end
end
