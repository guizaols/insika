# frozen_string_literal: true

module Insika
  module Server
    module A2A
      # A2A adapter error map: standard JSON-RPC 2.0 codes +
      # A2A extensions. The `App` NEVER leaks an exception — always an error object.
      module Errors
        PARSE_ERROR         = -32_700
        INVALID_REQUEST     = -32_600
        METHOD_NOT_FOUND    = -32_601
        INVALID_PARAMS      = -32_602
        INTERNAL_ERROR      = -32_603
        TASK_NOT_FOUND      = -32_001 # A2A TaskNotFoundError
        TASK_NOT_CANCELABLE = -32_002 # A2A TaskNotCancelableError

        # Core exception -> [code, message]. A task `NotFoundError` is handled
        # EXPLICITLY in the App (tasks/get returns TASK_NOT_FOUND directly), so
        # here `NotFoundError` falls into INVALID_PARAMS (missing agent/session in the
        # request). Anything else -> INTERNAL_ERROR (generic message, no stack).
        def self.from_exception(error)
          case error
          when Insika::ValidationError, Insika::NotFoundError
            [INVALID_PARAMS, error.message]
          else
            [INTERNAL_ERROR, "internal error"]
          end
        end
      end
    end
  end
end
