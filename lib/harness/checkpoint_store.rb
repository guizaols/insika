# frozen_string_literal: true

require "time"

module Harness
  # Store de domínio dos checkpoints. Snapshot por turno gravado
  # em transação ALL-OR-NOTHING (invariante: um checkpoint é válido inteiro
  # ou não existe), registro de side-effects não-idempotentes em chave avulsa
  # durante o turno, e `prune` para conter crescimento.
  #
  # Duas famílias de chave no scope "checkpoints":
  #   "checkpoint:<task_id>:turn:<n>"  -> JSON do Checkpoint
  #   "sideeffects:<task_id>:turn:<n>" -> ["tool_call_id", ...] (chave avulsa)
  #
  # A chave avulsa existe porque o checkpoint do turno ainda não existe quando
  # as tool calls rodam (ele só é salvo no estágio 8): ela é escrita ANTES de o
  # resultado da tool voltar ao modelo, e o `save` seguinte a
  # consolida em `completed_side_effects` e a apaga na MESMA transação.
  class CheckpointStore
    SCOPE = "checkpoints"

    def initialize(store:)
      @store = store
    end

    # -> Checkpoint (com a lista de side-effects consolidada). SEMPRE em
    # transação. Ordem: valida monotonicidade -> consolida a chave avulsa
    # do turno anterior -> grava o checkpoint -> apaga a chave avulsa absorvida.
    # Qualquer exceção no meio -> rollback total (nem checkpoint parcial, nem
    # chave avulsa perdida).
    def save(checkpoint)
      @store.transaction do
        current = latest(checkpoint.task_id)
        if current && current.turn >= checkpoint.turn
          raise ArgumentError,
                "checkpoint com turn não-monotônico: #{checkpoint.turn} <= #{current.turn}"
        end

        # O estágio 8 do turno n salva o checkpoint do turno n+1:
        # a chave avulsa a absorver é a do turno que acabou de executar (n).
        spill_key = sideeffects_key(checkpoint.task_id, checkpoint.turn - 1)
        spilled = @store.get(SCOPE, spill_key) || []
        consolidated = Array(checkpoint.completed_side_effects).map(&:to_s) | spilled

        record = deep_stringify(checkpoint.to_h)
        record["completed_side_effects"] = consolidated
        record["created_at"] ||= timestamp
        @store.set(SCOPE, checkpoint_key(checkpoint.task_id, checkpoint.turn), record)
        @store.delete(SCOPE, spill_key)

        to_checkpoint(record)
      end
    end

    # -> Checkpoint | nil (maior turn). Ordenação NUMÉRICA: `list` ordena
    # lexicograficamente e "turn:9" > "turn:10" — parsear o n como Integer.
    def latest(task_id)
      turns = checkpoint_turns(task_id)
      return nil if turns.empty?

      find(task_id, turn: turns.max)
    end

    # -> Checkpoint | nil
    def find(task_id, turn:)
      record = @store.get(SCOPE, checkpoint_key(task_id, turn))
      record && to_checkpoint(record)
    end

    # -> nil; idempotente (registrar duas vezes = uma entrada). Em transação
    # (escrita antes de a tool voltar ao modelo).
    def record_side_effect(task_id, turn:, tool_call_id:)
      @store.transaction do
        key = sideeffects_key(task_id, turn)
        ids = @store.get(SCOPE, key) || []
        id = tool_call_id.to_s
        @store.set(SCOPE, key, ids + [id]) unless ids.include?(id)
      end
      nil
    end

    # -> [tool_call_id] = chave avulsa ∪ checkpoint do mesmo turno.
    # Cobre os dois lugares onde um id pode estar durante o ciclo; como
    # tool_call_id é globalmente único, a união nunca causa skip indevido.
    def side_effects(task_id, turn:)
      spilled = @store.get(SCOPE, sideeffects_key(task_id, turn)) || []
      from_checkpoint = find(task_id, turn: turn)&.completed_side_effects || []
      spilled | from_checkpoint
    end

    # -> void. Mantém os `keep` checkpoints de maior turn (numérico); apaga o
    # resto. Também limpa chaves avulsas de turnos estritamente menores que o
    # menor turn mantido (lixo inatingível após a consolidação). Em transação
    # para não deixar poda parcial. No-op se houver <= keep checkpoints.
    def prune(task_id, keep: 1)
      @store.transaction do
        turns = checkpoint_turns(task_id).sort
        next if turns.size <= keep

        kept = turns.last(keep)
        smallest_kept = kept.first
        (turns - kept).each { |n| @store.delete(SCOPE, checkpoint_key(task_id, n)) }
        sideeffect_turns(task_id).each do |n|
          @store.delete(SCOPE, sideeffects_key(task_id, n)) if n < smallest_kept
        end
      end
      nil
    end

    private

    def checkpoint_key(task_id, turn)
      "checkpoint:#{task_id}:turn:#{turn}"
    end

    def sideeffects_key(task_id, turn)
      "sideeffects:#{task_id}:turn:#{turn}"
    end

    def checkpoint_turns(task_id)
      @store.list(SCOPE, "checkpoint:#{task_id}:turn:").map { |k| turn_of(k) }
    end

    def sideeffect_turns(task_id)
      @store.list(SCOPE, "sideeffects:#{task_id}:turn:").map { |k| turn_of(k) }
    end

    # O n é o último segmento da chave "...:turn:<n>"; parsear como Integer.
    def turn_of(key)
      key.split(":").last.to_i
    end

    # Materializa na borda: `turn` como Integer; demais campos como vêm do
    # backend (chaves string em `messages`).
    def to_checkpoint(record)
      Checkpoint.new(
        task_id: record["task_id"],
        turn: record["turn"].to_i,
        session_id: record["session_id"],
        agent_id: record["agent_id"],
        messages: record["messages"],
        completed_side_effects: record["completed_side_effects"],
        created_at: record["created_at"]
      )
    end

    def timestamp
      Time.now.utc.iso8601
    end

    # symbol->string na escrita, Ruby puro: chaves e valores Symbol viram String,
    # recursivo em Hash/Array; demais tipos (incl. Integer de `turn`) passam
    # intactos.
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
