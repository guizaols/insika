# frozen_string_literal: true

module Harness
  # Coerções compartilhadas na borda de entrada/persistência. Antes viviam
  # copiadas em cada store/handler; uma casa só evita que derivem.
  module Coercion
    module_function

    # String presente ou nil: "" e nil viram nil; o resto vira String.
    def presence(str)
      str.nil? || str.to_s.empty? ? nil : str.to_s
    end

    # Normaliza chaves e Symbols a String recursivamente (o modelo JSON dos
    # stores não tem Symbol). Hash -> chaves e valores; Array -> elementos.
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
