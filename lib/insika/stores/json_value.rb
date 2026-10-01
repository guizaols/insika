# frozen_string_literal: true

require "json"

module Insika
  module Stores
    # The type model every backend shares: JSON types plus Symbol (stored as
    # String). Anything else is refused at the write (fail-fast), so no backend
    # ever stores garbage.
    #
    # Does not use `JSON.generate(strict: true)`: under older json versions
    # `strict` rejects Symbol, which would break the Symbol coercion. The
    # explicit check is independent of the json version.
    module JsonValue
      JSONABLE = [NilClass, TrueClass, FalseClass, Integer, Float, String, Symbol].freeze

      private

      def serialize(value)
        ensure_jsonable!(value)
        JSON.generate(value)
      rescue JSON::GeneratorError => e
        raise Insika::StoreError, "value not serializable: #{e.message}"
      end

      def ensure_jsonable!(value)
        case value
        when *JSONABLE then nil
        when Array then value.each { |v| ensure_jsonable!(v) }
        when Hash then value.each { |k, v| ensure_jsonable!(k); ensure_jsonable!(v) }
        else
          raise Insika::StoreError, "value not serializable: #{value.class} not allowed in JSON"
        end
      end
    end
  end
end
