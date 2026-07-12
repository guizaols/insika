# frozen_string_literal: true

require "rack"
require "rack/utils"

module Harness
  module Server
    # Auth mínima de operador. Fail-closed POR CONSTRUÇÃO: sem
    # token configurado, o /admin não existe para o mundo (503) — nunca aberto
    # por omissão. Módulo puro, testável sem Rack env.
    module AdminAuth
      module_function

      # config_token: config[:admin_token] (o wiring lê HARNESS_ADMIN_TOKEN).
      # header: valor cru do Authorization.
      # -> :disabled | :unauthorized | :ok
      def check(config_token, header)
        return :disabled if config_token.nil? || config_token.empty?

        provided = header.to_s[/\ABearer (.+)\z/, 1]
        return :unauthorized if provided.nil?
        # Comparação em tempo constante: token de operador não vaza por timing.
        return :unauthorized unless Rack::Utils.secure_compare(config_token, provided)

        :ok
      end
    end
  end
end
