# frozen_string_literal: true

require "delegate"

module Harness
  module Capability
    # Decorator fino: troca só o `name` exposto ao modelo pelo nome
    # ESTÁVEL da capability (ex. "browse"), independente de qual impl concreta
    # (`impl_name`, ex. "puppeteer_browser") a resolução escolheu.
    # `execute`/`parameters`/`description`/`call` continuam delegando ao impl via
    # SimpleDelegator — nada reimplementado, mesmo espírito do `ToolEnvelope`.
    #
    # Ordem de embrulho no run_pipeline: impl -> ResolvedTool ->
    # ToolEnvelope. O Envelope, por fora, enxerga a call já renomeada (o modelo
    # chama `browse`); para side_effect?/approval ele precisa do `impl_name` REAL
    # (é o tool_registry quem sabe se "puppeteer_browser" é side-effect, não
    # "browse") — por isso `impl_name` fica exposto aqui. Quem consome isso é o
    # Executor (ToolEnvelope).
    class ResolvedTool < SimpleDelegator
      def initialize(impl, capability_name:, impl_name:)
        super(impl)
        @capability_name = capability_name.to_s
        @impl_name = impl_name.to_s
      end

      # Nome ESTÁVEL exposto ao modelo — sombreia o `name` do impl.
      def name = @capability_name

      # Nome concreto por trás da resolução — p/ side_effect?/approval no
      # ToolEnvelope, NUNCA exposto ao modelo.
      def impl_name = @impl_name
    end
  end
end
