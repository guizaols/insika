# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Store de domínio das sessões. Persiste transcript + vars
  # sobre um Harness::Store injetado, com schema fixo
  # `session:<id>` no scope "sessions".
  #
  # O transcript persistido é a FONTE DA VERDADE para reconstrução; eventos ao
  # vivo são só estado de entrega. O shape das
  # mensagens (`{"role"=>, "content"=>}`, role ∈ user|assistant|system|tool) é
  # o mesmo que `Runner#seed_history` já consome — o Executor não converte nada.
  #
  # Normaliza symbol→string na ESCRITA (o backend só garante round-trip de
  # tipos JSON); a LEITURA devolve os dados como vêm do backend
  # (chaves string), nunca simetriza de volta para symbols.
  class SessionStore
    include Coercion

    SCOPE = "sessions"
    KEY_PREFIX = "session:"

    Session = Data.define(:id, :messages, :vars, :memory_refs,
                          :created_at, :updated_at)

    # store: qualquer Harness::Store (Memory, SQLite, ...) — injetado pelo
    # composition root (config/wiring.rb). O SessionStore não conhece
    # backend concreto.
    def initialize(store:)
      @store = store
    end

    # -> Session; ArgumentError se id já existe (sessão duplicada é violação de
    # domínio — não sobrescreve silenciosamente).
    def create(id: SecureRandom.uuid, vars: {})
      key = key_for(id)
      raise ArgumentError, "sessão já existe: #{id}" unless @store.get(SCOPE, key).nil?

      now = timestamp
      record = {
        "id" => id.to_s,
        "messages" => [],
        "vars" => deep_stringify(vars),
        "memory_refs" => [],
        "created_at" => now,
        "updated_at" => now
      }
      @store.set(SCOPE, key, record)
      to_session(record)
    end

    # -> Session | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_session(record)
    end

    # -> Session (transcript += messages). Read-modify-write no fiber da própria
    # task, sem lock (um nó, um dono por task). Cada mensagem
    # ganha "at" (ISO8601 UTC) se não vier. NotFoundError se a sessão não existe.
    def append_messages(id, messages)
      record = fetch!(id)
      incoming = (messages.is_a?(Hash) ? [messages] : Array(messages))
                 .map { |msg| stamp(deep_stringify(msg)) }
      record["messages"] += incoming
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> Session (merge RASO: chave aninhada existente é substituída inteira,
    # não fundida). NotFoundError se ausente.
    def update_vars(id, vars)
      record = fetch!(id)
      record["vars"] = record["vars"].merge(deep_stringify(vars))
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> bool (delega ao backend: false para id inexistente)
    def delete(id)
      @store.delete(SCOPE, key_for(id))
    end

    # -> enumera ids sem o prefixo "session:". Sem bloco,
    # retorna Enumerator.
    def each_id
      return enum_for(:each_id) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        yield key.delete_prefix(KEY_PREFIX)
      end
    end

    private

    def key_for(id)
      "#{KEY_PREFIX}#{id}"
    end

    # Carrega o record cru; NotFoundError se ausente (sessão inexistente ->
    # HTTP 404). Erros do backend (StoreError) propagam sem re-embrulhar.
    def fetch!(id)
      record = @store.get(SCOPE, key_for(id))
      raise Harness::NotFoundError, "sessão inexistente: #{id}" if record.nil?

      record
    end

    def to_session(record)
      Session.new(
        id: record["id"],
        messages: record["messages"],
        vars: record["vars"],
        memory_refs: record["memory_refs"],
        created_at: record["created_at"],
        updated_at: record["updated_at"]
      )
    end

    # Carimba "at" (ISO8601 UTC) na mensagem quando ausente; preserva o que vier.
    def stamp(message)
      message["at"] ||= timestamp
      message
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end
