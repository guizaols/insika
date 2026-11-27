# frozen_string_literal: true

module Insika
  module Safety
    # The model pasting a context block into its answer. A consumer wraps what it
    # tells the model in tags inside the customer's message (`<memoria>…</memoria>`,
    # `<historico_compras>…</historico_compras>`), and now and then the reply carries
    # one of those blocks, or a stray piece of one, back to the customer.
    #
    # Which tags are context is not guessed from their spelling. It is every paired
    # tag the consumer sent in this chat's user messages, plus every tag the system
    # prompt names in open form (`<canal>`): a prompt that explains its context
    # blocks teaches the model to write them even on a turn that did not send them.
    # A tag the prompt also shows self-closing (`<carrossel/>`) is a marker the reply
    # is meant to carry, and self-closing tags are never touched.
    #
    # A whole block is cut with its content; a lone opening or closing tag left over
    # is cut alone.
    module ContextEcho
      OPEN = %r{<([A-Za-z_][\w-]*)(?:\s[^>]*?)?(?<!/)>}
      SELF_CLOSING = %r{<([A-Za-z_][\w-]*)(?:\s[^>]*?)?/>}

      module_function

      # -> [text, cut_count]. inputs: the user message texts of the chat.
      # instructions: the system prompt the model saw.
      def cut(reply, inputs, instructions = nil)
        reply = reply.to_s
        return [reply, 0] unless reply.include?("<")

        cut = 0
        text = context_tags(inputs, instructions).reduce(reply) do |acc, tag|
          name = Regexp.escape(tag)
          acc.gsub(%r{[ \t]*<#{name}(?:\s[^>]*?)?(?<!/)>.*?</#{name}\s*>[ \t]*\n?}m) { cut += 1; "" }
             .gsub(%r{[ \t]*</?#{name}(?:\s[^>]*?)?(?<!/)>[ \t]*\n?}) { cut += 1; "" }
        end
        [cut.zero? ? reply : text.gsub(/\n{3,}/, "\n\n").strip, cut]
      end

      def context_tags(inputs, instructions = nil)
        sent = Array(inputs).flat_map do |input|
          input = input.to_s
          input.scan(OPEN).flatten.uniq.select { |tag| input.include?("</#{tag}>") }
        end
        prompt = instructions.to_s
        named = prompt.scan(OPEN).flatten.uniq - prompt.scan(SELF_CLOSING).flatten
        (sent + named).uniq
      end
    end
  end
end
