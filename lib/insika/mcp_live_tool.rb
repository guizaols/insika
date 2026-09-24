# frozen_string_literal: true

require "json"
require "ruby_llm"

module Insika
  # One live MCP tool. `name`/`description`/`parameters_schema`
  # come from the CACHED descriptor (McpStore#tools_cache — no I/O to build
  # this instance, same cost as any other tool the registry hands out).
  # `#execute` is the only thing that touches the network, calling through
  # `client_for` (Insika::McpToolRegistry's memoized, lazy client) into
  # `RubyLLM::MCP::Tool#call`, which already unwraps `content[].text` and
  # turns `isError` into `{error:}`.
  #
  # Like every tool in this codebase, `#execute` NEVER raises: a connection
  # or protocol failure becomes `{error:}`, the model's normal failure path
  # (see Tools::DataDefinedTool's own rule).
  class McpLiveTool < RubyLLM::Tool
    def initialize(instance_name:, tool:, client_for:, overrides: {})
      @instance_name = instance_name
      @tool = tool
      @client_for = client_for
      @evidence = overrides["evidence"] && Insika::Evidence::Spec.parse(overrides["evidence"])
      @requires_evidence = Insika::ToolDefinition.normalize_requires_evidence(
        overrides["requires_evidence"], top_level_params
      )
      super()
    end

    def name = @tool["name"]
    def description = @tool["description"].to_s

    # The two questions the envelope asks any tool: what of this result is
    # evidence, and which of these parameters may only carry an id some tool
    # already returned. A server cannot answer either — it does not know what the
    # deployment trusts — so they come from the instance's own configuration and
    # are nil for every tool nobody configured, which is what they were before.
    attr_reader :evidence, :requires_evidence

    def parameters_schema
      schema = @tool["inputSchema"]
      schema.nil? || schema.empty? ? { "type" => "object", "properties" => {} } : schema
    end

    def execute(**params)
      live = @client_for.call.tools.find { |tool| tool.name == @tool["name"] }
      raise Insika::NotFoundError, "tool '#{@tool["name"]}' no longer offered" if live.nil?

      parsed(live.call(**params))
    rescue StandardError => e
      { error: "MCP instance '#{@instance_name}' tool '#{@tool["name"]}' failed: #{e.message}" }
    end

    private

    # An MCP result arrives as text — sometimes a String, sometimes the gem's own
    # content object wrapping one. Only a tool someone declared evidence for is
    # parsed into the object the extractor can dig into; everywhere else the result
    # reaches the model exactly as it did before.
    def parsed(result)
      return result unless @evidence

      text = case result
             when String then result
             when Hash then nil
             else result.respond_to?(:text) ? result.text : nil
             end
      return result if text.nil?

      object = begin
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end
      object.is_a?(Hash) ? object : result
    end

    def top_level_params
      properties = parameters_schema["properties"] || parameters_schema[:properties] || {}
      properties.keys.map(&:to_s)
    end
  end
end
