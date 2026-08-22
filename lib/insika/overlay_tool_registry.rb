# frozen_string_literal: true

module Insika
  # DYNAMIC tool registry: composes the CODE registry (base, built at boot,
  # immutable), the DATA-DEFINED tools from the ToolStore, and — optionally —
  # the LIVE MCP tools from Insika::McpToolRegistry. Drop-in
  # for ToolRegistry — the Executor/ToolCatalog/ToolEnvelope only use
  # entries/resolve/side_effect?.
  #
  # Rules:
  #   - COLLISION: the base (code) ALWAYS wins — a data-tool or an MCP tool
  #     cannot hijack the name of a code tool (security, R3); a data-tool
  #     also wins over an MCP tool of the same name (an operator-authored
  #     definition over a server's own naming). The authoring Command also
  #     refuses to create with a colliding name (code_tool?), but the defense stays here.
  #   - HOT: `reload` re-reads the store and swaps the dynamic index atomically — a
  #     new/edited data-tool takes effect on the next turn without a restart, mirroring
  #     SkillCatalog.reload. An in-flight turn has already captured the index. MCP
  #     entries need no such reload — they read McpStore#tools_cache fresh every call
  #     (no I/O, so there is nothing to memoize-then-invalidate).
  # PARITY: empty ToolStore + no mcp_registry ⇒ entries/resolve/side_effect? identical
  #     to the pure base. The base (config/wiring.rb) does not even use the overlay — zero regression.
  #
  # The data-tools and MCP tools enter as NORMAL Registry::Entry (optional:
  # false) — they obey the same per-agent allow/deny as code tools; exposure
  # is the operator's (the /tools matrix), not automatic just because they
  # are "data-defined" or MCP-discovered.
  class OverlayToolRegistry
    def initialize(base:, tool_store:, http:, egress: Insika::EgressGuard, egress_options: {}, event_stream: nil,
                   mcp_registry: nil)
      @base = base
      @tool_store = tool_store
      @http = http
      @egress = egress
      @egress_options = egress_options
      @event_stream = event_stream
      @mcp_registry = mcp_registry
    end

    # Base + dynamic + mcp, except any that collide with something higher in
    # the precedence (base > data-tools > mcp).
    def entries
      @base.entries + dynamic.reject { |e| code_tool?(e.name) } + mcp_entries
    end

    def names
      (@base.names + dynamic.map(&:name) + mcp_entries.map(&:name)).uniq
    end

    # -> instance (base wins, then data-tools) | raise NotFoundError.
    def resolve(name)
      key = name.to_s
      return @base.resolve(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key } || mcp_entries.find { |e| e.name == key }
      raise Insika::NotFoundError, "'#{name}' not registered in #{self.class}" unless entry

      entry.factory.call
    end

    # -> bool; consumed by ToolEnvelope (checkpoint/skip-on-resume). Base wins.
    def side_effect?(name)
      key = name.to_s
      return @base.side_effect?(key) if code_tool?(key)

      entry = dynamic.find { |e| e.name == key } || mcp_entries.find { |e| e.name == key }
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

    # No I/O (McpToolRegistry#entries only reads McpStore#tools_cache) ->
    # recomputed fresh every call, unlike `dynamic` (nothing to reload).
    # Drops anything already claimed by the base or a data-tool.
    def mcp_entries
      return [] unless @mcp_registry

      claimed = @base.names + dynamic.map(&:name)
      @mcp_registry.entries.reject { |e| claimed.include?(e.name) }
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
