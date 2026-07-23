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
