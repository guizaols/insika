# frozen_string_literal: true

# SINGLE-PROCESS server for the E2E smoke. `falcon serve` forks N workers (the
# parent's kill -9 doesn't kill the workers and the port stays stuck on reboot);
# here a single async-http process gives full control: kill -9 kills everything and
# frees the port. Serves the SMOKE_APP (already run through Boot -> recovery before
# the listen).
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require_relative "boot_app"

endpoint = Async::HTTP::Endpoint.parse(ENV.fetch("SMOKE_BIND"))
middleware = Protocol::Rack::Adapter.new(SMOKE_APP)

# SERVING mode (L4): turns now spawn as children of a long-lived supervisor
# (created lazily in the serving reactor), surviving the request's disconnect.
# Enabled AFTER the boot (recovery already ran without supervision, waiting for the
# resumed turns to finish).
SMOKE_EXECUTOR.supervised = true

Async do
  Async::HTTP::Server.new(middleware, endpoint).run
  # server.run enters the accept loop and keeps the reactor alive until kill -9.
end
