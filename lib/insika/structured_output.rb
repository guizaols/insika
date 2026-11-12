# frozen_string_literal: true

module Insika
  # The utility asks' JSON schema. DeepSeek's Chat Completions (their default
  # protocol) can't enforce one: RubyLLM 2.1 fell back to JSON-object mode, 2.2
  # raises instead. Keep 2.1's fallback — every caller already asks for the
  # `{"items": …}` envelope in the prompt and reads a parsed or a raw JSON reply.
  module StructuredOutput
    def self.apply(chat, schema)
      return chat.with_provider_options(response_format: { type: "json_object" }) if deepseek?(chat)

      chat.with_schema("schema" => schema, "strict" => false)
    end

    def self.deepseek?(chat)
      chat.respond_to?(:provider) && chat.provider.respond_to?(:slug) && chat.provider.slug.to_s == "deepseek"
    end
  end
end
