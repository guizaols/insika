# frozen_string_literal: true

module AgentRuntime
  # Tudo que o runtime emite durante um turno é um Event.
  # O consumidor (seu sistema WhatsApp) reage por :type.
  #
  #   :skill_activated  { name: }
  #   :tool_call        { name:, arguments: }
  #   :tool_result      { name:, result: }
  #   :content          { delta: }        # pedaço de texto
  #   :done             { content: }      # texto final consolidado
  #   :error            { message: }
  Event = Data.define(:type, :data) do
    def to_h
      { type: type }.merge(data)
    end
  end
end
