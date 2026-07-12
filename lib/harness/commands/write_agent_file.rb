# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: grava um arquivo de prompt de um
    # agente no workspace (AgentFileStore). É o que dá identidade própria a cada
    # BIA — o Prompt provider lê estes arquivos por `profile.prompt_files`. Vale
    # no próximo dispatch (hot). -> { agent_id, file, updated_at }.
    class WriteAgentFile
      def initialize(profile_source:, agent_file_store:, event_stream:)
        @profile_source = profile_source
        @agent_files = agent_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent_id = AgentPayload.presence(p[:agent_id])
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "agent_id é obrigatório" if agent_id.nil?
        raise Harness::ValidationError, "file é obrigatório" if file.nil?
        profile = @profile_source.fetch(agent_id) ||
                  (raise Harness::NotFoundError, "agente '#{agent_id}' não encontrado")

        entry = @agent_files.write(agent_id, file, p[:content].to_s, create_only: !!p[:create_only])
        # Gravar um prompt o registra em prompt_files — senão o Prompt provider
        # nunca o carregaria. É trabalho do Command, não de quem despacha.
        register_prompt_file(profile, file)
        emit(:agent_file_written, agent_id, file)
        { agent_id: agent_id, file: file, updated_at: entry["updated_at"] }
      end

      private

      def register_prompt_file(profile, file)
        files = Array(profile.prompt_files).map(&:to_s)
        return if files.include?(file)

        @profile_source.put(Harness::AgentProfile.build(**profile.to_h.merge(prompt_files: files + [file])))
      end

      def emit(type, agent_id, file)
        @event_stream.emit(Harness::Event.new(
                             type: type, data: { agent_id: agent_id, file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
