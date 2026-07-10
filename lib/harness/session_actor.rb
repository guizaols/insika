# frozen_string_literal: true

require "async"
require "async/queue"

module Harness
  # Sessions como Actors (RFC-0002 §9, P2-03): um fiber por sessão com fila FIFO
  # de turnos, executados UM POR VEZ. Restaura o invariante "um dono por vez" do
  # transcript que dois `send_message` concorrentes no mesmo `session_id`
  # quebrariam (read-modify-write no Session Store). Turnos de sessões distintas
  # seguem concorrentes; one-shot/history (sem session_id) não passam por aqui.
  #
  # Vive no escopo SUPERVISIONADO (L4): o loop é filho do supervisor, não da
  # request — sobrevive à conexão. O turno em si (spawnado pelo Executor) também
  # nasce no supervisor; o SessionActor apenas o AGUARDA para serializar.
  class SessionActor
    def initialize(session_id:, executor:, parent: Async::Task.current)
      @session_id = session_id
      @executor = executor
      @queue = Async::Queue.new
      @running = false
      @loop = parent.async { |t| t.annotate("session:#{session_id}"); run_loop }
    end

    # Enfileira um turno (FIFO). Não-bloqueante: o handler responde {task_id:}
    # imediato mesmo que o turno fique :queued atrás de outro. -> task.id.
    def enqueue(task, profile:, resume_from: nil)
      @queue.enqueue([task, profile, resume_from])
      task.id
    end

    def running? = @running
    def depth = @queue.size

    # O loop ainda está vivo? (o Executor revalida antes de reusar do cache —
    # um loop morto black-holearia turnos enfileirados).
    def alive? = !!@loop&.running?

    # Encerra o loop (shutdown do servidor / testes — o loop bloqueia p/ sempre
    # em dequeue quando ocioso).
    def stop = @loop&.stop

    private

    def run_loop
      loop do
        task, profile, resume_from = @queue.dequeue # bloqueia quando vazio
        @running = true
        begin
          @executor.run_serial(task, profile: profile, resume_from: resume_from)
        rescue StandardError
          # run_serial já mapeia erros do turno; este rescue é defesa: um erro
          # inesperado NUNCA derruba o loop da sessão (Async::Stop < Exception
          # não é capturado -> #stop encerra o loop normalmente).
          nil
        ensure
          @running = false
        end
      end
    end
  end
end
