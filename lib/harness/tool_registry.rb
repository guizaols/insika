# frozen_string_literal: true

module Harness
  # Registry de tools. Herda o genérico; `optional`/`side_effect`
  # vivem no metadata (defaults false). `side_effect: true` marca tool
  # não-idempotente — o mecanismo de checkpoint consome via `side_effect?`.
  class ToolRegistry < Registry
    # Compat legada: `optional:`/`plugin:` continuam aceitos; `side_effect:` é
    # novo. Tudo é normalizado no metadata (defaults false).
    def register(name, callable = nil, optional: false, side_effect: false, plugin: nil, **extra, &block)
      super(name, callable, plugin: plugin,
                            optional: optional, side_effect: side_effect, **extra, &block)
    end

    # -> bool; consumido pelo ToolEnvelope. Tool desconhecida = false.
    def side_effect?(name)
      entry = entries.find { |e| e.name == name.to_s }
      entry ? !!entry.metadata[:side_effect] : false
    end
  end
end
