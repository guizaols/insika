# frozen_string_literal: true

# Servidor SINGLE-PROCESS do smoke E2E. `falcon serve` forka N workers (o
# kill -9 do pai não mata os workers e a porta fica presa no reboot); aqui um
# único processo async-http dá controle total: kill -9 mata tudo e libera a
# porta. Serve o SMOKE_APP (já passado pelo Boot -> recovery antes do listen).
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require_relative "boot_app"

endpoint = Async::HTTP::Endpoint.parse(ENV.fetch("SMOKE_BIND"))
middleware = Protocol::Rack::Adapter.new(SMOKE_APP)

Async do
  Async::HTTP::Server.new(middleware, endpoint).run
  # server.run entra no loop de accept e mantém o reactor vivo até o kill -9.
end
