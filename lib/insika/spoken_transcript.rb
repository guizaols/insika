# frozen_string_literal: true

module Insika
  # The transcript slice an EXTRACTOR reads — memory distillation, knowledge
  # extraction. Only what people said: `user` and `assistant` prose. A
  # `role: tool` message is a product description, a search result, an FAQ body
  # — third-party text; a customer fact or a learned concept distilled from it
  # is a defect, not a behaviour to preserve. Tool-call payloads never render
  # either (only `content` does). Indices are the ORIGINAL message positions,
  # so a proposal's `turns` still point at the right message.
  module SpokenTranscript
    module_function

    ROLES = %w[user assistant].freeze

    # -> String, PII-redacted (what reaches the utility model follows the same
    # redaction rule as what gets persisted).
    def render(messages)
      lines = Array(messages).each_with_index.filter_map do |m, i|
        role = (m["role"] || m[:role]).to_s
        content = (m["content"] || m[:content]).to_s
        next unless ROLES.include?(role) && !content.strip.empty?

        "[#{i}] #{role}: #{content}"
      end
      redacted, = Insika::Safety::Detectors.redact(lines.join("\n"))
      redacted
    end
  end
end
