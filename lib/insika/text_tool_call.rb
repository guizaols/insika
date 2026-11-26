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
  #   <parameter name="query">quem é a loja Exemplo</parameter>
  #   </tool_call>
  #
  # Left alone that is the turn's ANSWER: the tool never runs, the consumer's leak
  # guard swallows the text and the customer gets silence — and the markup stays in
  # the session history, where the model reads itself calling tools that way and does
  # it again (Loja Exemplo, 23/10/2026). The Executor rewrites such a message
  # into a real tool call before the next step, so the loop runs the tool and the
  # history holds what a normal call would have left.
  #
  # Spellings recovered: the name-then-<parameter> one above, the Hermes/Qwen JSON
  # one (`<tool_call>{"name": …, "arguments": {…}}`), and DeepSeek's DSML ones —
  # `<invoke name="x">` and the tool name as the tag (`<call_support>`), both with
  # `｜｜DSML｜｜` tokens sprinkled in and often cut before the closing tag (niini,
  # 09/11/2026). Anything else — or a name the chat does not offer — is NOT
  # recovered: inventing a call is worse than silence. What is not recovered is
  # still never published: see .strip_markup.
  #
  # The tool-name tag also comes with a stray quote (`<call_support">`) and with the
  # arguments as child tags (`<reason>x</reason>`) or as `reason="x"` lines; all
  # three are read the same way.
  module TextToolCall
    BLOCK = %r{<tool_call>\s*(.*?)\s*</tool_call>}m
    PARAM = %r{<parameter\s+name\s*=\s*"([^"]+)"[^>]*>(.*?)</parameter>}m
    CHILD = %r{<([A-Za-z_]\w*)"?[^>]*>(.*?)</\1\s*>}m
    ATTR = /^\s*([A-Za-z_]\w*)\s*=\s*"(.*)"\s*$/
    NAME = /\A([A-Za-z_][\w.-]*)\s*(?:<|\z)/
    INVOKE = %r{<invoke\s+name\s*=\s*"([^"]+)"[^>]*>(.*?)(?:</invoke>|\z)}m
    # DeepSeek's markup token, in any of the spellings seen: `<｜DSML｜`, `</｜｜DSML｜｜ x>`.
    DSML = /[｜|]+\s*DSML\s*[｜|]+\s*/
    WRAPPERS = %r{</?\s*(?:function_calls|calls)\s*>}
    # Tool-call markup a customer must never read.
    MARKUP = /DSML|<\s*\/?\s*(?:tool_call|invoke|function_calls|parameter)\b/

    module_function

    # content: the assistant message text. known: the tool names the chat offers.
    # -> { calls: [{ name:, arguments: }], text: what is left outside the blocks } | nil
    def parse(content, known)
      text = normalize(content)
      return nil unless text.match?(MARKUP) || text.match?(tool_tag(known))

      calls, rest = blocks(text, known)
      return nil if calls.empty? || calls.any? { |call| call.nil? || !known.include?(call[:name]) }

      { calls: calls, text: strip_markup(rest.gsub(WRAPPERS, "")).strip }
    end

    # The text before the first tool-call markup — what is safe to publish. Bare
    # tags right before it (`<call_support>`) go too: they open the same call.
    # `known`: the chat's tool names; a tag opening one of them is markup too, in
    # any spelling (`<call_support>`, `<call_support">`, `<send_x/>`).
    def strip_markup(text, known = [])
      text = text.to_s
      cut = [text.index(MARKUP), text.index(tool_tag(known))].compact.min or return text
      text[0...cut].sub(%r{(?:\s*</?[\w.-]+>)+\s*\z}, "").strip
    end

    # `<name` of a known tool, followed by what can end a tag name.
    def tool_tag(known)
      return /(?!)/ if known.empty?

      %r{<(?:#{known.map { |n| Regexp.escape(n) }.join('|')})(?=[\s"/>])}
    end

    def normalize(content) = content.to_s.gsub(DSML, "")

    def blocks(text, known)
      if text.include?("<tool_call>")
        [text.scan(BLOCK).map { |(body)| call_from(body) }, text.gsub(BLOCK, "")]
      elsif text.match?(INVOKE)
        [text.scan(INVOKE).map { |name, body| params_call(name, body) }, text.gsub(INVOKE, "")]
      else
        bare = %r{<(#{known.map { |n| Regexp.escape(n) }.join('|')})"?\s*>(.*?)(?:</\1\s*>|\z)}m
        calls = text.scan(bare).filter_map { |name, body| bare_call(name, body) }
        [calls, text.gsub(bare, "")]
      end
    end

    def params_call(name, body) = { name: name, arguments: body.scan(PARAM).to_h { |k, v| [k, v.strip] } }

    # The tool-name tag's body: <parameter> tags, else child tags, else key="value"
    # lines. nil when it has none of them.
    def bare_call(name, body)
      pairs = [PARAM, CHILD, ATTR].lazy.map { |re| body.scan(re) }.find(&:any?) or return nil
      { name: name, arguments: pairs.to_h { |k, v| [k, v.strip] } }
    end

    def call_from(body)
      return json_call(body) if body.start_with?("{")

      name = body[NAME, 1] or return nil
      # ponytail: parameter values stay strings (the spelling carries no types);
      # every tool seen leaking takes strings. Coerce by schema if one ever doesn't.
      params_call(name, body)
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
