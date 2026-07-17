# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Message parts translation: TextPart only in this slice.
      # Tolerates `kind` (A2A ~v0.2+) and `type` (older spec) at the boundary.
      module Message
        # A2A Message (Hash) -> String (concatenates the TextParts). "" if none.
        def self.text_from(a2a_message)
          parts = a2a_message.is_a?(Hash) ? Array(a2a_message["parts"] || a2a_message[:parts]) : []
          parts.filter_map do |part|
            next unless part.is_a?(Hash)

            kind = part["kind"] || part["type"] || part[:kind] || part[:type]
            (part["text"] || part[:text]).to_s if kind.to_s == "text"
          end.join
        end

        # String -> A2A Message (role agent, 1 TextPart).
        def self.agent_message(text)
          { role: "agent", parts: [{ kind: "text", text: text.to_s }] }
        end
      end
    end
  end
end
