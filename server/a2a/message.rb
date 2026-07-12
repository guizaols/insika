# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Tradução de message parts (P3A-01, D4/L3): só TextPart nesta fatia.
      # Tolera `kind` (A2A ~v0.2+) e `type` (spec mais antigo) na borda.
      module Message
        # A2A Message (Hash) -> String (concatena os TextPart). "" se nenhum.
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
