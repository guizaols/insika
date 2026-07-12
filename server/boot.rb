# frozen_string_literal: true

require "async"

module Harness
  module Server
    # Transforma os componentes num serviço.
    # Ordem OBRIGATÓRIA e sem paralelismo: plugins → stores → recovery → (app
    # para o listen). "Nunca aceita request antes do recovery" é garantido POR
    # CONSTRUÇÃO: o listen (Falcon) só roda depois que `#call` retorna o app, e
    # `#call` só retorna após o `Recovery.run` terminar.
    class Boot
      # wiring: objeto com os passos nomeados (load_plugins/build_stores/
      # recovery/app) — o config/wiring.rb. logger: IO simples (default $stdout;
      # nil silencia).
      def initialize(wiring, logger: $stdout)
        @wiring = wiring
        @logger = logger
      end

      # -> Rack app pronto para o `run`. Falha de store no boot (arquivo
      # corrompido → StoreError) PROPAGA e aborta o processo (subir
      # sem durabilidade é pior que não subir); uma task irrecuperável NÃO
      # derruba o boot (o Recovery já a marca :failed).
      def call
        @wiring.load_plugins
        @wiring.build_stores
        warn_if_ephemeral
        summary = run_recovery
        log("boot: recovery concluído — #{summary[:resumed].size} retomada(s), " \
            "#{summary[:failed].size} falha(s)")
        @wiring.app
      end

      private

      # Recovery despacha resume_task, que cria fibers de task — precisa de um
      # reactor corrente. No load do config.ru (Falcon) NÃO há reactor: o Sync { }
      # cria um e, por concorrência estruturada, só retorna quando os fibers de
      # retomada TERMINAM (recovery + turnos concluídos antes do listen — boot
      # mais lento, semanticamente seguro). Sob um reactor já corrente (testes
      # dentro de Async), roda direto: retorna após o DISPATCH da retomada, com
      # os turnos ainda em voo — também correto: "recovery antes do listen" =
      # dispatch antes do listen, não conclusão dos turnos.
      def run_recovery
        recovery = @wiring.recovery
        return recovery.run if Async::Task.current?

        Sync { recovery.run }
      end

      # Durabilidade: sem backend durável, nada é retomado após
      # restart — avisa alto no boot para não subir "sem rede" por engano. O
      # wiring de teste (duplo) pode não expor `durable?`; nesse caso, silêncio.
      def warn_if_ephemeral
        return unless @wiring.respond_to?(:durable?)
        return if @wiring.durable?

        log("boot: AVISO — backend EFÊMERO (sem HARNESS_DB): recovery não " \
            "retomará nada após restart (doc 02 §6).")
      end

      def log(message)
        @logger&.puts(message)
      end
    end
  end
end
