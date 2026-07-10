# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Store de domínio das AÇÕES PENDENTES de aprovação (P2-02, D2: "estado como
  # record, não flag"). Uma tool marcada `approval` (Policy) cria um
  # PendingAction e o turno vai a :waiting; o operador resolve via ApproveAction.
  # Durável (sobre um Harness::Store injetado): sobrevive a kill -9 — o operador
  # aprova depois do reboot, e o Recovery reidrata a task em :waiting.
  #
  # Normaliza symbol→string na ESCRITA (o backend só garante round-trip de tipos
  # JSON, doc 01 §2), como os demais stores de domínio da Fase 1.
  class PendingActionStore
    SCOPE = "pending_actions"
    KEY_PREFIX = "pending:"

    STATUSES = %i[pending approved rejected].freeze

    PendingAction = Data.define(:id, :task_id, :turn, :tool, :args,
                                :status, :requested_at, :resolved_by, :resolved_at)

    def initialize(store:)
      @store = store
    end

    # -> PendingAction (:pending). `args` é o Hash de argumentos da tool call.
    def create(task_id:, turn:, tool:, args: {}, id: SecureRandom.uuid)
      record = {
        "id" => id.to_s,
        "task_id" => task_id.to_s,
        "turn" => turn,
        "tool" => tool.to_s,
        "args" => deep_stringify(args),
        "status" => "pending",
        "requested_at" => timestamp,
        "resolved_by" => nil,
        "resolved_at" => nil
      }
      @store.set(SCOPE, key_for(id), record)
      to_pending(record)
    end

    # -> PendingAction | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_pending(record)
    end

    # -> [PendingAction] :pending da task (recovery/UI). Scan O(n) — single-node,
    # Fase 1/2 (doc 01 §5), igual TaskStore#running_or_interrupted.
    def open_for(task_id)
      id = task_id.to_s
      @store.list(SCOPE, KEY_PREFIX).filter_map do |key|
        record = @store.get(SCOPE, key)
        next if record.nil?

        pa = to_pending(record)
        pa if pa.status == :pending && pa.task_id == id
      end
    end

    # -> PendingAction resolvida. Só resolve :pending (edge 1): dupla resolução
    # ou decision inválida -> ValidationError; ausente -> NotFoundError.
    def resolve(id, decision:, operator: nil)
      target = decision.to_sym
      unless %i[approved rejected].include?(target)
        raise Harness::ValidationError, "decision inválida: #{decision} (approved|rejected)"
      end

      record = @store.get(SCOPE, key_for(id)) ||
               (raise Harness::NotFoundError, "pending action inexistente: #{id}")
      unless record["status"] == "pending"
        raise Harness::ValidationError, "pending action '#{id}' já resolvida (#{record["status"]})"
      end

      record["status"] = target.to_s
      record["resolved_by"] = operator&.to_s
      record["resolved_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_pending(record)
    end

    private

    def key_for(id) = "#{KEY_PREFIX}#{id}"

    def to_pending(record)
      PendingAction.new(
        id: record["id"],
        task_id: record["task_id"],
        turn: record["turn"],
        tool: record["tool"],
        args: record["args"],
        status: record["status"].to_sym,
        requested_at: record["requested_at"],
        resolved_by: record["resolved_by"],
        resolved_at: record["resolved_at"]
      )
    end

    def timestamp = Time.now.utc.iso8601

    def deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
  end
end
