# frozen_string_literal: true

module Harness
  # Contrato mínimo de persistência.
  # KV escopado por namespace, transacional quando o backend suporta.
  # Toda implementação passa a MESMA suíte de contrato
  # (spec/harness/store_contract.rb). Valores devem ser serializáveis em JSON.
  #
  # scope: String — separa domínios/tenants (ex.: "sessions", "tasks:tenant_x")
  # key:   String hierárquica (ex.: "task:123", "checkpoint:123:turn:4")
  #
  # Regras do contrato (verificadas pela suíte):
  # - get de chave inexistente -> nil (nunca exceção)
  # - set sobrescreve silenciosamente (last-write-wins)
  # - round-trip preserva tipos JSON; Symbols viram Strings (domínio
  #   normaliza na borda)
  # - list(scope) só retorna chaves do scope, ordenadas lexicograficamente;
  #   prefix filtra por start_with?
  # - transaction aninhada reusa a transação externa (sem SAVEPOINT)
  # - falha de serialização na escrita -> Harness::StoreError (fail-fast)
  #
  # Backends fazem `include Store` e sobrescrevem os cinco métodos; qualquer
  # método esquecido levanta NotImplementedError (fail-fast, melhor que um
  # NoMethodError distante).
  module Store
    # -> Object | nil (desserializado)
    def get(scope, key)
      raise NotImplementedError, "#{self.class}#get"
    end

    # -> value (o MESMO objeto passado, não o round-trip)
    def set(scope, key, value)
      raise NotImplementedError, "#{self.class}#set"
    end

    # -> true | false (existia?)
    def delete(scope, key)
      raise NotImplementedError, "#{self.class}#delete"
    end

    # -> [String] chaves ordenadas lexicograficamente
    def list(scope, prefix = nil)
      raise NotImplementedError, "#{self.class}#list"
    end

    # -> resultado do bloco; atômico se o backend suportar
    def transaction(&blk)
      raise NotImplementedError, "#{self.class}#transaction"
    end
  end
end
