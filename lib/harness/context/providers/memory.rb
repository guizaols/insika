# frozen_string_literal: true

module Harness
  module Context
    module Providers
      # Read path da memória cross-session. Adaptador fino sobre
      # o MemoryStore — mesmo padrão do Skill/ToolSearch provider: um fragmento
      # `:system` com os fatos + as notes recentes do tenant. Determinístico (sem
      # embeddings/ranking).
      class Memory < ContextProvider
        def initialize(store:, notes_limit: 10)
          @store = store
          @notes_limit = notes_limit
        end

        # Opt-in por agente. O Builder ainda aplica a allowlist
        # `context_providers` por cima (dois gates, como os demais providers).
        def enabled_for?(profile) = !!profile.memory

        # required? == false (default): falha (store indisponível) vira
        # :provider_warning + degradação graciosa — nunca aborta o turno.
        def call(request)
          tenant = memory_tenant(request)
          facts = @store.facts(tenant: tenant)
          notes = @store.notes(tenant: tenant, limit: @notes_limit)
          return [] if facts.empty? && notes.empty?

          # priority MEMORY (75): entre skills (80) e tools deferred (70) na ordem
          # de sacrifício. pinned false (cortável sob orçamento apertado).
          [ContextFragment.build(content: format_block(facts, notes),
                                 placement: :system, priority: Context::Priority::MEMORY, source: id)]
        end

        private

        # Escopo da memória do motor (D3): tenant EXPLÍCITO do Command vence
        # (override multi-merchant); senão a SESSÃO (=chat) — memória dono-motor é
        # por-chat. Sem sessão (one-shot) e sem tenant -> nil (MemoryStore aplica
        # _default). Simétrico ao write path (`state.tenant` no Executor).
        def memory_tenant(request)
          explicit = request.respond_to?(:tenant) ? request.tenant : nil
          return explicit if explicit

          request.respond_to?(:session) ? request.session&.id : nil
        end

        # <memory> passivo (sem instrução — o COMO gravar vive na tool `remember`).
        def format_block(facts, notes)
          lines = facts.map { |f| %(  <fact key="#{f.key}">#{f.value}</fact>) }
          lines += notes.map { |n| "  <note>#{n.text}</note>" }
          <<~BLOCK.strip
            <memory>
            #{lines.join("\n")}
            </memory>
          BLOCK
        end
      end
    end
  end
end
