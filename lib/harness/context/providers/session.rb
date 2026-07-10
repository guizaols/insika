# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Lê o Session Store (D2). ÚNICO provider de histórico: as três fontes de
      # transcript convergem aqui (L4) — o Executor não escolhe fonte. Produz
      # fragmentos :history (1 por mensagem), priority escalonada por recência
      # com TETO 79 (L7): o corte de orçamento descarta as mais antigas primeiro
      # e o histórico NUNCA supera skills (80) nem identidade (100).
      class Session < ContextProvider
        def initialize(session_store:)
          @session_store = session_store
        end

        def call(request)
          messages = transcript_for(request)
          return [] if messages.nil? || messages.empty?

          messages.each_with_index.map do |msg, idx|
            ContextFragment.build(
              content: { role: msg[:role] || msg["role"], content: msg[:content] || msg["content"] },
              placement: :history,
              priority: [60 + idx, 79].min, # teto 79 (L7); idx 0 = mais antiga
              source: id
            )
          end
        end

        private

        # Precedência (doc 04 §2 / D2): checkpoint -> history explícito -> store.
        # A primeira fonte presente vence; sem merge.
        def transcript_for(request)
          return request.checkpoint.messages if request.checkpoint

          explicit = explicit_history(request)
          return explicit if explicit
          return session_messages(request.session) if request.session

          nil
        end

        # Fonte 2 (history explícito): convenção pendente com a task 12 —
        # o handler repassa em request.vars[:history]. Isolado num método único
        # p/ trocar a convenção com 1 linha (ver Notes da task).
        def explicit_history(request)
          vars = request.vars.to_h
          vars[:history] || vars["history"]
        end

        # Requiredness CONDICIONAL (doc 04 §6): com sessão pedida, falha de
        # leitura vira ContextError (aborta o turno); a base required? não
        # recebe o request, então o comportamento mora aqui.
        def session_messages(session)
          @session_store.find(session.id)&.messages || []
        rescue StandardError => e # doc 04 §6: "a leitura falha (exceção/StoreError)"
          raise ContextError.new("Session provider falhou com sessão pedida: #{e.message}",
                                 provider: id)
        end
      end
    end
  end
end
