# frozen_string_literal: true

module Harness
  # Turn-scoped assembly of the agent's tool instances (pipeline stage 3 tail):
  # capability resolution, instantiation (Entry#factory | ready instance),
  # turn-context (D2) injection, the capability<->direct dedup join, and the
  # ToolEnvelope wrap (stage 7 seam: per-call timeout + side-effect recording).
  #
  # Extracted from the Executor (§11 B5) to keep the hot-path file smaller. It is
  # a pure collaborator — it holds only the injected registries/stores and no
  # per-turn state; everything turn-specific arrives via `state`/`turn_context`.
  # The Executor keeps thin delegators (resolve_capabilities/assemble_tool_instances/
  # wrap_tools) so the existing private-method contract stays intact.
  class ToolAssembly
    def initialize(tool_registry:, capability_registry:, event_stream:,
                   checkpoint_store:, tool_trace_store:)
      @tool_registry = tool_registry
      @capability_registry = capability_registry
      @event_stream = event_stream
      @checkpoint_store = checkpoint_store
      @tool_trace_store = tool_trace_store
    end

    # Resolution sub-step BETWEEN Context and Policy —
    # it does NOT feed candidate_tools (those stay ONLY tool_registry.entries,
    # a capability does not go through the ToolAllowlist). Resolves each
    # capability of the profile to the concrete Entry already registered in the
    # tool_registry and keeps the impl_name -> capability_name mapping for the
    # post-Policy join. Errors
    # (Unavailable/Ambiguous, or an unregistered impl) propagate as a
    # CapabilityError -> single capture in `execute` (stage :capability). Without
    # @capability_registry OR without profile.capabilities: {} (parity).
    def resolve_capabilities(profile, context)
      return {} if @capability_registry.nil?

      Array(profile.capabilities).each_with_object({}) do |cap_name, names|
        provider = @capability_registry.resolve(cap_name, profile: profile, context: context,
                                                           event_stream: @event_stream)
        next if provider.kind == :workflow # exposure to the agent loop is a follow-up

        entry = @tool_registry.entries.find { |e| e.name == provider.impl_name.to_s }
        if entry.nil?
          raise CapabilityError, "capability '#{cap_name}' resolveu para impl " \
                                 "'#{provider.impl_name}', not registered in tool_registry"
        end

        names[entry.name] ||= cap_name.to_s # the 1st capability to claim an impl wins
      end
    end

    # Joins the direct instances (Policy/ToolAllowlist) with the
    # capability-sourced ones (grant = profile.capabilities — they never went
    # through Policy). Avoids double-exposure: if the SAME impl_name was also
    # allowed directly, the DIRECT instance is discarded — the model sees only the
    # capability alias.
    def assemble_tool_instances(allowed, state)
      names = state.respond_to?(:capability_names) ? (state.capability_names || {}) : {}
      ctx = state.respond_to?(:turn_context) ? state.turn_context : nil
      return instantiate_tools(allowed, ctx) if names.empty?

      # Dedup by the ENTRY NAME (registry key = impl_name) BEFORE
      # instantiating — the INSTANCE's `.name` (RubyLLM) is not the registration
      # name.
      direct = Array(allowed).reject { |e| e.respond_to?(:name) && names.key?(e.name.to_s) }
      instantiate_tools(direct, ctx) + capability_tool_instances(names, ctx)
    end

    # Envelopes each allowed tool (per-call timeout + side-effect recording).
    # The system LoadSkill (configure_chat) is NOT enveloped — it is a system
    # tool with no side-effect and of trivial latency.
    def wrap_tools(tools, state, skip_side_effects = [])
      timeout = state.profile.limits[:tool_timeout] || 60
      tools.map do |tool|
        ToolEnvelope.new(tool, state: state, checkpoint_store: @checkpoint_store,
                               tool_registry: @tool_registry, timeout: timeout,
                               skip_side_effects: skip_side_effects,
                               trace_recorder: @tool_trace_store)
      end
    end

    private

    # Real Engine -> Entries (respond to factory); fakes -> ready instances.
    # `turn_context` (D2) is deposited into the instances that expose it
    # (data-tools); the rest ignore it (parity).
    def instantiate_tools(allowed, turn_context = nil)
      Array(allowed).map do |t|
        tool = t.respond_to?(:factory) ? t.factory.call : t
        inject_turn_context(tool, turn_context)
        tool
      end
    end

    # D2/G3 seam: deposits the turn context into the freshly created instance
    # (same idea as `remember`, which receives tenant/state) BEFORE the
    # ToolEnvelope. Duck-typed: only what exposes `turn_context=` (DataDefinedTool)
    # receives it. nil (a state with no turn_context, e.g. a test stub) -> no-op.
    def inject_turn_context(tool, turn_context)
      return if turn_context.nil?

      tool.turn_context = turn_context if tool.respond_to?(:turn_context=)
    end

    # impl_name -> Capability::ResolvedTool(capability_name:), STILL without
    # ToolEnvelope (the call site's wrap_tools wraps the whole set — same
    # order impl -> ResolvedTool -> ToolEnvelope). entry already validated in
    # resolve_capabilities.
    def capability_tool_instances(names, turn_context = nil)
      names.map do |impl_name, capability_name|
        entry = @tool_registry.entries.find { |e| e.name == impl_name }
        tool = entry.factory.call
        inject_turn_context(tool, turn_context)
        Capability::ResolvedTool.new(tool, capability_name: capability_name,
                                           impl_name: impl_name)
      end
    end
  end
end
