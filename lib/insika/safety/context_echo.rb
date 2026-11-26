# frozen_string_literal: true

module Insika
  module Safety
    # The model pasting a context block into its answer. A consumer wraps what it
    # tells the model in tags inside the customer's message (`<memoria>…</memoria>`,
    # `<historico_compras>…</historico_compras>`), and now and then the reply carries
    # one of those blocks back to the customer.
    #
    # Which tags are context is not guessed from their spelling: it is every paired
    # tag the consumer actually sent in this chat's user messages. A block with one of
    # those names is cut from the reply. Self-closing tags (`<carrinho/>`) are left
    # alone: consumers use those as markers the reply is meant to carry.
    module ContextEcho
      OPEN = /<([A-Za-z_][\w-]*)(?:\s[^>]*)?>/

      module_function

      # -> [text, cut_blocks]. inputs: the user message texts of the chat.
      def cut(reply, inputs)
        reply = reply.to_s
        return [reply, 0] unless reply.include?("</")

        cut = 0
        text = context_tags(inputs).reduce(reply) do |acc, tag|
          acc.gsub(%r{[ \t]*<#{Regexp.escape(tag)}(?:\s[^>]*)?>.*?</#{Regexp.escape(tag)}\s*>[ \t]*\n?}m) do
            cut += 1
            ""
          end
        end
        [cut.zero? ? reply : text.gsub(/\n{3,}/, "\n\n").strip, cut]
      end

      # Tag names the inputs open AND close.
      def context_tags(inputs)
        Array(inputs).flat_map do |input|
          input = input.to_s
          input.scan(OPEN).flatten.uniq.select { |tag| input.include?("</#{tag}>") }
        end.uniq
      end
    end
  end
end
