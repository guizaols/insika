# frozen_string_literal: true

module Harness
  # Shared coercions at the input/persistence boundary. They used to live
  # copied in each store/handler; a single home keeps them from drifting.
  module Coercion
    module_function

    # Present string or nil: "" and nil become nil; everything else becomes a String.
    def presence(str)
      str.nil? || str.to_s.empty? ? nil : str.to_s
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
