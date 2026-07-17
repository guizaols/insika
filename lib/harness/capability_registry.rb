# frozen_string_literal: true

module Harness
  # Intent→implementation resolution. Pure INDIRECTION: does NOT inherit
  # from `Registry` (which holds executables) — it holds `Provider`s (resolution
  # metadata) and returns the `impl_name` that ANOTHER registry instantiates.
  # Immutable post-boot by construction (only boot/loader registers), like `Registry`.
  class CapabilityRegistry
    Provider = Data.define(:capability, :impl_name, :kind, :plugin, :priority, :available)
    #   kind:      :tool | :workflow
    #   priority:  Integer | nil (nil = lowest; inherits plugin precedence)
    #   available: callable -> bool (default -> { true }; never nil in a registered Provider)

    def initialize
      # capability(Symbol) -> [Provider], na ordem de registro (proxy de announce)
      @providers = Hash.new { |h, k| h[k] = [] }
    end

    # Unlike `Registry#register`, there is NO "first wins": registering the
    # same capability more than once is the normal case (providers competing) —
    # dedup/tie-breaking happens in `resolve`, not here.
    def register(capability, impl_name:, kind:, plugin: nil, priority: nil, available: nil)
      unless %i[tool workflow].include?(kind)
        raise ArgumentError, "invalid kind: #{kind.inspect} (use :tool or :workflow)"
      end

      if kind == :workflow
        warn "[capability_registry] '#{capability}' registered with kind: :workflow — " \
             "exposure to the agent deferred (L5)"
      end

      @providers[capability.to_sym] << Provider.new(
        capability: capability.to_sym, impl_name: impl_name.to_s, kind: kind,
        plugin: plugin&.to_s, priority: priority, available: available || -> { true }
      )
      self
    end

    def providers(capability) = @providers[capability.to_sym].dup

    def capabilities = @providers.keys

    # Loader rollback, symmetric to `Registry#deregister_plugin`. Removes
    # only the plugin's Providers; capabilities with no remaining provider drop
    # from `capabilities` (clears the key so the Hash.new-with-block won't recreate it empty).
    def deregister_plugin(plugin_id)
      @providers.each_value { |list| list.delete_if { |p| p.plugin == plugin_id.to_s } }
      @providers.delete_if { |_cap, list| list.empty? }
      nil
    end

    # -> chosen Provider | raise CapabilityUnavailable | raise CapabilityAmbiguous.
    # PURE and deterministic: same input → same choice or same error. No
    # IO beyond the Provider's own `available.call`. Emits `:capability_resolved`
    # when `event_stream:` is present (audit).
    def resolve(capability, profile:, context: {}, event_stream: nil)
      candidates = providers(capability)
      candidates = candidates.select { |p| p.available.call }
      candidates = apply_deny(candidates, profile)

      raise CapabilityUnavailable.new(capability: capability) if candidates.empty?

      chosen = pick_top(candidates, capability)
      event_stream&.emit(Harness::Event.new(
                           type: :capability_resolved,
                           data: {
                             capability: capability.to_sym,
                             chosen: chosen.impl_name,
                             candidates: candidates.map do |p|
                               { impl_name: p.impl_name, plugin: p.plugin, priority: p.priority }
                             end
                           }
                         ))
      chosen
    end

    private

    # Resolution applies ONLY `tools_deny` over `impl_name` (deny ALWAYS wins) — it does
    # NOT apply `tools_allow`: the grant to use the capability is
    # listing it in `profile.capabilities`, checked by the Executor BEFORE
    # calling `resolve`. Reusing `tools_allow` would filter out a provider for
    # an agent that lists only the capability (not the raw impl). Per-agent provider
    # pinning (`capability_providers`) is future work.
    def apply_deny(candidates, profile)
      deny = Array(profile.tools_deny).map(&:to_s)
      candidates.reject { |p| deny.include?(p.impl_name) }
    end

    # `priority` desc primary, `nil` as the LOWEST possible (below
    # any Integer, including negative — do not normalize to 0, which would collide
    # with an explicit `priority: 0`). Tie-break by plugin precedence (registration
    # order, announce proxy): different plugins always
    # break the tie; same plugin (nil included) tied = CapabilityAmbiguous.
    def pick_top(candidates, capability)
      indexed = providers(capability).each_with_index.to_h { |p, i| [p, i] }

      rank = ->(p) { p.priority.nil? ? [0, 0] : [1, p.priority] }
      top_rank = candidates.map(&rank).max
      top = candidates.select { |p| rank.call(p) == top_rank }

      return top.first if top.size == 1

      groups = top.group_by(&:plugin).values
      if groups.any? { |g| g.size > 1 }
        raise CapabilityAmbiguous.new(capability: capability, candidates: top)
      end

      groups.min_by { |g| indexed[g.first] }.first
    end
  end
end
