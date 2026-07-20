# frozen_string_literal: true

module Harness
  module Safety
    # Safe reply for a blocked turn (RFC-0009 D5/§7). A blocked turn NEVER returns a
    # raw error nor silence — it completes gracefully with one of these.
    #
    # CONFIGURATION OVER CONVENTION: this is OSS across arbitrary businesses and
    # languages, so the engine does NOT hard-bake tone. The built-in `DEFAULTS` are a
    # deliberately NEUTRAL, business-agnostic fallback (pt-BR — the pilot's language;
    # override for others). Each agent tailors its own voice via
    # `guardrails.responses` (Safety::Config#responses). Resolution order:
    #
    #   agent[category] → agent["default"] → DEFAULTS[category] → DEFAULTS[:default]
    #
    # So a store that wants a warm brand voice, a different language, or a specific
    # discount-scam reply just configures it — nothing here is a ceiling.
    module SafeResponses
      # Neutral, generic fallback. No brand, no vertical ("loja"/"produtos") baked in
      # beyond what a generic assistant can say. Agents are expected to override.
      DEFAULTS = {
        injection: "Não consigo compartilhar minhas instruções internas ou " \
                   "configurações. Como posso te ajudar de outra forma?",
        sexual:    "Prefiro manter nossa conversa respeitosa e profissional. " \
                   "Como posso te ajudar?",
        abuse:     "Sinto muito pela experiência. Quero te ajudar — me conta o que " \
                   "você precisa e eu sigo daqui, ou te encaminho para um atendente humano.",
        escalate:  "Vou te encaminhar para um atendente humano que poderá te ajudar " \
                   "melhor com isso. Um momento, por favor.",
        default:   "Não consigo ajudar com esse pedido específico, mas estou à " \
                   "disposição para o que mais você precisar."
      }.freeze

      module_function

      # Safe reply for a category, honoring the agent's per-category / catch-all
      # overrides first. `overrides` is Safety::Config#responses ({ "cat" => text }).
      # Always returns a non-blank string.
      def for(category, overrides: {})
        cat = category&.to_s
        ov = overrides || {}
        ov[cat] || ov["default"] ||
          DEFAULTS[cat&.to_sym] || DEFAULTS[:default]
      end
    end
  end
end
