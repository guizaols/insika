# frozen_string_literal: true

module Insika
  # Shared coercions at the input/persistence boundary. They used to live
  # copied in each store/handler; a single home keeps them from drifting.
  module Coercion
    module_function

    # Present string or nil: nil and blank (incl. whitespace-only) become nil;
    # everything else becomes a stripped String.
    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end

    # nil or blank (incl. whitespace-only) -> true.
    def blank?(value) = value.nil? || value.to_s.strip.empty?

    # Inverse of blank? — a usable, non-empty value.
    def present?(value) = !blank?(value)

    # Bytes that come from outside the engine (sockets, pipes, subprocesses)
    # arrive tagged BINARY, or as UTF-8 carrying invalid sequences. Both break
    # `JSON.generate` the moment the text has an accent or an emoji — today a
    # warning ("UTF-8 string passed as BINARY"), an exception from json 3.0 — and
    # that text ends up in a transcript, an event and an SSE frame. Reinterprets
    # the bytes as UTF-8 (the wire encoding of every source we read) and scrubs
    # what is not valid, so what crosses the boundary is always serializable.
    def utf8(str)
      s = str.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s.valid_encoding? ? s : s.scrub
    end

    # Normalizes keys and Symbols to String recursively (the stores' JSON model
    # has no Symbol). Hash -> keys and values; Array -> elements.
    def deep_stringify(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array
        obj.map { |v| deep_stringify(v) }
      when Symbol
        obj.to_s
      else
        obj
      end
    end
  end
end
