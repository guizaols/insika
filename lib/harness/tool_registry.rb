# frozen_string_literal: true

module Harness
  # Registry de tools. Herda o genérico; `optional`/`side_effect`
  # vivem no metadata (defaults false). `side_effect: true` marca tool
  # não-idempotente — o mecanismo de checkpoint consome via `side_effect?`.
  class ToolRegistry < Registry
    # Event stream nulo p/ o atalho deprecated (fora da pipeline de eventos).
    class NullEventStream
      def emit(_event) = nil
    end
    private_constant :NullEventStream

    def initialize
      super
      @resolve_warned = false
    end

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

    # Despacho por tipo: AgentProfile -> atalho DEPRECATED, delega ao
    # Policy::Engine com a ToolAllowlist e devolve INSTÂNCIAS (retorno
    # compatível com o legado). Caso contrário -> lookup por nome (genérico).
    def resolve(arg)
      return super unless arg.respond_to?(:tools_allow)

      unless @resolve_warned
        warn "[DEPRECATION] ToolRegistry#resolve(profile): use Policy::Engine#decide (doc 05 §8)"
        @resolve_warned = true
      end

      engine = Policy::Engine.new(
        policy_registry: { "tool_allowlist" => Policy::Builtin::ToolAllowlist.new },
        event_stream: NullEventStream.new
      )
      request = Policy::PolicyRequest.new(
        profile: arg.with(policies: ["tool_allowlist"]),
        command: nil, context: nil, candidate_tools: entries, candidate_skills: []
      )
      engine.decide(request).allowed_tools.map { |entry| entry.factory.call }
    end
  end
end
