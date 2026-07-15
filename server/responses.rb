# frozen_string_literal: true

require "json"

module Harness
  module Server
    # Adapter de borda OpenAI Responses (`/v1/responses`) — o contrato que os
    # consumidores do gateway OpenClaw já falam (ver consumer-app
    # `CoreServices::OpenclawDispatcher`). Fase 6, Etapa A.
    #
    # Módulo PURO (sem estado, sem framework): (a) traduz o request OpenAI
    # Responses → payload de `:send_message`; (b) mapeia cada Event do turno →
    # frame SSE OpenAI Responses (ou nil p/ eventos sem correspondência). Segue a
    # regra constitucional: nenhuma lógica de negócio, nenhum acesso a store aqui.
    #
    # Request: { model: "openclaw:<agent>", user: "<chat.id>", stream: true,
    #            input: "<string com blocos já compostos>" } + header
    # X-Openclaw-Agent (fallback do agente). O `input` entra VERBATIM como a
    # mensagem do turno — os blocos (<memoria>/<dados_conhecidos>/diretivas) já vêm
    # compostos pelo consumidor (o motor não os interpreta).
    module Responses
      module_function

      # -> { agent:, user:, message: } | raise ValidationError.
      def parse_request(body, req)
        agent = body[:model].to_s.sub(/\Aopenclaw:/, "")
        agent = req.get_header("HTTP_X_OPENCLAW_AGENT").to_s if agent.empty?
        raise Harness::ValidationError, "model/agent ausente" if agent.strip.empty?

        user = body[:user].to_s
        raise Harness::ValidationError, "user ausente" if user.strip.empty?

        message = extract_input(body[:input])
        raise Harness::ValidationError, "input vazio" if message.strip.empty?

        { agent: agent.strip, user: user, message: message }
      end

      # V1: `input` é STRING (o dispatcher compõe os blocos + user text). Tolera
      # array de partes (shape OpenAI multimodal) juntando os textos.
      def extract_input(input)
        case input
        when String then input
        when Array
          input.flat_map { |part| part.is_a?(Hash) ? (part[:text] || part["text"]) : part }
               .compact.join("\n")
        else input.to_s
        end
      end

      # Event do turno -> frame SSE OpenAI Responses | nil (evento sem
      # correspondência: :task_started, :tool_result, :skill_activated, ...).
      # Eventos terminais emitem o frame final + `[DONE]` (fecham o stream).
      def frame_for(event)
        case event.type
        when :content
          sse("response.output_text.delta",
              { type: "response.output_text.delta", delta: event.data[:delta].to_s })
        when :tool_call
          sse("response.output_item.added",
              { type: "response.output_item.added",
                item: { type: "function_call", name: event.data[:name].to_s } })
        when :done, :task_completed
          completed(event) + done
        when :task_failed
          failed(event.data[:message] || "task failed") + done
        when :task_cancelled
          failed("task cancelled") + done
        when :error
          failed(event.data[:message] || "error") + done
        end
      end

      def completed(event)
        usage = event.data[:usage]
        response = usage ? { usage: usage } : {}
        sse("response.completed", { type: "response.completed", response: response })
      end

      def failed(message)
        sse("response.failed",
            { type: "response.failed", response: { error: { message: message.to_s } } })
      end

      # event: + data: (o dispatcher lê os dois: `event:` e `type` no JSON).
      def sse(event_name, data)
        "event: #{event_name}\ndata: #{JSON.generate(data)}\n\n"
      end

      def done = "data: [DONE]\n\n"
    end
  end
end
