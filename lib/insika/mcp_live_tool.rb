# frozen_string_literal: true

require "ruby_llm"

module Insika
  # One live MCP tool (RFC-0040 PR2). `name`/`description`/`params_schema`
  # come from the CACHED descriptor (McpStore#tools_cache — no I/O to build
  # this instance, same cost as any other tool the registry hands out).
  # `#execute` is the only thing that touches the network, calling through
  # `client_for` (Insika::McpToolRegistry's memoized, started client — this
  # class never builds or starts one itself) into the gem's own
  # `RubyLLM::MCP::Tool#execute`, which already unwraps `content[].text` and
  # turns `isError` into `{error:}`.
  #
  # Like every tool in this codebase, `#execute` NEVER raises: a connection
  # or protocol failure becomes `{error:}`, the model's normal failure path
  # (see Tools::DataDefinedTool's own rule).
  class McpLiveTool < RubyLLM::Tool
    def initialize(instance_name:, tool:, client_for:)
      @instance_name = instance_name
      @tool = tool
      @client_for = client_for
      super()
    end

    def name = @tool["name"]
    def description = @tool["description"].to_s

    def params_schema
      schema = @tool["inputSchema"]
      schema.nil? || schema.empty? ? { "type" => "object", "properties" => {} } : schema
    end

    def execute(**params)
      live = @client_for.call.tool(@tool["name"])
      raise Insika::NotFoundError, "tool '#{@tool["name"]}' no longer offered" if live.nil?

      live.execute(**params)
    rescue StandardError => e
      { error: "MCP instance '#{@instance_name}' tool '#{@tool["name"]}' failed: #{e.message}" }
    end
  end
end
