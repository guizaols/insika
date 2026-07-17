# frozen_string_literal: true

module Harness
  # Tool registry. Inherits from the generic one; `optional`/`side_effect`
  # live in the metadata (defaults false). `side_effect: true` marks a
  # non-idempotent tool — the checkpoint mechanism consumes it via `side_effect?`.
  class ToolRegistry < Registry
    # Legacy compat: `optional:`/`plugin:` are still accepted; `side_effect:` is
    # new. Everything is normalized into the metadata (defaults false).
    def register(name, callable = nil, optional: false, side_effect: false, plugin: nil, **extra, &block)
      super(name, callable, plugin: plugin,
                            optional: optional, side_effect: side_effect, **extra, &block)
    end

    # -> bool; consumed by ToolEnvelope. Unknown tool = false.
    def side_effect?(name)
      entry = entries.find { |e| e.name == name.to_s }
      entry ? !!entry.metadata[:side_effect] : false
    end
  end
end
