# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Write path da memória cross-session (P2C, RFC-0005 §6): o agente grava um
    # fato (key+value, upsert durável) ou uma note (value sem key) sob demanda.
    # Determinístico — SEM chamada de modelo (o extractor por LLM é fatia D).
    # Builtin de sistema (como load_skill/tool_search): `require "ruby_llm"` fica
    # NESTE arquivo, carregado lazy pelo Executor em create_chat (D9).
    class Remember < RubyLLM::Tool
      description "Guarda uma informação para lembrar em conversas futuras. Use `key` " \
                  "para um fato durável chave-valor (sobrescreve o anterior); omita " \
                  "`key` para uma anotação livre."
      param :value, desc: "O conteúdo a lembrar"
      param :key, desc: "Chave do fato (ex.: 'plano', 'nome'); omita para uma nota", required: false

      # senão RubyLLM deriva "harness--tools--remember" do nome da classe (P2B-02 L7).
      def name = "remember"

      def initialize(store, tenant, event_stream:, state:)
        @store = store
        @tenant = tenant
        @event_stream = event_stream
        @state = state
        super()
      end

      def execute(value:, key: nil)
        if key.to_s.strip.empty?
          note = @store.add_note(tenant: @tenant, text: value.to_s)
          emit("note", note.id)
          { remembered: "note", id: note.id }
        else
          @store.put_fact(tenant: @tenant, key: key.to_s, value: value.to_s)
          emit("fact", key.to_s)
          { remembered: "fact", key: key.to_s }
        end
      end

      private

      def emit(kind, ref)
        @event_stream.emit(Harness::Event.new(
                             type: :memory_written,
                             data: { kind: kind, key: ref },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end
    end
  end
end
