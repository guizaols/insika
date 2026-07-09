# frozen_string_literal: true

require "json"

module Harness
  module Stores
    # Backend em memória para dev/teste (doc 01 §2-§3).
    # Serializa JSON mesmo em memória (L2): paridade exata de semântica de
    # tipos com o SQLite — a suíte de contrato é honesta.
    # Sem lock: fibers cooperativos não preemptam no meio de uma operação
    # de Hash (doc 01 §5).
    class Memory
      include Store

      def initialize
        @data = new_store
        @tx_depth = 0
        @snapshot = nil
      end

      def get(scope, key)
        raw = @data[scope][key]
        return nil if raw.nil?

        JSON.parse(raw)
      end

      def set(scope, key, value)
        @data[scope][key] = serialize(value)
        value
      end

      def delete(scope, key)
        !@data[scope].delete(key).nil?
      end

      def list(scope, prefix = nil)
        keys = @data[scope].keys.sort
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      end

      # Snapshot no início da transação mais externa; exceção em qualquer
      # nível -> restaura o snapshot e re-propaga (rollback REAL, doc 01 §2).
      # Aninhada reusa a externa (sem SAVEPOINT na Fase 1).
      def transaction
        if @tx_depth.positive?
          @tx_depth += 1
          begin
            return yield
          ensure
            @tx_depth -= 1
          end
        end

        @snapshot = deep_snapshot
        @tx_depth = 1
        begin
          yield
        rescue StandardError
          restore_snapshot
          raise
        ensure
          @tx_depth = 0
          @snapshot = nil
        end
      end

      # Tipos do modelo JSON + Symbol (coerido a String na escrita, C8).
      # Qualquer outro tipo é "lixo" e deve ser rejeitado (C22).
      JSONABLE = [NilClass, TrueClass, FalseClass, Integer, Float,
                  String, Symbol].freeze
      private_constant :JSONABLE

      private

      def new_store
        Hash.new { |h, scope| h[scope] = {} }
      end

      # Enforce o modelo de tipos do contrato na borda (doc 01 §2, §6):
      # Symbol/símbolo-chave viram String (C8); tipo fora do modelo JSON ->
      # StoreError na ESCRITA (fail-fast; nunca grava lixo — C22).
      #
      # Não usa `JSON.generate(strict: true)`: sob json 2.7.1 (versão travada)
      # `strict` rejeita Symbol, o que violaria C8. A validação explícita é
      # independente da versão do json e dá a MESMA semântica ao SQLite (task 4).
      # A exceção do bloco de transação (do chamador) propaga sem encapsular;
      # só erro do backend vira StoreError.
      def serialize(value)
        ensure_jsonable!(value)
        JSON.generate(value)
      rescue JSON::GeneratorError => e
        raise Harness::StoreError, "valor não serializável: #{e.message}"
      end

      def ensure_jsonable!(value)
        case value
        when *JSONABLE then nil
        when Array then value.each { |v| ensure_jsonable!(v) }
        when Hash then value.each { |k, v| ensure_jsonable!(k); ensure_jsonable!(v) }
        else
          raise Harness::StoreError,
                "valor não serializável: #{value.class} not allowed in JSON"
        end
      end

      # Dup profundo: os valores já são strings JSON (imutáveis na prática),
      # então dup por scope basta — não há estrutura aninhada mutável.
      def deep_snapshot
        @data.each_with_object({}) { |(scope, kv), acc| acc[scope] = kv.dup }
      end

      # Recria o Hash com default proc (senão @data[scope] em scope novo após
      # rollback levantaria erro) e restaura só os scopes do snapshot —
      # scopes criados dentro da transação somem.
      def restore_snapshot
        @data = new_store
        @snapshot.each { |scope, kv| @data[scope] = kv }
      end
    end
  end
end
