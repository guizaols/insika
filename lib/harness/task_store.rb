# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Store de domínio das tasks. Persiste Tasks sobre um
  # Harness::Store injetado, com a MÁQUINA DE ESTADOS validada aqui: o store é o
  # único ponto de escrita de status, então os
  # invariantes moram onde a escrita mora. Transição inválida é bug e levanta
  # ArgumentError alto e cedo — é assim que corridas lógicas são
  # detectadas sem lock.
  #
  # Cada Execution é UMA tentativa; retry/resume abre nova entrada, nunca
  # sobrescreve. `claimed_by`/`claim_expires_at`
  # ficam SEMPRE nil — o schema já os reserva para o lease/lock futuro,
  # nenhum método os escreve.
  class TaskStore
    SCOPE = "tasks"
    KEY_PREFIX = "task:"

    STATUSES = %i[queued running waiting paused completed failed cancelled].freeze

    # Transições válidas — tudo fora disso é bug -> ArgumentError.
    TRANSITIONS = {
      # queued -> failed: um turno enfileirado no SessionActor pode falhar
      # ao INICIAR (erro de spawn antes do fiber) sem nunca rodar.
      queued: %i[running cancelled failed],
      running: %i[waiting paused completed failed cancelled],
      waiting: %i[running cancelled failed],
      paused: %i[running cancelled],
      completed: [], failed: [], cancelled: [] # terminais
    }.freeze

    Task      = Data.define(:id, :status, :command, :session_id, :executions,
                            :mailbox_state, :claimed_by, :claim_expires_at,
                            :created_at, :updated_at)
    Execution = Data.define(:attempt, :started_at, :finished_at, :outcome, :error)

    def initialize(store:)
      @store = store
    end

    # -> Task (status :queued). command: Hash ({type:, payload:, meta:}) ou
    # qualquer objeto que responda a to_h (ex.: Harness::Command).
    # ArgumentError se o id já existir.
    def create(command:, session_id: nil, id: SecureRandom.uuid)
      key = key_for(id)
      raise ArgumentError, "task já existe: #{id}" unless @store.get(SCOPE, key).nil?

      now = timestamp
      record = {
        "id" => id.to_s,
        "status" => "queued",
        "command" => deep_stringify(command.respond_to?(:to_h) ? command.to_h : command),
        "session_id" => session_id&.to_s,
        "executions" => [],
        "mailbox_state" => { "pending" => [] },
        "claimed_by" => nil, # reservado p/ uso futuro, nunca escrito
        "claim_expires_at" => nil,
        "created_at" => now,
        "updated_at" => now
      }
      @store.set(SCOPE, key, record)
      to_task(record)
    end

    # -> Task | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_task(record)
    end

    # -> Task; valida a máquina de estados. NotFoundError se ausente,
    # ArgumentError para status fora do enum ou transição inválida.
    # Se `error:` vier E houver Execution aberta, fecha-a na mesma escrita
    # (caminho do Recovery).
    def transition(id, to:, error: nil)
      record = fetch!(id)
      target = to.to_sym
      raise ArgumentError, "status inválido: #{to}" unless STATUSES.include?(target)

      from = record["status"].to_sym
      unless TRANSITIONS.fetch(from).include?(target)
        raise ArgumentError, "transição inválida: #{from} -> #{target}"
      end

      close_open_execution(record, outcome: target.to_s, error: error) if error
      record["status"] = target.to_s
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> Task; abre Execution (attempt N+1). ArgumentError se já houver uma
    # aberta (dupla tentativa é bug — um dono por task). Append-only.
    def begin_execution(id)
      record = fetch!(id)
      raise ArgumentError, "já existe uma Execution aberta na task #{id}" if open_execution(record)

      record["executions"] += [{
        "attempt" => record["executions"].size + 1,
        "started_at" => timestamp,
        "finished_at" => nil,
        "outcome" => nil,
        "error" => nil
      }]
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> Task; fecha a Execution corrente. ArgumentError se não houver aberta.
    # NÃO mexe em status (papel do transition).
    def finish_execution(id, outcome:)
      record = fetch!(id)
      open = open_execution(record)
      raise ArgumentError, "nenhuma Execution aberta na task #{id}" if open.nil?

      open["finished_at"] = timestamp
      open["outcome"] = outcome.to_s
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_task(record)
    end

    # -> [Task] com um dos status dados. Varredura O(n) do boot;
    # aceitável (um nó, SQLite local).
    def with_status(*statuses)
      wanted = statuses.flatten
      @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
        record = @store.get(SCOPE, key)
        next if record.nil?

        task = to_task(record)
        task if wanted.include?(task.status)
      end
    end

    # Interrompidas (crash no meio do turno): têm checkpoint -> resume.
    def running_or_interrupted = with_status(:running, :waiting, :paused)

    # Enfileiradas mas nunca iniciadas (turno na fila do SessionActor no
    # crash) — sem checkpoint; recuperar = RODAR do zero (Recovery/ResumeTask).
    def queued = with_status(:queued)

    # -> enumera ids sem o prefixo "task:"; sem bloco retorna Enumerator.
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

    # NotFoundError se ausente (task inexistente -> 404). StoreError do
    # backend propaga sem re-embrulhar.
    def fetch!(id)
      record = @store.get(SCOPE, key_for(id))
      raise Harness::NotFoundError, "task inexistente: #{id}" if record.nil?

      record
    end

    # A Execution aberta é a última com finished_at nil (um dono por task, então
    # há no máximo uma). Devolve o Hash cru (mutável in-place para o RMW).
    def open_execution(record)
      last = record["executions"].last
      last if last && last["finished_at"].nil?
    end

    def close_open_execution(record, outcome:, error:)
      open = open_execution(record)
      return if open.nil? # sem tentativa aberta: nada onde gravar

      open["finished_at"] = timestamp
      open["outcome"] = outcome
      open["error"] = deep_stringify(error)
    end

    # Materializa Task a partir do Hash cru (normalização de tipos na borda):
    # `status` volta como Symbol (enum de domínio, comparado contra
    # STATUSES); `command`/`mailbox_state`/`error` ficam Hash de chaves string
    # (são dados, não enum).
    def to_task(record)
      Task.new(
        id: record["id"],
        status: record["status"].to_sym,
        command: record["command"],
        session_id: record["session_id"],
        executions: record["executions"].map { |e| to_execution(e) },
        mailbox_state: record["mailbox_state"],
        claimed_by: record["claimed_by"],
        claim_expires_at: record["claim_expires_at"],
        created_at: record["created_at"],
        updated_at: record["updated_at"]
      )
    end

    def to_execution(hash)
      Execution.new(
        attempt: hash["attempt"],
        started_at: hash["started_at"],
        finished_at: hash["finished_at"],
        outcome: hash["outcome"],
        error: hash["error"]
      )
    end

    def timestamp
      Time.now.utc.iso8601
    end

    # symbol->string na escrita, Ruby puro: chaves e valores Symbol viram String,
    # recursivo em Hash/Array; demais tipos passam intactos (o backend rejeita
    # não-JSONable).
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
