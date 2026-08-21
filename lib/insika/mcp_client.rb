# frozen_string_literal: true

module Insika
  # Builds a live MCP client for an McpStore record (RFC-0040). The ONE seam
  # between Insika and the transport gem: `ruby_llm-mcp` speaks stdio,
  # Streamable HTTP and SSE with the full lifecycle (initialize handshake,
  # session-id, notifications) — Insika stops maintaining its own protocol
  # client. Swapping the gem later (e.g. to modelcontextprotocol/ruby-sdk)
  # touches only this file.
  #
  # `require "ruby_llm/mcp"` is LAZY, done here rather than at `require
  # "insika"` time (spec/insika/load_guard_spec.rb): the gem drags in
  # ruby_llm + httpx, the same opt-in-cost discipline as every other provider
  # surface.
  #
  # Client LIFECYCLE (start/stop, registering the child process with
  # Insika::Shutdown so it dies on SIGTERM) belongs to whoever holds the
  # client across calls — the live tool registry, later work. `for` itself
  # returns an unstarted client (`start: false`); building one is cheap and
  # side-effect-free.
  module McpClient
    # A stdio instance is arbitrary command execution by config — refused
    # unless the operator opted in (config-over-convention, same pattern as
    # the egress envs).
    class StdioDisabled < Insika::Error; end

    module_function

    # `record` — the RAW McpStore record (get_raw/all_raw; never the masked
    # one — a masked record's credentials are the __OCULTO__ sentinel, not
    # something a client can connect with).
    # -> RubyLLM::MCP::Client, not started. Raises StdioDisabled (stdio, gate
    # off), Insika::Error (http/sse, egress-blocked url) or
    # Insika::ValidationError (unknown transport).
    def for(record, env_reader: Insika::EnvSchema, egress: Insika::EgressGuard)
      require "ruby_llm/mcp"

      case record["transport"].to_s
      when "stdio" then stdio_client(record, env_reader: env_reader)
      when "http" then http_client(record, :streamable_http, egress: egress)
      when "sse" then http_client(record, :sse, egress: egress)
      else
        raise Insika::ValidationError,
              "MCP instance '#{record["name"]}' has an unknown transport: #{record["transport"].inspect}"
      end
    end

    def stdio_client(record, env_reader:)
      unless env_reader.truthy?(env_reader.read("INSIKA_MCP_STDIO"))
        raise StdioDisabled,
              "MCP instance '#{record["name"]}' is stdio (arbitrary command execution by config) — " \
              "set INSIKA_MCP_STDIO=1 to allow it to start"
      end

      RubyLLM::MCP.client(
        name: record["name"], transport_type: :stdio, start: false,
        config: { command: record["command"], args: Array(record["args"]), env: record["env"] || {} }
      )
    end

    def http_client(record, transport_type, egress:)
      url = record["url"]
      reason = egress.violation(url)
      raise Insika::Error, "MCP target blocked: #{reason}" if reason

      RubyLLM::MCP.client(
        name: record["name"], transport_type: transport_type, start: false,
        config: { url: url, headers: record["headers"] || {} }
      )
    end
  end
end
