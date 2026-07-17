# frozen_string_literal: true

module Harness
  # Policy registry. `resolve(name) -> Policy::Base`.
  # The builtins (ToolAllowlist/SkillAllowlist/WorkflowAllowlist) are registered
  # AT BOOT by the composition root (config/wiring.rb), not here.
  #
  # NB: the Policy::Engine consumes via `fetch(name)`; a Hash also
  # satisfies that duck-type. This registry is the production implementation — to
  # use it with the Engine, expose `fetch` delegating to `resolve`.
  class PolicyRegistry < Registry
    # -> Policy::Base (INSTANCE): the Engine calls #decide on the result. If the
    # policy was registered as a CLASS, instantiate it; if it already came as an
    # instance/factory returning an instance, pass it through.
    def resolve(name)
      resolved = super
      resolved.is_a?(Class) ? resolved.new : resolved
    end

    # Alias for the duck-type the Policy::Engine expects (fetch(name) -> Policy::Base).
    def fetch(name) = resolve(name)
  end
end
