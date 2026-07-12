# frozen_string_literal: true

require "ruby_llm"

module Harness
  module Tools
    # Delega a um agente A2A remoto. Tool NORMAL do Tool Registry — a
    # allowlist do agente governa quem pode delegar. require lazy da gem: NÃO
    # entra em lib/harness.rb; é carregado no bloco de registro (wiring) na 1ª
    # instância. Uma instância por agente remoto (name/description próprios).
    class A2ARemote < RubyLLM::Tool
      param :message, desc: "A mensagem/tarefa para o agente remoto"

      def initialize(client:, url:, tool_name:, description:, event_stream: nil)
        @client = client
        @url = url
        @tool_name = tool_name
        @description = description
        @event_stream = event_stream
        super()
      end

      # name/description por INSTÂNCIA (RubyLLM deriva da classe; sobrescrevemos —
      # senão o modelo veria "harness--tools--a2a_remote" p/ todos os remotos).
      def name = @tool_name
      def description = @description

      def execute(message:)
        result = @client.call(@url, message.to_s)
        emit(result)
        result[:error] ? { error: result[:error] } : result[:text]
      end

      private

      # :a2a_call sem correlação de task: tools de registry não recebem o
      # TurnState -> meta {} (como o :provider_warning do Builder). O :tool_call
      # do wire_callbacks já correlaciona a chamada em si.
      def emit(result)
        @event_stream&.emit(Harness::Event.new(
                              type: :a2a_call,
                              data: { agent: @tool_name, remote_task_id: result[:id], state: result[:state] },
                              meta: {}
                            ))
      end
    end
  end
end
