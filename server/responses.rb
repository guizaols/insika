# frozen_string_literal: true

require "json"

module Insika
  module Server
    # OpenAI Responses edge adapter (`/v1/responses`) — the contract that the
    # OpenClaw gateway consumers already speak (see consumer-app
    # `CoreServices::OpenclawDispatcher`). Phase 6, Step A.
    #
    # PURE module (no state, no framework): (a) translates the OpenAI
    # Responses request → `:send_message` payload; (b) maps each turn Event →
    # OpenAI Responses SSE frame (or nil for events with no counterpart). Follows the
    # constitutional rule: no business logic, no store access here.
    #
    # Request: { model: "openclaw:<agent>", user: "<chat.id>", stream: true,
    #            input: "<string with already-composed blocks>" } + header
    # X-Openclaw-Agent (agent fallback). The `input` enters VERBATIM as the
    # turn's message — the blocks (<memoria>/<dados_conhecidos>/directives) already come
    # composed by the consumer (the engine does not interpret them).
    module Responses
      module_function

      # -> { agent:, user:, message: } | raise ValidationError.
      def parse_request(body, req)
        agent = body[:model].to_s.sub(/\Aopenclaw:/, "")
        agent = req.get_header("HTTP_X_OPENCLAW_AGENT").to_s if agent.empty?
        raise Insika::ValidationError, "model/agent missing" if agent.strip.empty?

        user = body[:user].to_s
        raise Insika::ValidationError, "user missing" if user.strip.empty?

        message = extract_input(body[:input])
        raise Insika::ValidationError, "input empty" if message.strip.empty?

        { agent: agent.strip, user: user, message: message }
      end

      # V1: `input` is a STRING (the dispatcher composes the blocks + user text). Tolerates
      # an array of parts (OpenAI multimodal shape) by joining the texts.
      def extract_input(input)
        case input
        when String then input
        when Array
          input.flat_map { |part| part.is_a?(Hash) ? (part[:text] || part["text"]) : part }
               .compact.join("\n")
        else input.to_s
        end
      end

      # Turn Event -> OpenAI Responses SSE frame | nil (event with no
      # counterpart: :task_started, :tool_result, :skill_activated, ...).
      # Terminal events emit the final frame + `[DONE]` (close the stream).
      def frame_for(event)
        case event.type
        when :content
          sse("response.output_text.delta",
              { type: "response.output_text.delta", delta: event.data[:delta].to_s })
        when :tool_call
          sse("response.output_item.added",
              { type: "response.output_item.added",
                item: { type: "function_call", name: event.data[:name].to_s } })
        when :task_completed
          completed(event) + done
        when :task_failed
          failed(event.data[:message] || "task failed") + done
        when :task_cancelled
          failed("task cancelled") + done
        when :error
          failed(event.data[:message] || "error") + done
        when :thinking, :intermediate
          # NEITHER is the answer, and this consumer streams every text delta straight
          # to the end customer (consumer-app's OpenclawDispatcher accumulates the deltas
          # into the WhatsApp reply), so anything mapped here would be read out loud.
          #
          # :thinking is the provider's reasoning channel. :intermediate is the model's
          # own prose that did not turn out to be the answer — the narration of a
          # message that also called a tool, or the reasoning-in-content a model emits
          # when it has no tool to call. A real store's prompt sent 132 deltas of an
          # English monologue this way before TurnOutput started holding them back.
          #
          # Both stay internal: /studio/events + the Studio + the trace. Explicit (not
          # a fall-through) to keep the closed catalog honest.
          nil
        when :guardrail_blocked, :guardrail_flagged
          # RFC-0009: audit events with no OpenAI Responses counterpart. On a BLOCK
          # the safe reply still reaches the consumer through the normal :content
          # deltas + :task_completed path (the turn completes gracefully), so there
          # is nothing extra to translate here — the events live in /v1/events + the
          # Studio + the trace. Explicit (not a fall-through) to keep the closed
          # catalog honest.
          nil
        end
      end

      def completed(event)
        response = {}
        if (usage = event.data[:usage])
          # `model` travels alongside usage in the event; in the OpenAI shape it is a sibling of
          # usage (pure tokens in usage).
          model = usage[:model] || usage["model"]
          response[:usage] = usage.reject { |k, _| k.to_s == "model" }
          response[:model] = model if model
        end
        # Opt-in per-turn latency breakdown (INSIKA_TURN_TIMING; item 34). Absent
        # by default — a non-standard sibling used only for TTFB diagnostics.
        (timing = event.data[:timing]) && (response[:timing] = timing)
        sse("response.completed", { type: "response.completed", response: response })
      end

      def failed(message)
        sse("response.failed",
            { type: "response.failed", response: { error: { message: message.to_s } } })
      end

      # event: + data: (the dispatcher reads both: `event:` and `type` in the JSON).
      def sse(event_name, data)
        "event: #{event_name}\ndata: #{JSON.generate(data)}\n\n"
      end

      def done = "data: [DONE]\n\n"
    end
  end
end
