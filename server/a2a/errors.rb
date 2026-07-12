# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Mapa de erros do adapter A2A (P3A-01, D4): códigos JSON-RPC 2.0 padrão +
      # extensões A2A. O `App` NUNCA vaza exceção — sempre um error object.
      module Errors
        PARSE_ERROR         = -32_700
        INVALID_REQUEST     = -32_600
        METHOD_NOT_FOUND    = -32_601
        INVALID_PARAMS      = -32_602
        INTERNAL_ERROR      = -32_603
        TASK_NOT_FOUND      = -32_001 # A2A TaskNotFoundError
        TASK_NOT_CANCELABLE = -32_002 # A2A TaskNotCancelableError

        # Exceção do núcleo -> [code, message]. `NotFoundError` de task é tratado
        # EXPLICITAMENTE no App (tasks/get devolve TASK_NOT_FOUND direto), então
        # aqui `NotFoundError` cai em INVALID_PARAMS (agente/sessão inexistente da
        # request). Qualquer outra -> INTERNAL_ERROR (mensagem genérica, sem stack).
        def self.from_exception(error)
          case error
          when Harness::ValidationError, Harness::NotFoundError
            [INVALID_PARAMS, error.message]
          else
            [INTERNAL_ERROR, "internal error"]
          end
        end
      end
    end
  end
end
