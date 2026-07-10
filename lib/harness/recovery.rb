# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Chamado UMA vez no boot, ANTES de aceitar requests (doc 07 §4). Descobre
  # tasks interrompidas e despacha a retomada pelo MESMO caminho do ResumeTask
  # (D3) — este componente não executa nada, não abre Execution, não muda o
  # status das tasks retomáveis. Só descoberta + dispatch + marcação de
  # irrecuperáveis (doc 02 §4).
  #
  # Durabilidade sem job runner externo (restrição 4, doc 00 §5) = stores +
  # recovery no boot. A metade "execução" é o handler ResumeTask (task 13).
  #
  # `command_bus` é consumido só pelo contrato `dispatch(command)`; até a task 13
  # os testes injetam um duplo que grava os dispatches (doc 02 §7).
  class Recovery
    # checkpoint_store: necessário para consultar `latest` (o doc 02 §2 lista só
    # task_store/command_bus, mas o fluxo do §4 usa checkpoint_store — lacuna do
    # techspec, registrada nas Notes da task). logger opcional (default nil ->
    # silencioso em teste).
    def initialize(task_store:, checkpoint_store:, command_bus:, logger: nil)
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @command_bus = command_bus
      @logger = logger
    end

    # -> { resumed: [ids], failed: [ids] }
    # A varredura inicial roda FORA do rescue por-task: StoreError aqui aborta
    # o boot (doc 02 §6).
    def run
      resumed = []
      failed = []
      # Ordena por created_at (P2-03 L5): tasks da MESMA sessão são reprocessadas
      # na ordem original. Ordem global por tempo é inofensiva p/ tasks avulsas.
      # 1) interrompidas (crash no meio) -> resume do checkpoint.
      @task_store.running_or_interrupted.sort_by(&:created_at).each { |task| process(task, resumed, failed) }
      # 2) enfileiradas nunca iniciadas (turno na fila do SessionActor no crash,
      #    P2-03) -> re-run do zero (o mesmo resume_task trata :queued). Sem isso,
      #    um turno :queued na fila volátil seria perdido no kill -9.
      @task_store.queued.sort_by(&:created_at).each { |task| process(task, resumed, failed) }
      log(:info, "recovery concluído: #{resumed.size} retomadas, #{failed.size} falhas")
      { resumed: resumed, failed: failed }
    end

    private

    # Falha ao retomar UMA task não derruba o boot: dispatch/latest não-store ->
    # marca :failed e segue. StoreError -> propaga (aborta o boot).
    def process(task, resumed, failed)
      # :queued nunca iniciou (sem checkpoint) mas É recuperável — o ResumeTask
      # re-roda do Command. Interrompida exige checkpoint; sem ele, irrecuperável.
      if task.status == :queued || @checkpoint_store.latest(task.id)
        @command_bus.dispatch(resume_command(task.id))
        resumed << task.id
        log(:info, "resume despachado: #{task.id}")
      else
        fail_task(task.id, class_name: "Harness::Error",
                           message: "irrecuperável: sem checkpoint")
        failed << task.id
        log(:warn, "irrecuperável (sem checkpoint): #{task.id}")
      end
    rescue Harness::StoreError
      raise
    rescue StandardError => e
      fail_task(task.id, class_name: e.class.name, message: e.message, stage: "recovery")
      failed << task.id unless failed.include?(task.id)
      log(:warn, "falha ao retomar #{task.id}: #{e.class}: #{e.message}")
    end

    # Transiciona a task para :failed gravando o erro na Execution aberta (se
    # houver). StoreError propaga (aborta o boot). ArgumentError é absorvido:
    # `paused -> failed` não está na máquina (doc 02 §2) — a task permanece no
    # estado atual, mas ainda a reportamos como failed no sumário. Lacuna do
    # techspec (Notes); não "consertar" a máquina aqui.
    def fail_task(id, class_name:, message:, stage: nil)
      error = { class: class_name, message: message }
      error[:stage] = stage if stage
      @task_store.transition(id, to: :failed, error: error)
    rescue Harness::StoreError
      raise
    rescue ArgumentError
      nil
    end

    def resume_command(task_id)
      # transport: :recovery identifica a origem (boot) no meta — auditoria
      # (o campo é Symbol livre, doc 03 §2). Usa o factory da task 09.
      Harness::Command.build(:resume_task, { task_id: task_id }, transport: :recovery)
    end

    # Log é observabilidade pura: uma falha do logger NUNCA pode alterar o
    # fluxo do recovery (senão um logger com bug corromperia o sumário —
    # ex.: id em resumed E failed). Engolimos qualquer erro do logger.
    def log(level, message)
      @logger&.public_send(level, "[recovery] #{message}")
    rescue StandardError
      nil
    end
  end
end
