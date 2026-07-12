# frozen_string_literal: true

require "json"
require "rack"
require "async"
require_relative "sse_body"
require_relative "admin_auth"
require_relative "admin/app"
require_relative "a2a/app" # adapter A2A de borda (puxa protocol/errors/message/projection/card)

module Harness
  module Server
    # Rack app. Transportes SÓ
    # traduzem requisições em Commands — o servidor não contém lógica de
    # negócio. Ele parseia JSON, monta `Command.build(...)`, despacha no
    # CommandBus e projeta o Event Stream em SSE. Leituras NÃO são Commands: são
    # reads diretos dos stores.
    #
    # Regra constitucional AUDITÁVEL: `server/` não importa Executor,
    # métodos de ESCRITA de store nem RubyLLM. Requires: json, rack, async e os
    # tipos do núcleo (Command/Event/erros) já carregados pelo composition root.
    class App
      SSE_HEADERS = {
        "content-type" => "text/event-stream",
        "cache-control" => "no-cache",
        "connection" => "keep-alive"
      }.freeze

      # Eventos terminais de um turno (fecham a subscription da task no
      # transporte). :error é mantido por compat com o consumidor.
      TERMINAL_EVENTS = %i[done task_failed task_cancelled error].freeze
      private_constant :TERMINAL_EVENTS

      # checkpoint_store: leitura apenas (coluna "checkpoints" de
      # /admin/tasks/:id). A regra constitucional se mantém: server/ só LÊ stores.
      def initialize(command_bus:, event_stream:, session_store:, task_store:,
                     catalogs:, registries:, config:, checkpoint_store: nil,
                     pending_action_store: nil, a2a: nil)
        @command_bus = command_bus
        @event_stream = event_stream
        @session_store = session_store
        @task_store = task_store
        @catalogs = catalogs
        @registries = registries
        @config = config
        @pending_action_store = pending_action_store # leitura p/ GET /v1/tasks/:id
        @a2a = a2a # A2A edge. nil = servidor não expõe A2A (paridade).
        @heartbeat = config.fetch(:heartbeat, 15)
        @sync_timeout = config.fetch(:sync_timeout, 10) # controle síncrono
        # Control UI de escrita: recebe o bus (despacha os mesmos Commands
        # da API) e o pending_action_store (aprovações). O /admin não escreve em
        # store direto — só via Command (transporte).
        @admin = Admin::App.new(
          command_bus: command_bus, session_store: session_store, task_store: task_store,
          checkpoint_store: checkpoint_store, pending_action_store: pending_action_store,
          catalogs: catalogs, registries: registries, event_stream: event_stream
        )
      end

      # Roteamento explícito, SEM framework: ~10 rotas num `case`. Um único
      # `rescue` centraliza o mapeamento erro->status. Só erros
      # SÍNCRONOS (antes do fiber) viram status HTTP; falha da task viaja como
      # evento no stream e fica em GET /v1/tasks/:id.
      def call(env)
        req = Rack::Request.new(env)
        route(req)
      rescue JSON::ParserError => e
        error_response(400, e) # JSON malformado, antes de qualquer dispatch
      rescue Harness::ValidationError => e
        error_response(422, e)
      rescue Harness::NotFoundError => e
        error_response(404, e)
      rescue Async::TimeoutError => e
        error_response(504, e) # request síncrono de controle estourou o teto
      rescue StandardError => e
        error_response(500, e)
      end

      private

      def route(req)
        segments = req.path_info.split("/").reject(&:empty?)
        return handle_admin(req) if segments.first == "admin"

        case [req.request_method, segments]
        in ["POST", ["v1", "commands", type]]
          handle_command(req, type)
        in ["POST", ["v1", "sessions"]]
          handle_create_session(req)
        in ["POST", ["v1", "messages"]]
          handle_send_message(req)
        in ["GET", ["v1", "sessions", id]]
          handle_read_session(id)
        in ["GET", ["v1", "tasks", id]]
          handle_read_task(id)
        in ["GET", ["v1", "events"]]
          handle_events(req)
        in ["POST", ["agent", "messages"]]
          handle_legacy(req)
        in ["POST", ["a2a"]] if @a2a
          handle_a2a(req)
        in ["GET", [".well-known", "agent-card.json"]] if @a2a
          json_response(200, @a2a.agent_card)
        else
          not_found # método/rota errados (ou A2A não exposto -> @a2a nil)
        end
      end

      # Pipeline do /admin: preflight OPTIONS (sem auth —
      # browsers não mandam Authorization em preflight) -> AdminAuth.check
      # (fail-closed) -> headers CORS na resposta -> delega ao Admin::App. O
      # /admin NUNCA despacha Command nem escreve em store.
      def handle_admin(req)
        origin = req.get_header("HTTP_ORIGIN")
        return preflight_response(origin) if req.request_method == "OPTIONS"

        cors = cors_headers(origin)
        case Harness::Server::AdminAuth.check(@config[:admin_token], req.get_header("HTTP_AUTHORIZATION"))
        when :disabled
          merge_headers(admin_error(503, "admin disabled"), cors)
        when :unauthorized
          merge_headers(admin_error(401, "unauthorized", "www-authenticate" => "Bearer"), cors)
        else # :ok
          merge_headers(@admin.call(req), cors)
        end
      end

      # CORS ESTRITO: só devolve headers se a Origin constar
      # EXATAMENTE em allowed_origins (sem `*`, sem sufixos). Sem Origin (curl,
      # mesma origem) -> {}. Default [] = nenhuma origem cross-site.
      def cors_headers(origin)
        return {} if origin.nil?
        return {} unless Array(@config[:allowed_origins]).include?(origin)

        { "access-control-allow-origin" => origin, "vary" => "origin" }
      end

      def preflight_response(origin)
        headers = { "content-type" => "text/plain" }
        if origin && Array(@config[:allowed_origins]).include?(origin)
          headers.merge!(cors_headers(origin),
                         "access-control-allow-methods" => "GET, POST", # /admin de escrita
                         "access-control-allow-headers" => "authorization, content-type")
        end
        [204, headers, []]
      end

      def admin_error(status, message, extra_headers = {})
        [status,
         { "content-type" => "application/json" }.merge(extra_headers),
         [JSON.generate(error: { class: "Harness::Error", message: message })]]
      end

      def merge_headers(response, extra)
        status, headers, body = response
        [status, headers.merge(extra), body]
      end

      # POST /v1/commands/:type — genérica: todo Command novo já nasce com
      # transporte. Distinção controle vs turno é PELO SHAPE do resultado (o
      # transporte não conhece semântica).
      def handle_command(req, type)
        command = Harness::Command.build(type.to_sym, parse_body(req), transport: :http)
        command_response(dispatch_with_timeout(command))
      end

      # POST /v1/sessions — açúcar p/ create_session; 201 {session}.
      def handle_create_session(req)
        body = parse_body(req)
        command = Harness::Command.build(:create_session, { vars: body[:vars] || {} },
                                         transport: :http)
        session = dispatch_with_timeout(command)
        json_response(201, { session: session.to_h })
      end

      # POST /v1/messages — açúcar p/ send_message; ?stream ausente/"true" -> SSE,
      # "false" -> 200 JSON agregado no evento terminal.
      def handle_send_message(req)
        stream = req.GET["stream"] != "false"
        message_flow(parse_body(req), stream: stream)
      end

      # GET /v1/sessions/:id — leitura direta (não é Command).
      def handle_read_session(id)
        session = @session_store.find(id)
        raise Harness::NotFoundError, "sessão inexistente: #{id}" if session.nil?

        json_response(200, { session: session.to_h })
      end

      # GET /v1/tasks/:id — leitura direta. É por aqui que o consumidor observa
      # PolicyDenied/falhas pós-202: o estado terminal fica no Task
      # Store; nada se perde se o cliente desconectou.
      def handle_read_task(id)
        task = @task_store.find(id)
        raise Harness::NotFoundError, "task inexistente: #{id}" if task.nil?

        body = { task: task_to_h(task) }
        # aprovações pendentes: é por aqui que o consumidor/operador vê
        # o que precisa aprovar depois de um :approval_requested.
        if @pending_action_store
          body[:pending_actions] = @pending_action_store.open_for(id).map(&:to_h)
        end
        json_response(200, body)
      end

      # GET /v1/events?task_id=&session_id= — aqui os filtros SÃO conhecidos.
      # Stream CONTÍNUO (rota de reconexão pós-queda): não fecha em
      # evento terminal — encerra por desconexão do cliente ou cap.
      def handle_events(req)
        subscription = @event_stream.subscribe(task_id: req.GET["task_id"],
                                                session_id: req.GET["session_id"])
        sse_response(subscription)
      end

      # POST /agent/messages — LEGADO, byte-compatível. Traduz para
      # send_message (o Runner não existe mais). `history` presente
      # -> nada é persistido (paridade). Default de agente "sales".
      def handle_legacy(req)
        body = parse_body(req)
        payload = {
          agent: body[:agent] || "sales",
          message: body[:message],
          history: body[:history] || []
        }
        message_flow(payload, stream: true)
      end

      # POST /a2a — JSON-RPC 2.0: HTTP 200 SEMPRE (o erro viaja no envelope,
      # não no status). JSON malformado -> -32700 (envelope A2A, não o error HTTP
      # genérico do #call). O A2A::App nunca vaza exceção. Parse com chaves
      # STRING (o wire A2A é JSON genérico — NÃO reusa `parse_body`, que
      # symboliza para os payloads de Command).
      def handle_a2a(req)
        raw = req.body&.read
        body =
          begin
            raw.nil? || raw.empty? ? {} : JSON.parse(raw)
          rescue StandardError
            return json_response(200, A2A::Protocol.error(nil, A2A::Errors::PARSE_ERROR, "parse error"))
          end
        json_response(200, @a2a.rpc(body))
      end

      # --- Fluxo de turno (SSE ou agregado) ---------------------------------

      # Assine ANTES de despachar: sob Async o fiber da task pode
      # rodar eagerly e emitir :task_started antes de o dispatch retornar. O
      # task_id só existe DEPOIS do dispatch -> assina SEM filtro e filtra no
      # transporte (TaskFilter). Erro SÍNCRONO do handler (Validation/NotFound)
      # acontece aqui, ANTES do SSE abrir -> fecha a subscription e propaga p/ o
      # rescue de #call (vira status HTTP).
      def message_flow(payload, stream:)
        command = Harness::Command.build(:send_message, payload, transport: :http)
        subscription = @event_stream.subscribe
        result =
          begin
            @command_bus.dispatch(command)
          rescue StandardError
            subscription.close
            raise
          end

        task_id = result[:task_id]
        # Vincula a subscription ao task_id agora que ele existe: o cap passa a
        # contar só eventos DESTA task e o :error de overflow sai com o task_id
        # certo. Os eventos já enfileirados (fiber eager) são desta task — nenhum
        # se perde.
        subscription.bind(task_id: task_id)
        filtered = TaskFilter.new(subscription, task_id)
        stream ? sse_response(filtered) : aggregate_response(filtered, task_id)
      end

      # stream=false: agrega iterando a subscription filtrada no
      # próprio fiber da request. Acumula deltas de :content; responde no
      # terminal. O shape com `error:` espelha o data do :task_failed (menor
      # extensão coerente — o estado também está em GET /v1/tasks/:id). Terminais
      # não-felizes (:task_cancelled, :error de overflow) também viram `error:` —
      # um turno cancelado/truncado NUNCA é reportado como 200 de sucesso.
      def aggregate_response(subscription, task_id)
        content = +""
        events = []
        error = nil

        subscription.each do |event|
          events << event.to_h
          case event.type
          when :content        then content << event.data[:delta].to_s
          when :task_failed    then error = { class: event.data[:error], message: event.data[:message] }
          when :task_cancelled then error = { class: "Harness::CancelledError", message: "task cancelada" }
          when :error          then error ||= { class: nil, message: event.data[:message] }
          end
        end

        if error
          json_response(200, { task_id: task_id, events: events, error: error })
        else
          json_response(200, { content: content, task_id: task_id, events: events })
        end
      end

      def sse_response(subscription)
        [200, SSE_HEADERS.dup, SSEBody.new(subscription: subscription, heartbeat: @heartbeat)]
      end

      # --- Dispatch e serialização -----------------------------------------

      # Commands de controle podem estourar 10s -> 504. Para
      # Commands de turno o dispatch retorna imediato (o turno vive no fiber) —
      # o timeout é inócuo. NUNCA Timeout.timeout da stdlib. Sem reactor
      # corrente (teste de controle puro), despacha direto.
      def dispatch_with_timeout(command)
        task = Async::Task.current?
        return @command_bus.dispatch(command) if task.nil?

        task.with_timeout(@sync_timeout) { @command_bus.dispatch(command) }
      end

      # Turno -> {task_id:} -> 202. Qualquer outro shape (controle:
      # Session/Task, que são Data) -> 200 com to_h serializado.
      def command_response(result)
        if turn_result?(result)
          json_response(202, { task_id: result[:task_id] })
        else
          json_response(200, result.to_h)
        end
      end

      # Turno = Hash com task_id PRESENTE e não-nil. Um controle que
      # devolvesse Hash sem task_id útil não é confundido com turno.
      def turn_result?(result)
        result.is_a?(Hash) && !result[:task_id].nil?
      end

      # Body vazio ou sem content-type -> {} (transporte valida só
      # JSON bem-formado; payload é do handler). NÃO usa req.params (consumiria
      # o body como form) — lê o corpo cru.
      def parse_body(req)
        raw = req.body&.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw, symbolize_names: true)
      end

      # Task#to_h é raso (Data#to_h não desce): `executions` fica como Array de
      # Execution (Data), que JSON.generate serializaria como string opaca
      # (`"#<data ...>"`) — ilegível para o consumidor que observa falhas por
      # GET /v1/tasks/:id. Desce a serialização das Executions.
      def task_to_h(task)
        task.to_h.merge(executions: task.executions.map(&:to_h))
      end

      def json_response(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end

      def error_response(status, error)
        json_response(status, { error: { class: error.class.name, message: error.message } })
      end

      def not_found
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end

      # Decorator fino de Subscription: descarta
      # eventos de OUTRAS tasks e FECHA a subscription após repassar o evento
      # terminal da task. Resolve a lacuna subscribe-antes-do-task_id sem tocar
      # na assinatura da Subscription.
      class TaskFilter
        def initialize(subscription, task_id)
          @subscription = subscription
          @task_id = task_id
        end

        def each
          @subscription.each do |event|
            next unless (event.meta || {})[:task_id] == @task_id

            yield event
            break if TERMINAL_EVENTS.include?(event.type)
          end
        ensure
          @subscription.close
        end

        def close = @subscription.close
      end
      private_constant :TaskFilter
    end
  end
end
