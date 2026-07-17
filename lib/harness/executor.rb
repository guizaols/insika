# frozen_string_literal: true

require "time"
require "async/queue"

module Harness
  # Coordena a execução. Não monta contexto, não decide policy, não fala com o
  # provider. Este arquivo NÃO requer ruby_llm em load-time —
  # o require é lazy dentro dos métodos de chat.
  #
  # Entorno dos estágios: spawn, lifecycle de estados
  # (sempre via TaskStore), drain de mailbox nas fronteiras, registro
  # in-process de fibers vivos (running?) e o emissor com meta + seq.
  class Executor
    def initialize(context_builder:, policy_engine:, middleware:, hooks:,
                   tool_registry:, skill_catalog:, profiles:,
                   session_store:, task_store:, checkpoint_store:,
                   event_stream:, workflow_registry: nil, pending_action_store: nil,
                   capability_registry: nil, tool_catalog: nil, memory_store: nil,
                   tool_trace_store: nil)
      @context_builder = context_builder
      @policy_engine = policy_engine
      @middleware = middleware
      @hooks = hooks
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      # Hash legado -> StaticProfileSource; um ProfileSource passa direto.
      @profiles = ProfileSource.coerce(profiles)
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @workflow_registry = workflow_registry # estágio 6 do trigger_workflow
      @pending_action_store = pending_action_store # gate de aprovação
      @capability_registry = capability_registry # resolução de capability (nil = desligado)
      @tool_trace_store = tool_trace_store # trace de tool-calls p/ debug no Studio (nil = desligado)
      # Cola RubyLLM (estágios 5-7): montagem do chat delegada ao ChatBuilder. As
      # deps opcionais tool_catalog (Tool Search) e memory_store (memória
      # cross-session) só a ele importam — nil = paridade (deferred
      # não particionado; sem remember de sistema).
      @chat_builder = ChatBuilder.new(
        tool_registry: tool_registry, skill_catalog: skill_catalog,
        checkpoint_store: checkpoint_store, event_stream: event_stream, hooks: hooks,
        tool_catalog: tool_catalog, memory_store: memory_store
      )
      @running = {}            # task_id => TaskActor (fibers vivos neste processo)
      @seqs = Hash.new(0)      # contador monotônico por task
      @supervised = false      # modo serving? — ver #turn_parent
      @supervisor = nil        # supervisor lazy de vida-longa (criado no serving)
      @session_actors = {}     # session_id => SessionActor (fila FIFO)
    end

    # Liga o modo SERVING: a arm de serving do composition root (serve.rb /
    # config.ru) seta true APÓS o recovery. Sob HTTP o `spawn` roda no fiber
    # EFÊMERO da request; sem isso o turno seria filho dela e o runtime o
    # CANCELARIA no disconnect (viola o contrato: "a execução pertence ao runtime,
    # não à conexão"). Ligado, o turno nasce filho de um supervisor de vida-longa
    # (irmão do accept loop) e sobrevive à conexão. false (default) = parenteia
    # no fiber corrente: no recovery/boot e nos testes o dono QUER esperar o
    # turno terminar (concorrência estruturada).
    attr_accessor :supervised

    # Registro in-process de fibers vivos (critério do ResumeTask).
    def running?(task_id) = @running.key?(task_id)

    # Ponto de acesso do CancelTask: posta :cancel se há fiber vivo.
    # No-op idempotente se não há (terminal/órfã). Retorna se havia fiber.
    def cancel(task_id)
      actor = @running[task_id]
      actor&.post(:cancel)
      !actor.nil?
    end

    # Ponto de acesso do PauseTask: posta :pause se há fiber vivo; o turno
    # suspende na próxima fronteira (drain_and_maybe_suspend). No-op idempotente
    # se não há fiber. Retorna se havia fiber.
    def pause(task_id)
      actor = @running[task_id]
      actor&.post(:pause)
      !actor.nil?
    end

    # Ponto de acesso do ResumeTask para task IN-PROCESS pausada:
    # posta :resume no fiber vivo (que está bloqueado em await). Retorna se havia
    # fiber vivo — o handler decide entre resume in-process e re-dispatch de
    # crash conforme isso.
    def resume_live(task_id)
      actor = @running[task_id]
      actor&.post(:resume)
      !actor.nil?
    end

    # Ponto de acesso do ApproveAction: ACORDA o turno suspenso em
    # :waiting postando :approval no fiber vivo. A decisão já foi gravada no store
    # pelo handler ANTES deste post (request_approval a relê do store). No-op se
    # não há fiber vivo (processo caiu) — o recovery reexecuta e usa a decisão
    # durável. Retorna se havia fiber.
    def approve(task_id)
      actor = @running[task_id]
      actor&.post(:approval)
      !actor.nil?
    end

    # Gate de aprovação, chamado pelo ToolEnvelope no estágio 6 quando a
    # tool exige aprovação. Cria/consulta o PendingAction (id determinístico por
    # task+turn+tool — correlação por-tool como no side-effect),
    # suspende o turno em :waiting e BLOQUEIA (await(:approval)) até o operador
    # resolver via ApproveAction. A decisão AUTORITATIVA vem do store
    # durável (crash-safe): numa reexecução pós-crash, uma PendingAction já
    # resolvida é reusada sem re-suspender; uma :pending re-suspende.
    # -> "approved" | "rejected".
    def request_approval(task:, turn:, tool:, args:, actor:)
      # Fail-closed: exigir aprovação sem onde persistir/consultar a decisão é
      # misconfiguração — falha ALTO, nunca pendura nem auto-aprova.
      if @pending_action_store.nil?
        raise Harness::Error, "tool '#{tool}' exige aprovação mas PendingActionStore não está configurado"
      end

      id = pending_id(task.id, turn, tool)
      existing = @pending_action_store.find(id)
      return existing.status.to_s if existing && existing.status != :pending # reexecução: já resolvida

      unless existing
        @pending_action_store.create(id: id, task_id: task.id, turn: turn, tool: tool, args: args || {})
        emit(:approval_requested, { pending_id: id, tool: tool.to_s, args: args }, task: task)
      end

      @task_store.transition(task.id, to: :waiting) if @task_store.find(task.id).status == :running

      # Aguarda a resolução DESTE pending. Um :approval espúrio (duplicado ou de
      # outro pending do mesmo actor) que acorde antes de resolver é ignorado
      # (re-await) — fail-closed: só a resolução real deste id destrava.
      status = nil
      loop do
        actor.await(reason: :approval) # bloqueia (ou levanta em :cancel/:timeout)
        status = @pending_action_store.find(id)&.status
        break unless status == :pending
      end

      @task_store.transition(task.id, to: :running)
      (status || :rejected).to_s # fail-closed: record sumido -> rejeita (defensivo)
    end

    # Estágio 1 (parte assíncrona): cria o actor, registra e dispara o fiber.
    # Chamado pelos handlers de turno (SendMessage/ResumeTask/TriggerWorkflow).
    def spawn(task, profile:, resume_from: nil)
      raise Harness::ValidationError, "task já em execução: #{task.id}" if running?(task.id)

      actor = TaskActor.new(task_id: task.id, parent: turn_parent)
      @running[task.id] = actor
      actor.run { execute(task, profile: profile, resume_from: resume_from, actor: actor) }
      task.id
    end

    # Ponto de entrada de turno que RESPEITA a sessão: turno com
    # session_id é SERIALIZADO na fila do SessionActor daquela sessão (um por
    # vez); sem session_id (one-shot/history) vai direto ao spawn (avulso).
    def spawn_in_session(task, profile:, resume_from: nil)
      # SessionActor só no modo SERVING (@supervised): serializa REQUESTS
      # concorrentes. No boot/recovery (não-supervised) o replay é sequencial e
      # o loop de vida-longa penduraria o Sync do Boot — usa spawn direto (o
      # dono aguarda o turno). One-shot/history (sem session_id)
      # nunca serializa.
      unless @supervised && task.session_id
        return spawn(task, profile: profile, resume_from: resume_from)
      end

      session_actor(task.session_id).enqueue(task, profile: profile, resume_from: resume_from)
    end

    # Executa UM turno de forma serial (chamado pelo loop do SessionActor):
    # spawna (turno nasce filho do supervisor, não-bloqueante) e AGUARDA sua
    # conclusão antes de retornar — é o que serializa a sessão. Erro do turno já
    # é mapeado a estado terminal dentro do próprio fiber (captura única); aqui
    # só garantimos que o loop da sessão não morre.
    def run_serial(task, profile:, resume_from: nil)
      spawn(task, profile: profile, resume_from: resume_from)
      @running[task.id]&.wait
    rescue Async::Stop
      raise # shutdown: propaga (encerra o loop da sessão)
    rescue StandardError => e
      # Erro SÍNCRONO do spawn (antes do fiber): a captura única do execute não
      # age (o turno nunca rodou). Marca :failed aqui para NÃO orfanar a task
      # como :queued sem estado terminal nem evento (o cliente ficaria pendurado).
      fail_spawn(task, e)
    end

    # Encerra todos os SessionActors (shutdown do servidor / testes — o loop
    # bloqueia p/ sempre em dequeue quando ocioso).
    def stop_session_actors
      @session_actors.each_value(&:stop)
      @session_actors.clear
      nil
    end

    # Estágios 2..9. Roda DENTRO do fiber da task.
    def execute(task, profile:, actor:, resume_from: nil)
      # Resume de órfã de crash: a Execution do attempt interrompido ficou ABERTA
      # (o fiber morreu). O TaskStore proíbe abrir uma segunda enquanto há aberta
      # -> fecha a órfã como :interrupted antes de abrir a N+1 (nova
      # entrada, nunca sobrescreve).
      close_orphan_execution(task) if resume_from
      @task_store.begin_execution(task.id) # attempt N+1
      # queued (spawn normal) e paused/waiting (resume) -> running. Órfã já está
      # :running (running->running é inválido) -> sem transição.
      status = @task_store.find(task.id).status
      @task_store.transition(task.id, to: :running) if %i[queued paused waiting].include?(status)
      emit(:task_started, { task_id: task.id, command: command_type(task), agent: profile&.id }, task: task)

      actor.drain!
      run_pipeline(task, profile, actor, resume_from)
    # Captura ÚNICA no topo do fiber: um só lugar mapeia
    # erro -> estado terminal -> eventos. Estágios não fazem rescue próprio
    # (exceto tool, semântica RubyLLM). O fiber NUNCA re-raise.
    rescue CancelledError
      # cancel não é erro: transition SEM error: (não fecha a Execution), depois
      # finish_execution a fecha com outcome :cancelled.
      @task_store.transition(task.id, to: :cancelled)
      @task_store.finish_execution(task.id, outcome: :cancelled)
      emit(:task_cancelled, { task_id: task.id }, task: task)
      emit(:error, { message: "task cancelada" }, task: task) # compat legada
    rescue PolicyDenied => e
      emit(:policy_denied, { policy: e.policy, reason: e.reason }, task: task)
      fail_task(task, e, stage: :policy)
    rescue ContextError => e
      fail_task(task, e, stage: :context)
    rescue CapabilityError => e
      fail_task(task, e, stage: :capability)
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

    # SessionActor lazy por sessão, parenteado no escopo de turnos:
    # o loop da sessão sobrevive à conexão, como o supervisor. Revalida liveness:
    # se o loop cacheado morreu (supervisor recriado/parado), cria um novo — senão
    # os turnos enfileirados seriam black-holed num loop morto.
    def session_actor(session_id)
      existing = @session_actors[session_id]
      return existing if existing&.alive?

      @session_actors[session_id] =
        SessionActor.new(session_id: session_id, executor: self, parent: turn_parent)
    end

    # Marca :failed uma task cujo turno FALHOU no spawn (antes do fiber). Idempotente
    # contra estado terminal; StoreError re-levanta (o loop da sessão trata).
    def fail_spawn(task, error)
      current = @task_store.find(task.id)
      return if current.nil? || TERMINAL_STATUSES.include?(current.status)

      @task_store.transition(task.id, to: :failed,
                                      error: { class: error.class.name, message: error.message, stage: :spawn })
      emit(:task_failed, { task_id: task.id, error: error.class.name, message: error.message }, task: task)
      emit(:error, { message: error.message }, task: task)
    rescue Harness::Error
      nil
    end

    # Parent do fiber do turno. Não-serving: o fiber corrente (o dono espera
    # o turno). Serving: um supervisor de vida-longa criado lazy no BOUNDARY do
    # reactor — a task cujo parent é o próprio reactor (irmã do accept loop),
    # fora da subárvore de qualquer request. Assim o turno sobrevive ao stop da
    # request (disconnect). Um supervisor por Executor, reusado enquanto vivo.
    def turn_parent
      return Async::Task.current unless @supervised
      return @supervisor if @supervisor&.running?

      reactor = Async::Task.current.reactor
      node = Async::Task.current
      node = node.parent while node.parent && node.parent != reactor
      # Idle sem spin nem API deprecada (Async::Task#sleep é deprecated em 2.42):
      # bloqueia num dequeue que nunca chega. Só termina quando o escopo é parado
      # (shutdown do servidor) — aí os turnos-filhos vão junto (aceitável).
      @supervisor = node.async { |t| t.annotate("harness-turn-supervisor"); Async::Queue.new.dequeue }
    end

    # Id determinístico do PendingAction: correlação por task+turn+tool.
    # Limitação herdada do side-effect: a MESMA tool com aprovação mais
    # de uma vez no turno colide (a 2ª reusa a decisão da 1ª) — checkpoint por
    # passo é fatia futura. Uma call por tool é segura.
    def pending_id(task_id, turn, tool) = "#{task_id}:#{turn}:#{tool}"

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
    # Execution aberta (TaskStore real) — NÃO chamar finish_execution
    # (dupla-fecho). Checkpoint anterior NUNCA é tocado em falha. Nunca
    # re-raise: o fiber morre limpo.
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
      emit(:error, { message: error.message }, task: task) # compat legada
      nil
    end

    TERMINAL_STATUSES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATUSES

    # Estágios 2-9, com drain de mailbox só nas fronteiras e
    # turn-timeout envolvendo tudo via Async::Task#with_timeout — NUNCA
    # Timeout.timeout da stdlib.
    def run_pipeline(task, profile, actor, resume_from)
      turn = resume_from ? resume_from.turn : 1
      state = TurnState.new(task: task, profile: profile, turn: turn,
                            message: extract_message(task))
      state.tenant = memory_tenant(task) # escopo da memória do WRITE path (`remember`); =chat (D3)
      state.turn_context = build_turn_context(task, profile, state) # ctx.* das data-tools (D2/G4)
      turn_timeout = profile.limits[:turn_timeout] || 300
      # Turno que PODE exigir aprovação humana ganha budget = approval_timeout
      # (~1h): o with_timeout do turno não pode matar uma espera de operador
      # legítima. O runaway do LLM já é contido por max_tool_calls/max_turns.
      unless Array(profile.approvals_required).empty?
        turn_timeout = [turn_timeout, profile.limits[:approval_timeout] || 3_600].max
      end

      Async::Task.current.with_timeout(turn_timeout) do
        # par :task: envolve os estágios do turno. before_task pode
        # reescrever o TurnState antes do estágio 2; after_task roda após o 9.
        # O block-param `state` sombreia o externo (usa o TurnState possivelmente
        # reescrito pelo before_task). Subject == resultado == TurnState
        # (o content da Response vive no evento :done).
        @hooks.around(:task, state) do |state|
        # estágio 2: Context. O par de hooks :prompt é envolvido DENTRO do
        # ContextBuilder#call — NÃO envolver aqui (double-wrap
        # dispararia os hooks 2x). O Hooks é a MESMA instância injetada no
        # Builder e aqui (para :agent/:task/:tool).
        request = build_context_request(task, profile, state, resume_from)
        state.context = @context_builder.call(request)
        drain_and_maybe_suspend(task, actor)

        # checkpoint INICIAL do turno ("o checkpoint do turno n contém
        # o estado NO INÍCIO do turno n"). Sem ele, um crash no meio do estágio 6
        # (antes do estágio 8) deixaria a task órfã SEM checkpoint -> irrecuperável
        # (o Recovery a marcaria :failed). Idempotente: só grava no 1º turno de uma
        # task nova — no resume o checkpoint já existe (find != nil) e nos turnos
        # seguintes o checkpoint de fim do turno anterior já é o "início" deste.
        save_initial_checkpoint(task, profile, state)

        # sub-passo de resolução de capability: ENTRE Context e Policy.
        # Só preenche state.capability_names para a junção PÓS-Policy — o
        # policy_request abaixo NÃO muda (candidate_tools continua tool_registry.entries).
        state.capability_names = resolve_capabilities(profile, state.context)

        # estágio 3: Policy (candidate_skills vêm do CATÁLOGO, não do contexto;
        # candidate_tools = tool_registry.entries, SÓ tools diretas — inalterado)
        resolution = @policy_engine.decide(policy_request(profile, task, state))
        # no resume, tool calls já concluídas no turno interrompido são "puladas"
        # (união chave avulsa ∪ checkpoint do turno).
        skip = resume_from ? @checkpoint_store.side_effects(task.id, turn: state.turn) : []
        # propaga o `skip` às tools PROMOVIDAS pelo tool_search (mesma
        # resume-safety das eager); a builtin lê Array(state.skip_side_effects).
        state.skip_side_effects = skip
        # o Executor instancia SÓ as permitidas: o Engine real
        # devolve Entries -> factory.call; um fake que já devolve instâncias
        # passa direto (shim de compat).
        # fia o gate de aprovação no state (o ToolEnvelope lê no estágio 6).
        state.actor = actor
        state.approval_coordinator = self
        state.requires_approval = resolution.requires_approval
        state.allowed_tools = wrap_tools(assemble_tool_instances(resolution.allowed_tools, state), state, skip)
        state.allowed_skills = resolution.allowed_skills
        drain_and_maybe_suspend(task, actor)

        # estágio 4: Middleware envolve os estágios 5-9. O elo que
        # curto-circuita NÃO chama o terminal e seta state.halt_reason.
        terminal_ran = false
        @middleware.call(state) do |st|
          raise Harness::Error, "turno interrompido: #{st.halt_reason}" if st.halt_reason

          terminal_ran = true
          # estágio 5: montar chat + checar mailbox (só send_message; um workflow
          # não usa o chat do Harness — orquestra RubyLLM por dentro).
          drain_and_maybe_suspend(task, actor)
          unless workflow_turn?(task)
            st.chat = create_chat(profile)
            @chat_builder.assemble(st.chat, st, emit: ->(type, data) { emit(type, data, task: task) })
          end

          # estágio 6: única interação de agente do turno. send_message ->
          # chat.ask; trigger_workflow -> workflow.call(input, context:, tools:)
          # Ambos envoltos por hooks.around(:agent). O retorno é o
          # conteúdo final do turno.
          content = run_agent_stage(task, st)

          # estágio 8: Persistence (ordem fixa checkpoint->session->task)
          # drain! puro (NUNCA suspende no estágio 8 — janela proibida). Um
          # :pause que chegue aqui arma pause_requested mas NÃO é honrado: é o
          # último estágio, não há fronteira seguinte; o turno conclui e o flag é
          # descartado com o actor. Corrida benigna: pausa perde p/ a conclusão
          # (o operador vê a task :completed). :cancel aqui ainda levanta.
          actor.drain!
          persist_turn(task, profile, st, content)

          # estágio 9: Response. usage (tokens) capturado no estágio 6 viaja no
          # evento terminal -> usage do /v1/responses + Telemetry (OTEL).
          emit(:done, { content: content, usage: st.usage }, task: task) # compat legada
          emit(:task_completed, { task_id: task.id, content: content, usage: st.usage }, task: task)
        end

        # halt (com motivo) ou curto-circuito sem terminar (violação de
        # contrato) -> falha do turno via captura única.
        if state.halt_reason
          raise Harness::Error, "turno interrompido: #{state.halt_reason}"
        elsif !terminal_ran
          raise Harness::Error, "middleware curto-circuitou sem halt_reason"
        end

          state # subject do par :task (after_task o recebe; o caller descarta)
        end
      end
    rescue Async::TimeoutError
      raise Harness::TimeoutError.new("turno excedeu #{turn_timeout}s", stage: :turn)
    end

    def workflow_turn?(task)
      command_type(task).to_s == "trigger_workflow"
    end

    # Estágio 6: a única interação de agente. Retorna o conteúdo final do turno.
    def run_agent_stage(task, state)
      if workflow_turn?(task)
        # workflow = callable Ruby que orquestra RubyLLM por dentro (RubyLLM
        # First). tools: são as MESMAS instâncias filtradas pela Resolution e
        # envelopadas (estágio 7) — o workflow herda timeout/side-effect/skip.
        workflow = @workflow_registry.resolve(workflow_name(task))
        @hooks.around(:agent, state) do |s|
          # input omitido no payload -> {} (o workflow espera um Hash).
          workflow.call(s.message || {}, context: s.context, tools: s.allowed_tools)
        end
      else
        response = @hooks.around(:agent, state) do |s|
          s.chat.ask(s.message) do |chunk|
            emit(:content, { delta: chunk.content }, task: task) if chunk.content
          end
        end
        state.usage = usage_of(response)
        response.content
      end
    end

    # Uso de tokens da resposta do provider (RubyLLM::Message expõe
    # input_tokens/output_tokens/cached_tokens/model_id). Duck-typed: provider/
    # fake sem contagem -> nil (nada a reportar). Shape compatível com o usage do
    # OpenAI Responses (input/output/total) + model, consumidos pelo /v1/responses
    # e pela Telemetry.
    def usage_of(response)
      return nil unless response.respond_to?(:input_tokens)

      input = response.input_tokens.to_i
      output = response.output_tokens.to_i
      usage = { input_tokens: input, output_tokens: output, total_tokens: input + output }
      if response.respond_to?(:cached_tokens) && response.cached_tokens
        usage[:cached_tokens] = response.cached_tokens.to_i
      end
      usage[:model] = response.model_id.to_s if response.respond_to?(:model_id) && response.model_id
      usage
    end

    def workflow_name(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["workflow"] || payload[:workflow]
    end

    # message do turno: send_message -> payload.message; trigger_workflow ->
    # payload.input (o input vira o "user" content e o argumento do workflow).
    def extract_message(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["message"] || payload[:message] || payload["input"] || payload[:input]
    end

    def command_history(task)
      payload = task.command["payload"] || task.command[:payload] || {}
      payload["history"] || payload[:history]
    end

    def build_context_request(task, profile, state, resume_from)
      session = task.session_id ? @session_store.find(task.session_id) : nil
      hist = command_history(task)
      # `vars` reconcilia o seam (o Request/Session provider já
      # chamavam request.vars): metadados da sessão + o `history` explícito na
      # convenção que o Session provider consome (vars["history"]).
      vars = (session&.vars || {}).dup
      vars["history"] = hist if hist
      # O tipo único é Harness::ContextRequest (Data); o `history` explícito viaja
      # em vars["history"] (convenção do Session provider), não num campo próprio.
      ContextRequest.new(profile: profile, message: state.message, session: session,
                         checkpoint: resume_from, tenant: command_tenant(task), vars: vars)
    end

    # tenant do Command (Command.build(..., tenant:) -> meta[:tenant],
    # command.rb). Ausente -> nil (o MemoryStore aplica DEFAULT_TENANT).
    def command_tenant(task)
      meta = rebuild_command(task).meta
      meta["tenant"] || meta[:tenant]
    end

    # Escopo da memória do motor (D3): tenant EXPLÍCITO do Command vence (override
    # multi-merchant); senão a SESSÃO (=chat) — memória dono-motor é por-chat.
    # Simétrico ao READ path (Memory provider). One-shot sem tenant -> nil
    # (_default). NÃO é o tenant do <request_context> (esse segue command_tenant,
    # paridade de prompt) — só o escopo de leitura/escrita da memória.
    def memory_tenant(task)
      command_tenant(task) || task.session_id
    end

    # Contexto de turno (Fase 6/D2/G4): os ids que as data-tools resolvem via
    # {{ctx.*}} p/ emitir X-Chat-Id/X-Store-Id/X-Agent-Id ao /api/internal/*. Vêm
    # do TURNO, nunca dos args do modelo (R2). chat_id = a sessão (o adapter
    # /v1/responses cria a sessão com id = user = chat.id); tenant = tenant do
    # Command (memória) OU chat_id (default drop-in); agent_id = profile;
    # store_id = metadata do profile (estável por loja, do pack). Campos ausentes
    # -> nil (a data-tool emite header vazio; no piloto o profile carrega store_id).
    # Genérico: nada aqui cita consumer-app (NF1).
    def build_turn_context(task, profile, state)
      {
        chat_id: task.session_id,
        agent_id: profile.id,
        tenant: state.tenant, # já = command_tenant || session_id (memory_tenant)
        store_id: (profile.store_id if profile.respond_to?(:store_id))
      }
    end

    # Request real: command (p/ a WorkflowAllowlist), context
    # (Context antes de Policy), candidate_tools (Entries do registry, SEM
    # filtrar) e candidate_skills (do CATÁLOGO).
    def policy_request(profile, task, state)
      Harness::Policy::PolicyRequest.new(
        profile: profile,
        command: rebuild_command(task),
        context: state.context,
        candidate_tools: @tool_registry.entries,
        candidate_skills: @skill_catalog.effective(profile.skills)
      )
    end

    # A Task persiste o Command como Hash; a WorkflowAllowlist precisa
    # de um Command com #type (Symbol) e #payload.
    def rebuild_command(task)
      cmd = task.command
      Harness::Command.new(
        type: (cmd["type"] || cmd[:type]).to_s.to_sym,
        payload: cmd["payload"] || cmd[:payload] || {},
        meta: cmd["meta"] || cmd[:meta] || {}
      )
    end

    # Engine real -> Entries (respondem a factory); fakes -> instâncias prontas.
    # `turn_context` (D2) é depositado nas instâncias que o expõem (data-tools);
    # as demais ignoram (paridade).
    def instantiate_tools(allowed, turn_context = nil)
      Array(allowed).map do |t|
        tool = t.respond_to?(:factory) ? t.factory.call : t
        inject_turn_context(tool, turn_context)
        tool
      end
    end

    # Costura D2/G3: deposita o contexto do turno na instância recém-criada
    # (mesma ideia do `remember`, que recebe tenant/state) ANTES do ToolEnvelope.
    # Duck-typed: só quem expõe `turn_context=` (DataDefinedTool) recebe. nil
    # (state sem turn_context, ex.: stub de teste) -> no-op.
    def inject_turn_context(tool, turn_context)
      return if turn_context.nil?

      tool.turn_context = turn_context if tool.respond_to?(:turn_context=)
    end

    # Sub-passo de resolução ENTRE Context e Policy —
    # NÃO alimenta candidate_tools (essas continuam SÓ tool_registry.entries,
    # a capability não passa pela ToolAllowlist). Resolve cada capability
    # do perfil para a Entry concreta já registrada no tool_registry e guarda a
    # marcação impl_name -> capability_name p/ a junção pós-Policy. Erros
    # (Unavailable/Ambiguous, ou impl não registrado) propagam como
    # CapabilityError -> captura única no `execute` (stage :capability). Sem
    # @capability_registry OU sem profile.capabilities: {} (paridade).
    def resolve_capabilities(profile, context)
      return {} if @capability_registry.nil?

      Array(profile.capabilities).each_with_object({}) do |cap_name, names|
        provider = @capability_registry.resolve(cap_name, profile: profile, context: context,
                                                           event_stream: @event_stream)
        next if provider.kind == :workflow # exposição ao loop do agente é follow-up

        entry = @tool_registry.entries.find { |e| e.name == provider.impl_name.to_s }
        if entry.nil?
          raise CapabilityError, "capability '#{cap_name}' resolveu para impl " \
                                 "'#{provider.impl_name}', não registrado em tool_registry"
        end

        names[entry.name] ||= cap_name.to_s # 1ª capability a reivindicar um impl vence
      end
    end

    # Junta as instâncias diretas (Policy/ToolAllowlist) às de origem-capability
    # (grant = profile.capabilities — nunca passaram pela Policy). Evita
    # dupla-exposição: se o MESMO impl_name também foi permitido direto, a
    # instância DIRETA é descartada — o modelo vê só o apelido da capability.
    def assemble_tool_instances(allowed, state)
      names = state.respond_to?(:capability_names) ? (state.capability_names || {}) : {}
      ctx = state.respond_to?(:turn_context) ? state.turn_context : nil
      return instantiate_tools(allowed, ctx) if names.empty?

      # Dedup pelo NOME DA ENTRY (chave do registry = impl_name) ANTES de
      # instanciar — o `.name` da INSTÂNCIA (RubyLLM) não é o nome de registro.
      direct = Array(allowed).reject { |e| e.respond_to?(:name) && names.key?(e.name.to_s) }
      instantiate_tools(direct, ctx) + capability_tool_instances(names, ctx)
    end

    # impl_name -> Capability::ResolvedTool(capability_name:), AINDA sem
    # ToolEnvelope (o wrap_tools do call site embrulha o conjunto inteiro — mesma
    # ordem impl -> ResolvedTool -> ToolEnvelope). entry já validada em
    # resolve_capabilities.
    def capability_tool_instances(names, turn_context = nil)
      names.map do |impl_name, capability_name|
        entry = @tool_registry.entries.find { |e| e.name == impl_name }
        tool = entry.factory.call
        inject_turn_context(tool, turn_context)
        Capability::ResolvedTool.new(tool, capability_name: capability_name,
                                           impl_name: impl_name)
      end
    end

    # Envelopa cada tool permitida (timeout por call + registro de side-effect).
    # A LoadSkill de sistema (configure_chat) NÃO é envelopada — é tool de
    # sistema sem side-effect e de latência trivial.
    def wrap_tools(tools, state, skip_side_effects = [])
      timeout = state.profile.limits[:tool_timeout] || 60
      tools.map do |tool|
        ToolEnvelope.new(tool, state: state, checkpoint_store: @checkpoint_store,
                               tool_registry: @tool_registry, timeout: timeout,
                               skip_side_effects: skip_side_effects,
                               trace_recorder: @tool_trace_store)
      end
    end

    # Fronteira de estágio: drena a mailbox e, se o operador pediu pausa,
    # SUSPENDE o turno em :paused até o :resume. Cooperativo — nunca no
    # meio de uma operação. NÃO é chamado no estágio 8 (janela proibida).
    # :cancel durante a espera vira CancelledError (captura única do topo);
    # :timeout vira TimeoutError. O checkpoint inicial do turno já foi gravado,
    # então um kill -9 em :paused é retomável.
    def drain_and_maybe_suspend(task, actor)
      actor.drain!
      return unless actor.pause_requested?

      @task_store.transition(task.id, to: :paused)
      emit(:task_paused, { task_id: task.id }, task: task)
      actor.await(reason: :paused) # bloqueia até :resume (ou levanta em :cancel/:timeout)
      @task_store.transition(task.id, to: :running)
      emit(:task_resumed, { task_id: task.id }, task: task)
    end

    # Checkpoint do estado inicial do turno (ver chamada no run_pipeline). Só no
    # 1º turno de uma task nova: no resume o checkpoint do turno já existe (não
    # re-salva — a monotonicidade do CheckpointStore levantaria). NÃO emite
    # evento (:checkpoint_created é só do estágio 8) nem toca side-effects.
    def save_initial_checkpoint(task, profile, state)
      return unless @checkpoint_store.find(task.id, turn: state.turn).nil?

      @checkpoint_store.save(Harness::Checkpoint.new(
                               task_id: task.id, turn: state.turn, session_id: task.session_id,
                               agent_id: profile.id, messages: Array(state.context.history),
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))
    end

    # Estágio 8: ordem FIXA checkpoint -> session -> task. Se cair
    # entre escritas, o pior caso é checkpoint novo com task :running -> Recovery
    # reexecuta o turno já salvo (seguro pelo registro de side-effects).
    def persist_turn(task, profile, state, content)
      new_messages = [
        { role: "user", content: state.message },
        { role: "assistant", content: content }
      ]
      transcript = Array(state.context.history) + new_messages

      @checkpoint_store.save(Harness::Checkpoint.new(
                               task_id: task.id, turn: state.turn + 1, session_id: task.session_id,
                               agent_id: profile.id, messages: transcript,
                               completed_side_effects: [], created_at: Time.now.utc.iso8601
                             ))

      # sessão só quando o turno é de sessão persistida; one-shot/history
      # não persistem NA SESSÃO (mas sempre checkpointam).
      @session_store.append_messages(task.session_id, new_messages) if task.session_id

      # finish_execution (fecha a Execution) ANTES do transition(:completed) —
      # transition sem error: não fecha, então o finish é necessário aqui.
      @task_store.finish_execution(task.id, outcome: :completed)
      @task_store.transition(task.id, to: :completed)
      # prune é cleanup best-effort: uma falha aqui NÃO pode re-falhar um
      # turno já commitado (a task já é :completed e durável). Swallow.
      begin
        @checkpoint_store.prune(task.id, keep: 1)
      rescue Harness::StoreError
        nil
      end

      emit(:checkpoint_created, { task_id: task.id, turn: state.turn + 1 }, task: task)
    end

    # Estágio 6 (fábrica): ÚNICO ponto que toca a gem. require lazy,
    # confinado — não coberto por unit (linha de fábrica). Também carrega os
    # builtins de sistema (load_skill/tool_search/remember) que o ChatBuilder
    # monta no estágio 5 — lazy, para o núcleo instalar sem ruby_llm.
    def create_chat(profile)
      require "ruby_llm"
      require_relative "tools/load_skill"
      require_relative "tools/tool_search"
      require_relative "tools/remember"
      RubyLLM.chat(
        model: profile.model,
        provider: profile.provider,
        assume_model_exists: !profile.provider.nil?
      )
    end

    # Emissor único: Event com meta e seq monotônico por task. @seqs não é
    # limpo ao fim da task — o resume (nova Execution) continua a numeração
    # (replay confiável).
    def emit(type, data, task:)
      @event_stream.emit(Harness::Event.new(
                           type: type, data: data,
                           meta: { task_id: task.id, session_id: task.session_id,
                                   seq: (@seqs[task.id] += 1), at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
