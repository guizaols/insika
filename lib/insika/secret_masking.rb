# frozen_string_literal: true

module Insika
  # Secret masking on the UI<->Store round-trip. OpenClaw
  # convention: a secret NEVER comes back to the screen in plaintext — it becomes
  # the sentinel `__OCULTO__`. On save, the sentinel coming back means "keep what
  # was already there"; a new string replaces it; `""` clears it. Shared by
  # llm_providers (api keys) and, in the future, MCP instances (credentials).
  module SecretMasking
    SENTINEL = "__OCULTO__"

    module_function

    # Value to DISPLAY: present -> sentinel (never the plaintext); absent -> nil.
    def mask(value)
      present?(value) ? SENTINEL : nil
    end

    # Value to PERSIST given what the form sent (`incoming`) and what already
    # existed (`existing`):
    #   - not sent (nil) ............ preserves `existing`
    #   - sentinel `__OCULTO__` ..... preserves `existing`
    #   - "" (empty) ................ clears (nil)
    #   - new string ................ replaces
    def reconcile(incoming, existing)
      return existing if incoming.nil? || incoming == SENTINEL

      s = incoming.to_s
      s.empty? ? nil : s
    end

    def present?(value) = Insika::Coercion.present?(value)
  end
end
