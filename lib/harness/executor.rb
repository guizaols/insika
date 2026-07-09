# frozen_string_literal: true

require "time"

module Harness
  # Coordena a execução. Não monta contexto, não decide policy, não fala com o
  # provider (doc 03 §1). Este arquivo NÃO requer ruby_llm em load-time (D9) —
  # o require é lazy dentro dos métodos de chat (task 11).
  #
  # Esqueleto (task 10): entorno dos estágios — spawn, lifecycle de estados
  # (sempre via TaskStore, doc 02 L1), drain de mailbox nas fronteiras, registro
  # in-process de fibers vivos (running?) e o emissor com meta D5 + seq. O miolo
  # (run_pipeline) é stub até as tasks 11 (estágios 6-7) e 12 (2-9).
  class Executor
    def initialize(context_builder:, policy_engine:, middleware:, hooks:,
                   tool_registry:, skill_catalog:, profiles:,
                   session_store:, task_store:, checkpoint_store:,
                   event_stream:)
      @context_builder = context_builder
      @policy_engine = policy_engine
      @middleware = middleware
      @hooks = hooks
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      @profiles = profiles
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @running = {}            # task_id => TaskActor (fibers vivos neste processo)
      @seqs = Hash.new(0)      # contador monotônico por task (D5)
    end

    # Registro in-process de fibers vivos (critério do ResumeTask, doc 03 §3).
    def running?(task_id) = @running.key?(task_id)

    # Ponto de acesso do CancelTask (task 9): posta :cancel se há fiber vivo.
    # No-op idempotente se não há (terminal/órfã). Retorna se havia fiber.
    def cancel(task_id)
      actor = @running[task_id]
      actor&.post(:cancel)
      !actor.nil?
    end

    # Estágio 1 (parte assíncrona): cria o actor, registra e dispara o fiber.
    # Chamado pelos handlers de turno (SendMessage/ResumeTask/TriggerWorkflow).
    def spawn(task, profile:, resume_from: nil)
      raise Harness::ValidationError, "task já em execução: #{task.id}" if running?(task.id)

      actor = TaskActor.new(task_id: task.id)
      @running[task.id] = actor
      actor.run { execute(task, profile: profile, resume_from: resume_from, actor: actor) }
      task.id
    end

    # Estágios 2..9. Roda DENTRO do fiber da task (doc 03 §2).
    def execute(task, profile:, actor:, resume_from: nil)
      @task_store.begin_execution(task.id)
      # running->running é inválido (doc 02 §2): só transiciona quando queued.
      # No resume (task 13), paused/waiting->running é feito pelo caminho de resume.
      @task_store.transition(task.id, to: :running) if @task_store.find(task.id).status == :queued
      emit(:task_started, { task_id: task.id, command: command_type(task) }, task: task)

      actor.drain!
      run_pipeline(task, profile, actor, resume_from) # stub nesta task
      # (caminho de sucesso completo — transition/persistência — chega na task 12)
    rescue CancelledError
      @task_store.transition(task.id, to: :cancelled)
      @task_store.finish_execution(task.id, outcome: :cancelled)
      emit(:task_cancelled, { task_id: task.id }, task: task)
    rescue StandardError => e
      # Esqueleto: rescue genérico p/ o fiber nunca vazar exceção. O mapeamento
      # COMPLETO erro->estado->eventos (D4/L3) chega na task 12.
      @task_store.transition(task.id, to: :failed,
                                      error: { class: e.class.name, message: e.message })
      @task_store.finish_execution(task.id, outcome: :failed)
      emit(:task_failed, { task_id: task.id, error: e.class.name, message: e.message }, task: task)
    ensure
      @running.delete(task.id) # SEMPRE desregistra (falso-positivo de running? quebraria o resume)
    end

    private

    # command foi normalizado a chaves string pelo TaskStore; aceitar símbolo
    # também por robustez.
    def command_type(task)
      task.command[:type] || task.command["type"]
    end

    # Preenchido nas tasks 11 (estágios 6-7) e 12 (2-9). Nos specs desta task é
    # stubado para simular sucesso/lentidão/erro.
    def run_pipeline(_task, _profile, _actor, _resume_from) = nil

    # Emissor único: Event com meta D5 e seq monotônico por task. @seqs não é
    # limpo ao fim da task — o resume (nova Execution) continua a numeração
    # (replay confiável, D5).
    def emit(type, data, task:)
      @event_stream.emit(Harness::Event.new(
                           type: type, data: data,
                           meta: { task_id: task.id, session_id: task.session_id,
                                   seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
