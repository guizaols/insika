# frozen_string_literal: true

module Insika
  # DYNAMIC tool registry: composes the CODE registry (base, built at boot,
  # immutable) with the DATA-DEFINED tools from the ToolStore. Drop-in for ToolRegistry —
  # the Executor/ToolCatalog/ToolEnvelope only use entries/resolve/side_effect?.,
  #
  # Rules:
  #   - COLLISION: the base (code) ALWAYS wins — a data-tool cannot hijack
  #     the name of a code tool (security, R3). The authoring Command also
  #     refuses to create with a colliding name (code_tool?), but the defense stays here.
  #   - HOT: `reload` re-reads the store and swaps the dynamic index atomically — a
  #     new/edited data-tool takes effect on the next turn without a restart, mirroring
  #     SkillCatalog.reload. An in-flight turn has already captured the index.
  # PARITY: empty ToolStore ⇒ entries/resolve/side_effect? identical to the
  #     pure base. The base (config/wiring.rb) does not even use the overlay — zero regression.
  #
  # The data-tools enter as NORMAL Registry::Entry (optional: false) — they obey
  # the same per-agent allow/deny as code tools; exposure is the operator's
  # (the /tools matrix), not automatic just because they are "data-defined".
  class OverlayToolRegistry
    def initialize(base:, tool_store:, http:, egress: Insika::EgressGuard, egress_options: {}, event_stream: nil)
      @base = base
      @tool_store = tool_store
      @http = http
      @egress = egress
      @egress_options = egress_options
      @event_stream = event_stream
    end

    # Base + dynamic, except dynamic ones that collide with the base (base wins).
    def entries
      @base.entries + dynamic.reject { |e| code_tool?(e.name) }
    end

    def names
      (@base.names + dynamic.map(&:name)).uniq
    end

    # -> instance (base wins) | raise NotFoundError.
    def resolve(name)
      key = name.to_s
      return @base.resolve(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key }
      raise Insika::NotFoundError, "'#{name}' not registered in #{self.class}" unless entry

      entry.factory.call
    end

    # -> bool; consumed by ToolEnvelope (checkpoint/skip-on-resume). Base wins.
    def side_effect?(name)
      key = name.to_s
      return @base.side_effect?(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key }
      entry ? !!entry.metadata[:side_effect] : false
    end

    # Atomic swap of the dynamic index (after writing/removing a data-tool).
    def reload
      @dynamic = build_dynamic
      self
    end

    # Is it a CODE tool (base)? Used by the authoring Command's validation.
    def code_tool?(name) = @base.names.include?(name.to_s)

    private

    def dynamic
      @dynamic ||= build_dynamic
    end

    def build_dynamic
      @tool_store.all_raw.filter_map { |raw| entry_for(raw) }
    end

    def entry_for(raw)
      definition = Insika::ToolDefinition.from_h(raw)
      Insika::Registry::Entry.new(
        name: definition.name, plugin: "data-tools",
        metadata: { optional: false, side_effect: definition.side_effect,
                    group: definition.group, tags: definition.tags },
        factory: -> { build_tool(definition) }
      )
    rescue Insika::ValidationError => e
      warn "[overlay-tools] invalid definition ignored: #{e.message}"
      nil
    end

    # Lazy require: DataDefinedTool inherits from RubyLLM::Tool (pulls in the gem) -> kept
    # out of insika.rb load-time, loaded on the 1st instance (turn time).
    def build_tool(definition)
      require_relative "tools/data_defined_tool"
      Insika::Tools::DataDefinedTool.new(
        definition: definition, http: @http, egress: @egress,
        egress_options: @egress_options, event_stream: @event_stream
      )
    end
  end
end
