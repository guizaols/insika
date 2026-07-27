# frozen_string_literal: true

# Launches the insika-code prototype server: a single-process Async::HTTP
# server (same stack as scripts/serve_real.rb) exposing the engine's HTTP API —
# notably POST /v1/responses (SSE), GET /v1/events (SSE) and
# POST /v1/commands/approve_action, which the CLI (bin/insika-code) drives.
#
# Usage:
#   HARNESS_CODE_ROOT=/path/to/project \
#   DEEPSEEK_API_KEY=... \
#   ruby examples/insika-code/server.rb           # binds http://localhost:9292
#
# Env:
#   HARNESS_CODE_ROOT      workspace root the tools are sandboxed to (default: cwd)
#   HARNESS_CODE_TOKEN     bearer for /v1/responses (default: "local-code")
#   HARNESS_CODE_MODEL     model id (default: "deepseek-chat")
#   HARNESS_CODE_PROVIDER  provider (default: "deepseek")
#   BIND                   bind URL (default: http://localhost:9292)
#   HARNESS_DB             SQLite path for durable state (default: in-memory)

$stdout.sync = true
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack"
require_relative "boot"

W = InsikaCodeApp::Wiring
BIND = ENV.fetch("BIND", "http://localhost:9292")

endpoint   = Async::HTTP::Endpoint.parse(BIND)
middleware = Protocol::Rack::Adapter.new(W::APP)

puts "\e[1minsika-code — code agent on the insika engine\e[0m"
puts "  workspace : #{InsikaCodeApp::WORKSPACE_ROOT}"
puts "  model     : #{InsikaCodeApp::PROVIDER}:#{InsikaCodeApp::MODEL}"
puts "  bind      : #{BIND}"
puts "  token     : #{InsikaCodeApp::GATEWAY_TOKEN}"
puts "  state     : #{W.durable? ? 'durable (sqlite)' : 'ephemeral (memory)'}"
puts "  tools     : read_file list_dir grep | write_file edit_file bash (approval-gated)"
puts "  CLI       : HARNESS_CODE_URL=#{BIND} HARNESS_CODE_TOKEN=#{InsikaCodeApp::GATEWAY_TOKEN} " \
     "ruby examples/insika-code/bin/insika-code"
puts "  Ctrl-C to stop."

Async do
  # Serving mode: turns are children of a long-lived supervisor and survive the
  # client disconnecting mid-turn (matches serve_real.rb).
  W::EXECUTOR.supervised = true
  Async::HTTP::Server.new(middleware, endpoint).run
end
