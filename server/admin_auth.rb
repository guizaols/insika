# frozen_string_literal: true

require "rack"
require "rack/utils"

module Harness
  module Server
    # Minimal operator auth. Fail-closed BY CONSTRUCTION: with no
    # token configured, /admin does not exist to the world (503) — never open
    # by omission. Pure module, testable without a Rack env.
    module AdminAuth
      module_function

      # config_token: config[:admin_token] (the wiring reads HARNESS_ADMIN_TOKEN).
      # header: raw Authorization value.
      # -> :disabled | :unauthorized | :ok
      def check(config_token, header)
        return :disabled if config_token.nil? || config_token.empty?

        provided = header.to_s[/\ABearer (.+)\z/, 1]
        return :unauthorized if provided.nil?
        # Constant-time comparison: the operator token doesn't leak via timing.
        return :unauthorized unless Rack::Utils.secure_compare(config_token, provided)

        :ok
      end
    end
  end
end
