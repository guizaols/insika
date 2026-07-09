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
      # NB: contra o TaskStore real (task 06), `transition` com `error:` JÁ fecha
      # a Execution aberta (finished_at/outcome/error) — por isso NÃO chamamos
      # finish_execution aqui (seria dupla-fecho -> ArgumentError). No caminho
      # de :cancelled, transition é sem `error:`, então lá o finish é necessário.
      @task_store.transition(task.id, to: :failed,
                                      error: { class: e.class.name, message: e.message })
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

    # --- Estágios 5-7: cola RubyLLM migrada INTACTA do runner.rb da Fase 0
    # (doc 03 §4.2, restrição "RubyLLM First"). Loop/streaming/retry nunca são
    # reimplementados aqui — só o entorno vira estágios.

    # Estágio 6 (fábrica): ÚNICO ponto que toca a gem (D9). require lazy,
    # confinado — não coberto por unit (linha de fábrica); a task 12 o exercita
    # com a gem/stub presente.
    def create_chat(profile)
      require "ruby_llm"
      require_relative "tools/load_skill"
      RubyLLM.chat(
        model: profile.model,
        provider: profile.provider,
        assume_model_exists: !profile.provider.nil?
      )
    end

    # Estágio 5: monta o chat com o contexto (estágio 2) e as tools da Resolution
    # (estágio 3). `state` é o TurnState (classe na task 12; specs usam Struct).
    def configure_chat(chat, state)
      system = state.context.system.to_s
      chat.with_instructions(system) unless system.empty?

      # load_skill é default de SISTEMA (fora da allowlist), senão o progressive
      # disclosure quebra — comportamento preservado da Fase 0. allowed_skills
      # vem da RESOLUTION (policy), não do provider de contexto.
      tools = Array(state.allowed_tools).dup
      skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
      tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?
      chat.with_tools(*tools) unless tools.empty?

      chat
    end

    # Estágio 5: histórico vem do contexto/checkpoint. O shape {role:, content:}
    # é o mesmo que a Fase 0 consome; tolera chaves string (JSON dos stores).
    def seed_history(chat, messages)
      Array(messages).each do |m|
        chat.add_message(role: (m[:role] || m["role"]).to_sym,
                         content: m[:content] || m["content"])
      end
    end

    # Estágio 7: callbacks aditivos do RubyLLM viram eventos com meta (D5).
    # load_skill vira :skill_activated — inalterado da Fase 0. Acrescenta o
    # contador max_tool_calls (doc 03 §6/L6): o loop é do RubyLLM; aqui só
    # CONTAMOS e abortamos.
    def wire_callbacks(chat, state)
      tool_calls = 0
      max_tool_calls = state.profile.limits[:max_tool_calls] || 50 # D6
      last_tool_name = nil

      chat.before_tool_call do |tool_call|
        tool_calls += 1
        if tool_calls > max_tool_calls
          raise Harness::TimeoutError.new("limite de tool calls excedido (#{max_tool_calls})",
                                          stage: :tool_limit)
        end

        last_tool_name = tool_call.name.to_s
        if last_tool_name == "load_skill"
          args = tool_call.arguments || {}
          emit(:skill_activated, { name: args["name"] || args[:name] }, task: state.task)
        else
          emit(:tool_call, { name: tool_call.name, arguments: tool_call.arguments }, task: state.task)
        end
      end

      chat.after_tool_result do |result|
        emit(:tool_result, { name: last_tool_name, result: result.to_s }, task: state.task)
      end
    end

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
