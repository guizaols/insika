# frozen_string_literal: true

require "async"

module Harness
  module Server
    # Transforma os componentes das 25 tasks anteriores num serviço (doc 07 §4).
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
      # corrompido → StoreError) PROPAGA e aborta o processo (doc 02 §6: subir
      # sem durabilidade é pior que não subir); uma task irrecuperável NÃO
      # derruba o boot (o Recovery já a marca :failed).
      def call
        @wiring.load_plugins
        @wiring.build_stores
        summary = run_recovery
        log("boot: recovery concluído — #{summary[:resumed].size} retomada(s), " \
            "#{summary[:failed].size} falha(s)")
        @wiring.app
      end

      private

      # Recovery despacha resume_task, que cria fibers de task — precisa de um
      # reactor corrente. No load do config.ru pode não haver um: envolve em
      # Sync { } quando necessário (edge case 1). Sob um reactor já corrente
      # (teste dentro de Async), roda direto.
      def run_recovery
        recovery = @wiring.recovery
        return recovery.run if Async::Task.current?

        Sync { recovery.run }
      end

      def log(message)
        @logger&.puts(message)
      end
    end
  end
end
