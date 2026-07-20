# frozen_string_literal: true

module Harness
  module Safety
    # Canonical safe replies per block category (RFC-0009 D5). A blocked turn NEVER
    # returns a raw error nor silence — it completes gracefully with one of these
    # (the `halt_response` path in the Executor).
    #
    # pt-BR by default (the pilot is Natura/Cacau Show). Fixed text, not
    # LLM-generated: on a block we deliberately do NOT round-trip the model (that is
    # the whole point of short-circuiting). Open question §7 (per-category i18n /
    # agent-authored refusals) is left for a later slice.
    module SafeResponses
      DEFAULTS = {
        injection: "Não consigo compartilhar minhas instruções internas ou " \
                   "configurações. Posso te ajudar com informações sobre produtos, " \
                   "pedidos ou trocas — é só me dizer o que você precisa.",
        sexual:    "Prefiro manter nossa conversa focada no atendimento da loja. " \
                   "Posso te ajudar com produtos, pedidos ou dúvidas sobre a compra?",
        abuse:     "Sinto muito pela experiência. Quero muito te ajudar de verdade — " \
                   "me conta o que aconteceu com seu pedido ou o que você precisa e " \
                   "eu resolvo, ou te encaminho para um atendente humano.",
        escalate:  "Vou te encaminhar para um atendente humano que poderá te ajudar " \
                   "melhor com isso. Um momento, por favor.",
        default:   "Não consigo ajudar com esse pedido, mas fico à disposição para " \
                   "falar sobre produtos, pedidos ou trocas da loja."
      }.freeze

      module_function

      # Safe reply for a category. Unknown/nil -> the neutral default (never blank).
      def for(category)
        DEFAULTS[category&.to_sym] || DEFAULTS[:default]
      end
    end
  end
end
