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
      # Resume de órfã de crash: a Execution do attempt interrompido ficou ABERTA
      # (o fiber morreu). O TaskStore proíbe abrir uma segunda enquanto há aberta
      # -> fecha a órfã como :interrupted antes de abrir a N+1 (doc 02 §3: nova
      # entrada, nunca sobrescreve). Ver Notes da task.
      close_orphan_execution(task) if resume_from
      @task_store.begin_execution(task.id) # attempt N+1 (doc 02 §3)
      # queued (spawn normal) e paused/waiting (resume) -> running. Órfã já está
      # :running (running->running é inválido, doc 02 §2) -> sem transição.
      status = @task_store.find(task.id).status
      @task_store.transition(task.id, to: :running) if %i[queued paused waiting].include?(status)
      emit(:task_started, { task_id: task.id, command: command_type(task) }, task: task)

      actor.drain!
      run_pipeline(task, profile, actor, resume_from)
    # Captura ÚNICA no topo do fiber (doc 03 §6/L3): um só lugar mapeia
    # erro -> estado terminal -> eventos. Estágios não fazem rescue próprio
    # (exceto tool, semântica RubyLLM). O fiber NUNCA re-raise.
    rescue CancelledError
      # cancel não é erro: transition SEM error: (não fecha a Execution), depois
      # finish_execution a fecha com outcome :cancelled.
      @task_store.transition(task.id, to: :cancelled)
      @task_store.finish_execution(task.id, outcome: :cancelled)
      emit(:task_cancelled, { task_id: task.id }, task: task)
      emit(:error, { message: "task cancelada" }, task: task) # compat Fase 0 (D5)
    rescue PolicyDenied => e
      emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task) # D5
      fail_task(task, e, stage: :policy)
    rescue ContextError => e
      fail_task(task, e, stage: :context)
    rescue ProviderError => e
      fail_task(task, e, stage: :ruby_llm)
    rescue StoreError => e
      fail_task(task, e, stage: :persistence)
    rescue TimeoutError => e
      fail_task(task, e, stage: e.stage)
    rescue StandardError => e
      fail_task(task, e, stage: :unknown)
    ensure
      @running.delete(task.id) # SEMPRE desregistra (falso-positivo de running? quebraria o resume)
    end

    private

    # command foi normalizado a chaves string pelo TaskStore; aceitar símbolo
    # também por robustez.
    def command_type(task)
      task.command[:type] || task.command["type"]
    end

    # Fecha a Execution órfã (aberta) de um attempt interrompido por crash,
    # marcando-a :interrupted — o registro do que aconteceu é preservado; o
    # attempt N+1 é aberto em seguida por begin_execution.
    def close_orphan_execution(task)
      open = @task_store.find(task.id).executions.last
      @task_store.finish_execution(task.id, outcome: :interrupted) if open && open.finished_at.nil?
    end

    # Mapeia erro -> task :failed + eventos. `transition` com error: JÁ fecha a
    # Execution aberta (TaskStore real, task 06) — NÃO chamar finish_execution
    # (dupla-fecho). Checkpoint anterior NUNCA é tocado em falha (D4). Nunca
    # re-raise: o fiber morre limpo (doc 03 §6).
    def fail_task(task, error, stage:)
      # Defense-in-depth: se a task já é terminal (ex.: falha em cleanup APÓS
      # transition(:completed)), completed->failed é inválido e levantaria
      # ArgumentError DENTRO do rescue, vazando do fiber. Nesse caso só reporta
      # o erro — a durabilidade do turno commitado é preservada.
      current = @task_store.find(task.id)
      if current && TERMINAL_STATUSES.include?(current.status)
        emit(:error, { message: error.message }, task: task)
        return nil
      end

      @task_store.transition(task.id, to: :failed,
                                      error: { class: error.class.name, message: error.message, stage: stage })
      emit(:task_failed, { task_id: task.id, error: error.class.name, message: error.message }, task: task)
      emit(:error, { message: error.message }, task: task) # compat Fase 0 (D5)
      nil
    end

    TERMINAL_STATUSES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATUSES

    # Correlação call<->execução p/ side-effects/skip (interno; doc 03 §3 Notes).
    ContextRequest = Struct.new(:task, :profile, :message, :session, :history, :checkpoint,
                                keyword_init: true)
    PolicyRequest  = Struct.new(:profile, :task, :candidate_skills, keyword_init: true)

    # Estágios 2-9 (doc 03 §4), com drain de mailbox só nas fronteiras (L2) e
    # turn-timeout (D4) envolvendo tudo via Async::Task#with_timeout — NUNCA
    # Timeout.timeout da stdlib.
    def run_pipeline(task, profile, actor, resume_from)
      turn = resume_from ? resume_from.turn : 1
      state = TurnState.new(task: task, profile: profile, turn: turn,
                            message: extract_message(task))
      turn_timeout = profile.limits[:turn_timeout] || 300 # D4/D6

      Async::Task.current.with_timeout(turn_timeout) do
        # estágio 2: Context
        request = build_context_request(task, profile, state, resume_from)
        state.context = @hooks.around(:prompt, request) { |req| @context_builder.call(req) }
        actor.drain!

        # estágio 3: Policy (candidate_skills vêm do CATÁLOGO, não do contexto)
        resolution = @policy_engine.decide(policy_request(profile, task))
        # no resume, tool calls já concluídas no turno interrompido são "puladas"
        # (doc 02 L5): união chave avulsa ∪ checkpoint do turno.
        skip = resume_from ? @checkpoint_store.side_effects(task.id, turn: state.turn) : []
        state.allowed_tools = wrap_tools(Array(resolution.allowed_tools), state, skip)
        state.allowed_skills = resolution.allowed_skills
        actor.drain!

        # estágio 4: Middleware (pode curto-circuitar setando halt_reason)
        @middleware.call(state) do |st|
          raise Harness::Error, "turno interrompido: #{st.halt_reason}" if st.halt_reason

          # estágio 5: montar chat + checar mailbox
          actor.drain!
          st.chat = create_chat(profile)
          configure_chat(st.chat, st)
          seed_history(st.chat, st.context.history)
          wire_callbacks(st.chat, st) # estágio 7

          # estágio 6: RubyLLM — ÚNICA interação com o modelo
          response = @hooks.around(:agent, st) do |s|
            s.chat.ask(s.message) do |chunk|
              emit(:content, { delta: chunk.content }, task: task) if chunk.content
            end
          end

          # estágio 8: Persistence (ordem fixa checkpoint->session->task, doc 02 L4)
          actor.drain! # nunca DURANTE o estágio 8 (D4)
          persist_turn(task, profile, st, response)

          # estágio 9: Response
          emit(:done, { content: response.content }, task: task) # compat Fase 0
          emit(:task_completed, { task_id: task.id, content: response.content }, task: task)
        end

        # halt sem executar o bloco terminal também é falha (doc 05 §4)
        raise Harness::Error, "turno interrompido: #{state.halt_reason}" if state.halt_reason
      end
    rescue Async::TimeoutError
      raise Harness::TimeoutError.new("turno excedeu #{turn_timeout}s", stage: :turn)
    end

    def extract_message(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["message"] || payload[:message]
    end

    def command_history(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["history"] || payload[:history]
    end

    def build_context_request(task, profile, state, resume_from)
      session = task.session_id ? @session_store.find(task.session_id) : nil
      ContextRequest.new(task: task, profile: profile, message: state.message,
                         session: session, history: command_history(task),
                         checkpoint: resume_from)
    end

    def policy_request(profile, task)
      PolicyRequest.new(profile: profile, task: task,
                        candidate_skills: @skill_catalog.effective(profile.skills))
    end

    # Envelopa cada tool permitida (timeout por call + registro de side-effect,
    # doc 03 §5). A LoadSkill de sistema (configure_chat) NÃO é envelopada nesta
    # fase — é tool de sistema sem side-effect e de latência trivial (ver Notes).
    def wrap_tools(tools, state, skip_side_effects = [])
      timeout = state.profile.limits[:tool_timeout] || 60 # D4/D6
      tools.map do |tool|
        ToolEnvelope.new(tool, state: state, checkpoint_store: @checkpoint_store,
                               tool_registry: @tool_registry, timeout: timeout,
                               skip_side_effects: skip_side_effects)
      end
    end

    # Estágio 8: ordem FIXA checkpoint -> session -> task (doc 02 L4). Se cair
    # entre escritas, o pior caso é checkpoint novo com task :running -> Recovery
    # reexecuta o turno já salvo (seguro pelo registro de side-effects).
    def persist_turn(task, profile, state, response)
      new_messages = [
        { role: "user", content: state.message },
        { role: "assistant", content: response.content }
      ]
      transcript = Array(state.context.history) + new_messages

      @checkpoint_store.save(Harness::Checkpoint.new(
                               task_id: task.id, turn: state.turn + 1, session_id: task.session_id,
                               agent_id: profile.id, messages: transcript,
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))

      # sessão só quando o turno é de sessão persistida (D2); one-shot/history
      # não persistem NA SESSÃO (mas sempre checkpointam).
      @session_store.append_messages(task.session_id, new_messages) if task.session_id

      # finish_execution (fecha a Execution) ANTES do transition(:completed) —
      # transition sem error: não fecha, então o finish é necessário aqui.
      @task_store.finish_execution(task.id, outcome: :completed)
      @task_store.transition(task.id, to: :completed)
      # prune é cleanup best-effort (L6): uma falha aqui NÃO pode re-falhar um
      # turno já commitado (a task já é :completed e durável). Swallow.
      begin
        @checkpoint_store.prune(task.id, keep: 1)
      rescue Harness::StoreError
        nil
      end

      emit(:checkpoint_created, { task_id: task.id, turn: state.turn + 1 }, task: task)
    end

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
        # correlação call<->decorator (side-effects/skip, task 13) — 1ª linha.
        state.current_tool_call = tool_call
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
