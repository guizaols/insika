# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Lê o Session Store. ÚNICO provider de histórico: as três fontes de
      # transcript convergem aqui — o Executor não escolhe fonte. Produz
      # fragmentos :history (1 por mensagem), priority escalonada por recência
      # com TETO 79: o corte de orçamento descarta as mais antigas primeiro
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
              # teto HISTORY_MAX; idx 0 = mais antiga (cai primeiro no corte)
              priority: [Context::Priority::HISTORY_BASE + idx, Context::Priority::HISTORY_MAX].min,
              source: id
            )
          end
        end

        private

        # Precedência: checkpoint -> history explícito -> store.
        # A primeira fonte presente vence; sem merge.
        def transcript_for(request)
          return request.checkpoint.messages if request.checkpoint

          explicit = explicit_history(request)
          return explicit if explicit
          return session_messages(request.session) if request.session

          nil
        end

        # Fonte 2 (history explícito): o handler repassa em request.vars[:history].
        # Isolado num método único p/ trocar a convenção com 1 linha.
        def explicit_history(request)
          vars = request.vars.to_h
          vars[:history] || vars["history"]
        end

        # Requiredness CONDICIONAL: com sessão pedida, falha de
        # leitura vira ContextError (aborta o turno); a base required? não
        # recebe o request, então o comportamento mora aqui.
        def session_messages(session)
          @session_store.find(session.id)&.messages || []
        rescue StandardError => e # leitura falha (exceção/StoreError)
          raise ContextError.new("Session provider falhou com sessão pedida: #{e.message}",
                                 provider: id)
        end
      end
    end
  end
end
