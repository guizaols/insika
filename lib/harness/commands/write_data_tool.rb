# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Grava (upsert) uma tool POR DADOS no ToolStore e RECARREGA o overlay + o
    # catálogo — passa a valer sem restart (F5). Recusa nome que colida com uma
    # tool de código (R3). A validação da definição (formato, method/url, tipos,
    # placeholders) é do ToolStore/ToolDefinition. Segredos (headers) reconciliam
    # no store; o evento carrega só o nome (0 vazamento). -> { name, definition }.
    class WriteDataTool
      def initialize(tool_store:, registry:, tool_catalog:, event_stream:)
        @tool_store = tool_store
        @registry = registry
        @tool_catalog = tool_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Harness::ValidationError, "name é obrigatório" if name.nil?
        raise Harness::ValidationError, "'#{name}' já é uma tool de código" if @registry.code_tool?(name)

        masked = @tool_store.write(p, create_only: !!p[:create_only])
        @registry.reload
        @tool_catalog.reload
        emit(name)
        { name: name, definition: masked }
      end

      private

      def emit(name)
        @event_stream.emit(Harness::Event.new(
                             type: :data_tool_written, data: { name: name },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
