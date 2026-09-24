# frozen_string_literal: true

module Insika
  # Maps persisted MCP configuration to RubyLLM's native, lazy client.
  # Insika retains the stdio opt-in and deployment egress policy.
  module McpClient
    class StdioDisabled < Insika::Error; end

    module_function

    def for(record, env_reader: Insika::EnvSchema, egress: Insika::EgressGuard)
      require "ruby_llm"

      case record["transport"].to_s
      when "stdio" then stdio_client(record, env_reader: env_reader)
      when "http" then http_client(record, egress: egress, env_reader: env_reader)
      when "sse"
        raise Insika::ValidationError,
              "MCP instance '#{record['name']}' uses legacy SSE; configure its Streamable HTTP endpoint instead"
      else
        raise Insika::ValidationError,
              "MCP instance '#{record['name']}' has an unknown transport: #{record['transport'].inspect}"
      end
    end

    def egress_options(env_reader)
      hosts = env_reader.read("INSIKA_EGRESS_HOSTS").to_s.split(",").map(&:strip).reject(&:empty?)
      { allow_http: env_reader.truthy?(env_reader.read("INSIKA_EGRESS_ALLOW_HTTP")),
        allow_private: env_reader.truthy?(env_reader.read("INSIKA_EGRESS_ALLOW_PRIVATE")),
        host_allowlist: (hosts unless hosts.empty?) }.compact
    end

    def stdio_client(record, env_reader:)
      unless env_reader.truthy?(env_reader.read("INSIKA_MCP_STDIO"))
        raise StdioDisabled,
              "MCP instance '#{record['name']}' is stdio (arbitrary command execution by config) — " \
              "set INSIKA_MCP_STDIO=1 to allow it to start"
      end

      RubyLLM.mcp(name: record["name"], command: [record["command"], *Array(record["args"])],
                  env: record["env"] || {})
    end

    def http_client(record, egress:, env_reader:)
      url = record["url"]
      reason = egress.violation(url, **egress_options(env_reader))
      raise Insika::Error, "MCP target blocked: #{reason}" if reason
      unless RubyLLM::MCP::HTTP.secure?(url)
        raise Insika::ValidationError, "Native MCP requires HTTPS without URL credentials, except on loopback hosts"
      end

      RubyLLM.mcp(name: record["name"], url: url, headers: record["headers"] || {})
    end
  end
end
