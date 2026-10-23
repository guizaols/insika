# frozen_string_literal: true

require "json"

module Insika
  # A tool call the model wrote as TEXT instead of through the API's `tool_calls`.
  #
  # deepseek-v4-flash does it now and then: the message comes back with no tool call
  # and a body like
  #
  #   <tool_call>
  #   search_faq
  #   <parameter name="query">quem é a loja Mensageiros</parameter>
  #   </tool_call>
  #
  # Left alone that is the turn's ANSWER: the tool never runs, the consumer's leak
  # guard swallows the text and the customer gets silence — and the markup stays in
  # the session history, where the model reads itself calling tools that way and does
  # it again (Loja Mensageiros, 23/10/2026). The Executor rewrites such a message
  # into a real tool call before the next step, so the loop runs the tool and the
  # history holds what a normal call would have left.
  #
  # Two spellings: the name-then-<parameter> one above (the one seen in production)
  # and the Hermes/Qwen JSON one (`<tool_call>{"name": …, "arguments": {…}}`).
  # Anything else — or a name the chat does not offer — is NOT recovered: inventing a
  # call is worse than the silence the consumer already guards.
  module TextToolCall
    BLOCK = %r{<tool_call>\s*(.*?)\s*</tool_call>}m
    PARAM = %r{<parameter\s+name\s*=\s*"([^"]+)"\s*>(.*?)</parameter>}m
    NAME = /\A([A-Za-z_][\w.-]*)\s*(?:<|\z)/

    module_function

    # content: the assistant message text. known: the tool names the chat offers.
    # -> { calls: [{ name:, arguments: }], text: what is left outside the blocks } | nil
    def parse(content, known)
      text = content.to_s
      return nil unless text.include?("<tool_call>")

      calls = text.scan(BLOCK).map { |(body)| call_from(body) }
      return nil if calls.empty? || calls.any? { |call| call.nil? || !known.include?(call[:name]) }

      { calls: calls, text: text.gsub(BLOCK, "").strip }
    end

    def call_from(body)
      return json_call(body) if body.start_with?("{")

      name = body[NAME, 1] or return nil
      # ponytail: parameter values stay strings (the spelling carries no types);
      # every tool seen leaking takes strings. Coerce by schema if one ever doesn't.
      { name: name, arguments: body.scan(PARAM).to_h { |key, value| [key, value.strip] } }
    end

    def json_call(body)
      data = JSON.parse(body)
      return nil unless data.is_a?(Hash) && data["name"].is_a?(String)

      arguments = data["arguments"]
      arguments = JSON.parse(arguments) if arguments.is_a?(String)
      { name: data["name"], arguments: arguments.is_a?(Hash) ? arguments : {} }
    rescue JSON::ParserError
      nil
    end
  end
end
