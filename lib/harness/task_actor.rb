# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Modelo de Actor (RFC-0002 §9): um fiber Async por Task + mailbox. Fase 1
  # tinha só `cancel`/`user_message`; a Fase 2 completa o enum (`approval`,
  # `pause`, `resume`, `timeout`, `heartbeat`) e adiciona o primitivo de
  # SUSPENSÃO cooperativa (`await`). Cancelamento/suspensão só nas fronteiras de
  # estágio (doc 03 L2) — nunca no meio de uma operação.
  class TaskActor
    # `user_message` segue reservado (sem produtor). `pause`/`resume` (operador,
    # P2-01), `approval` (human-in-the-loop, P2-02), `timeout`/`heartbeat`
    # (watchdog/liveness, observação — P2-01 L4).
    MESSAGES = %i[cancel user_message approval pause resume timeout heartbeat].freeze

    attr_reader :task_id, :pending_user_messages, :heartbeats

    def initialize(task_id:, parent: Async::Task.current)
      @task_id = task_id
      @parent = parent
      @mailbox = Async::Queue.new
      @pending_user_messages = []
      @pause_requested = false
      @heartbeats = 0
    end

    # Não-bloqueante (doc 03 §5). Mensagem fora do enum é bug do chamador.
    def post(message, data = nil)
      raise ArgumentError, "mensagem desconhecida: #{message}" unless MESSAGES.include?(message)

      @mailbox.enqueue([message, data])
      nil
    end

    # Roda o bloco num fiber Async FILHO do parent (doc 03 §5). Retorna o Task.
    def run(&turn_block)
      @async_task = @parent.async { turn_block.call(self) }
    end

    # Drena a mailbox SEM bloquear (fronteiras, L2). `:cancel` levanta (o topo do
    # fiber mapeia :cancelled). `:pause` arma a suspensão (o Executor checa
    # `pause_requested?`). Resoluções (`:resume`/`:approval`/`:timeout`) que
    # cheguem aqui SEM suspensão pendente são DESCARTADAS (idempotente, no-op).
    def drain!
      until @mailbox.empty?
        route_boundary(*@mailbox.dequeue)
      end
      nil
    end

    # O operador pediu pausa? (consumido pelo Executor; `await` limpa o flag).
    def pause_requested? = @pause_requested

    # BLOQUEIA o fiber do turno até uma RESOLUÇÃO (cede o reactor — sem spin).
    # Usado pelo Executor em :paused (espera :resume) e pelo ToolEnvelope em
    # :waiting (espera :approval). Retorna [:resume, nil] ou [:approval, data].
    # `:cancel` -> CancelledError; `:timeout` -> TimeoutError. Uma resolução
    # legítima só chega COM o fiber já aqui bloqueado (o operador só resume/aprova
    # o que está suspenso), então é consumida por este `dequeue` — não há corrida
    # que exija buffer. Mensagens não-resolução recebidas durante a espera são
    # ABSORVIDAS sem alterar o estado de suspensão (um :pause redundante não
    # re-arma a pausa).
    def await(reason:)
      @pause_requested = false # a pausa/espera está sendo tratada agora
      loop do
        message, data = @mailbox.dequeue
        case message
        when :cancel        then raise CancelledError, "task #{@task_id} cancelada"
        when :timeout       then raise Harness::TimeoutError.new("espera (#{reason}) excedeu", stage: data || reason)
        when :resume, :approval then return [message, data]
        when :heartbeat     then @heartbeats += 1
        when :user_message  then @pending_user_messages << data
        # :pause durante a espera: já suspenso, ignora (não re-arma pause_requested)
        end
      end
    end

    # specs/boot aguardam o término do fiber.
    def wait = @async_task&.wait

    private

    # Roteamento das mensagens de fronteira (não-bloqueante). Resoluções órfãs
    # (`:resume`/`:approval`/`:timeout` sem suspensão pendente) são DESCARTADAS —
    # NUNCA bufferizadas: uma resolução guardada resolveria erroneamente um
    # `await` FUTURO (auto-resume/auto-approve/auto-timeout de uma suspensão que
    # o operador não resolveu). Resoluções legítimas chegam com o fiber já em
    # `await` (consumidas lá), então descartar aqui é seguro e idempotente.
    def route_boundary(message, data)
      case message
      when :cancel then raise CancelledError, "task #{@task_id} cancelada"
      when :pause then @pause_requested = true
      when :user_message then @pending_user_messages << data
      when :heartbeat then @heartbeats += 1
      when :resume, :approval, :timeout then nil # órfã: descarta (ver comentário)
      end
    end
  end
end
