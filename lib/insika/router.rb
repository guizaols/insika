# frozen_string_literal: true

# RFC-0043 — Session-sticky router. NOT required by `require "insika"` (like
# server/ and the Studio, it pulls in async-http and is only needed by an
# operator who actually runs `bin/insika-router`): the engine's serving path
# (`insika serve` / `DSL::ServerBoot` / `WEB_CONCURRENCY=1`) is completely
# unaffected by this file's existence — the router is additive infrastructure
# for whoever chooses to scale past one worker, never a default.
require_relative "coercion"
require_relative "router/hash_ring"
require_relative "router/session_key"
require_relative "router/backend_pool"
require_relative "router/app"

module Insika
  module Router
  end
end
