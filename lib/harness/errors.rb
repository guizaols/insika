# frozen_string_literal: true

module Harness
  # Taxonomia única de erros.
  # Regra geral: erro vira evento, task tem estado terminal explícito,
  # checkpoint nunca é corrompido.
  class Error < StandardError; end

  class ValidationError < Error; end  # Command malformado -> HTTP 422, nenhuma Task criada
  class NotFoundError   < Error; end  # session/task/agente inexistente -> HTTP 404

  # Policy Engine negou -> evento :policy_denied, task :failed
  class PolicyDenied < Error
    attr_reader :policy, :reason

    def initialize(message = nil, policy: nil, reason: nil)
      @policy = policy
      @reason = reason
      super(message || "policy #{policy} negou: #{reason}")
    end
  end

  # provider required falhou -> task :failed
  class ContextError < Error
    attr_reader :provider

    def initialize(message = nil, provider: nil)
      @provider = provider
      super(message || "provider #{provider} falhou")
    end
  end

  class ProviderError  < Error; end  # RubyLLM esgotou retries -> task :failed
  class StoreError     < Error; end  # backend de persistência falhou -> task :failed
  class CancelledError < Error; end  # cancelamento cooperativo -> task :cancelled

  # Estouro de timeout de estágio. Dentro do namespace Harness a constante
  # sombreia ::Timeout::Error da stdlib — referencie sem :: aqui dentro
  # (o contrato proíbe Timeout.timeout de stdlib de qualquer forma).
  class TimeoutError < Error
    attr_reader :stage

    def initialize(message = nil, stage: nil)
      @stage = stage
      super(message || "timeout no estágio #{stage}")
    end
  end

  # Resolução de capability falhou -> task :failed no
  # estágio :capability. Base da subárvore; NÃO ganha evento próprio —
  # propaga pelos eventos :error/:task_failed já existentes, mesma
  # disciplina da taxonomia. Nunca levantada direto (só as subclasses).
  class CapabilityError < Error; end

  # 0 candidatos sobraram após disponibilidade + deny.
  class CapabilityUnavailable < CapabilityError
    attr_reader :capability

    def initialize(message = nil, capability: nil)
      @capability = capability
      super(message || "capability #{capability} sem provider disponível")
    end
  end

  # >=2 candidatos empatados no topo (mesma priority E mesmo plugin) -> erro de
  # configuração, NUNCA escolha silenciosa. `candidates` carrega o
  # suficiente para o operador desempatar no manifesto.
  class CapabilityAmbiguous < CapabilityError
    attr_reader :capability, :candidates

    def initialize(message = nil, capability: nil, candidates: [])
      @capability = capability
      @candidates = candidates
      super(message || "capability #{capability} ambígua entre #{candidates.inspect}")
    end
  end
end
