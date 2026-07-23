# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # Delegates to a remote A2A agent. A NORMAL Tool Registry tool — the
    # agent's allowlist governs who may delegate. Lazy require of the gem: it does NOT
    # enter lib/insika.rb; it is loaded in the registration block (wiring) on the 1st
    # instance. One instance per remote agent (its own name/description).
    class A2ARemote < RubyLLM::Tool
      param :message, desc: "The message/task for the remote agent"

      def initialize(client:, url:, tool_name:, description:, event_stream: nil)
        @client = client
        @url = url
        @tool_name = tool_name
        @description = description
        @event_stream = event_stream
        super()
      end

      # name/description per INSTANCE (RubyLLM derives them from the class; we override —
      # otherwise the model would see "insika--tools--a2a_remote" for every remote).
      def name = @tool_name
      def description = @description

      def execute(message:)
        result = @client.call(@url, message.to_s)
        emit(result)
        result[:error] ? { error: result[:error] } : result[:text]
      end

      private

      # :a2a_call without task correlation: registry tools do not receive the
      # TurnState -> meta {} (like the Builder's :provider_warning). The :tool_call
      # from wire_callbacks already correlates the call itself.
      def emit(result)
        @event_stream&.emit(Insika::Event.new(
                              type: :a2a_call,
                              data: { agent: @tool_name, remote_task_id: result[:id], state: result[:state] },
                              meta: {}
                            ))
      end
    end
  end
end
