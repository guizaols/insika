# frozen_string_literal: true

require "rack"
require "rack/utils"

module Insika
  module Server
    # Edge resolution for WS1 (multi-tenant): `Authorization: Bearer <token>` ->
    # a principal `{ role:, tenant_id: }`, resolved BEFORE the routes. Two modes,
    # one gate:
    #
    #   single_tenant (default) — no token store: the classic single operator
    #     credential (config[:gateway_token]) is the only thing that resolves.
    #   multi_tenant — tokens live in the TokenStore (per-tenant + operator).
    #     A configured gateway_token STILL resolves as operator (an existing
    #     deployment switching modes keeps its credential — additive, never
    #     a second-class path).
    #
    # Fail-closed BY CONSTRUCTION: no store and no configured token -> :disabled
    # (503, never open). A revoked or unknown token -> :unauthorized. Pure module,
    # testable without a Rack env.
    module TenantAuth
      module_function

      # gateway_token: config[:gateway_token] | nil. token_store: TokenStore |
      # nil. header: raw Authorization value.
      # -> :disabled | :unauthorized | { role: "operator"|"tenant", tenant_id: }
      def check(gateway_token, token_store, header)
        # Fail-closed FIRST (the construction rule): with no store AND no
        # configured token the gateway is DISABLED (503) however the request
        # looks — never "401: who are you facing a door that does not exist".
        # A token_store present means the gateway IS configured (multi_tenant),
        # with or without the legacy gateway token.
        return :disabled if token_store.nil? && (gateway_token.nil? || gateway_token.empty?)

        provided = header.to_s[/\ABearer (.+)\z/, 1]
        return :unauthorized if provided.nil?

        if token_store
          record = token_store.resolve(provided)
          unless record
            # store miss -> the legacy gateway token still resolves as operator
            # (an existing deployment switching modes keeps its credential).
            return :unauthorized if gateway_token.nil? || gateway_token.empty?
            return :unauthorized unless Rack::Utils.secure_compare(gateway_token, provided)

            return { role: "operator", tenant_id: nil }
          end

          return { role: record.role.to_s, tenant_id: record.tenant_id }
        end

        # classic mode (no store): the gateway token is the only credential.
        # Constant-time comparison: the operator token doesn't leak via timing.
        return :unauthorized unless Rack::Utils.secure_compare(gateway_token, provided)

        { role: "operator", tenant_id: nil }
      end
    end
  end
end